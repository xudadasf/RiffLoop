import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def grouped_boundary_fixture(path,mode='valid',new_page=False,down=False):
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=440)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        for row in range(2):
            if row and new_page:p=doc.new_page(width=420,height=440)
            top=100 if not row or new_page else 270;y=top+6
            p.insert_font(fontname='music',fontbuffer=font_buffer())
            for yy in range(top,top+31,6):p.draw_line((30,yy),(400,yy),width=.4)
            for x in (30,400):p.draw_line((x,top),(x,top+30),width=.4)
            p.insert_text((30,top-2),str(row+1),fontname='Times-Roman',fontsize=6)
            if not row:
                for yy in (top+10,top+18.5):p.insert_text((38,yy),'\ue084',fontname='music',fontsize=17)
            boxes=[]
            for i,x in enumerate((70,160,280,340)):
                fret=(6 if down else 10) if row else (10 if down else 6) if i==2 else 8
                token='X' if not row and i==2 and mode=='dead_source' else str(fret)
                if not row and i==2 and mode=='same_fret':token='8'
                if not row and i==2 and mode=='source_rest':
                    p.insert_text((x,y),'\ue4e5',fontname='music',fontsize=17);boxes.append((x,x));continue
                actual_y=y+6 if not row and i==2 and mode=='other_string' else y
                size=5 if not row and i==2 and mode=='grace_source' else 7
                w=fitz.get_text_length(token,fontname='helv',fontsize=size)
                p.insert_text((x-w/2,actual_y+2.4),token,fontname='helv',fontsize=size);boxes.append((x-w/2,x+w/2))
                p.draw_line((x,top+35),(x,top+55),width=.4)
                if not row and i==2 and mode=='source_chord':p.insert_text((x-1.95,y+8.4),'5',fontname='helv',fontsize=7)
            side=-1 if mode=='upper' else 1
            def arc(a,z,yy,end_y=None):
                end_y=yy if end_y is None else end_y
                sh=p.new_shape()
                sh.draw_bezier((a,yy),(a+4,yy+side*5),(z-4,end_y+side*5),(z,end_y))
                sh.draw_bezier((z,end_y),(z-4,end_y+side*4),(a+4,yy+side*4),(a,yy))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
            if not row:
                label='sl.';cx=360 if mode=='wrong_scope' else 340
                w=fitz.get_text_length(label,fontname='Times-Italic',fontsize=6)
                if mode!='no_label':
                    for _ in range(2 if mode=='duplicate_label' else 1):
                        p.insert_text((cx-w/2,top-4),label,fontname='Times-Italic',fontsize=6)
                if mode in ('H','P'):p.insert_text((307,top-4),mode,fontname='Times-Roman',fontsize=6)
                rise=-1.5 if down else 1.5
                if mode!='no_prefix_line':
                    for _ in range(2 if mode=='duplicate_line' else 1):
                        d=-rise if mode=='wrong_slope' else rise
                        p.draw_line((boxes[2][1]+1,y+d),(boxes[3][0]-1,y-d),width=.4)
                if mode!='no_prefix_arc':
                    for _ in range(2 if mode=='duplicate_arc' else 1):
                        arc(280,340,y+side*2.5,y+6 if mode=='displaced_arc' else None)
                if mode!='no_boundary_line':p.draw_line((boxes[3][1]+2,y+rise),(398,y),width=.4)
                if mode!='no_outgoing':arc(340,398,y+side*2.5)
            elif mode!='no_incoming':arc(64,70,y+side*2.5)
        doc.save(path)


class GroupedBoundarySlideTests(unittest.TestCase):
    def test_shared_label_covers_both_proven_transitions_across_rows_and_pages(self):
        for new_page,down,mode in ((False,False,'valid'),(True,False,'valid'),(False,True,'valid'),(True,True,'upper')):
            with self.subTest(new_page=new_page,down=down,mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'slides.pdf';grouped_boundary_fixture(pdf,mode,new_page,down)
                data=recognize(pdf);beats=data['systems'][0]['bars'][0]['beats']
                self.assertEqual([v['notes'][0].get('legato_slide',False) for v in beats],[False,False,True,True])
                self.assertEqual(beats[2]['notes'][0]['slide_target_fret'],8)
                self.assertEqual(beats[3]['notes'][0]['slide_target_fret'],6 if down else 10)
                self.assertFalse(any(b['issues'] for s in data['systems'] for b in s['bars']))

    def test_scope_and_each_segment_need_independent_evidence(self):
        modes=('wrong_scope','no_label','duplicate_label','H','P','no_prefix_line','wrong_slope','duplicate_line',
               'no_prefix_arc','duplicate_arc','displaced_arc','no_boundary_line','no_outgoing','no_incoming',
               'other_string','dead_source','same_fret','source_rest','source_chord','grace_source')
        for mode in modes:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ambiguous.pdf';grouped_boundary_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertFalse(any(n.get('legato_slide') for n in bar['beats'][2]['notes']))

    def test_gp_and_midi_join_the_full_chain_without_extra_attacks(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'slides.pdf';grouped_boundary_fixture(pdf,new_page=True)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js'),notes=[];
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
const beats=s.tracks[0].staves[0].bars[0].voices[0].beats;
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end,
 slides:beats.slice(2).map(b=>[b.notes[0].slideOutType,b.notes[0].slideTarget?.fret])}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
            self.assertEqual(json.loads(run.stdout),{'notes':[[0,960],[960,960],[1920,2880],[4800,960],[5760,960],[6720,960]],
                                                     'end':7680,'slides':[[2,8],[2,10]]})


if __name__=='__main__':unittest.main()
