import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def chord_fixture(path,mode='valid',bend_right=False,outlined=False):
    with fitz.open() as doc,fitz.open() as music:
        p=doc.new_page(width=400,height=220)
        m=music.new_page(width=400,height=220) if outlined else p
        m.insert_font(fontname='music',fontbuffer=font_buffer())
        p.insert_text((30,25),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        for yy in range(110,141,6):p.draw_line((30,yy),(350,yy),width=.4)
        for i in range(5):p.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
        for x in (30,350):p.draw_line((x,110),(x,140),width=.4)
        for yy in (120,128.5):m.insert_text((38,yy),'\ue084',fontname='music',fontsize=17)
        for i,x in enumerate((70,140,210,280)):
            if i!=1 or mode=='visible_target':
                for string,fret in ((2,4),(3,6)):
                    token='X' if i==0 and mode=='dead_source' and string==3 else str(fret)
                    size=5 if i==0 and mode=='grace_source' else 7
                    w=fitz.get_text_length(token,fontname='helv',fontsize=size)
                    p.insert_text((x-w/2,110+(string-1)*6+2.4),token,fontname='helv',fontsize=size)
                if i==0 and mode=='third_source_note':p.insert_text((x-1.95,130.4),'7',fontname='helv',fontsize=7)
            for j,dx in enumerate((-2.25,2.25)):
                if mode=='missing_head' and i==1 and j==1:continue
                if mode=='missing_source_head' and i==0 and j==1:continue
                y=60 if i==1 or j==1 else 62.125
                if mode=='unequal_target' and i==1 and j==0:y+=2.125
                if mode=='equal_source' and i==0:y=60
                size=12.75 if mode=='cue_head' and i==1 and j==0 else 17
                m.insert_text((x+dx-2.5,y),'\ue0a4',fontname='music',fontsize=size)
            if not (i==1 and mode=='no_stem' or i==0 and mode=='no_source_stem'):
                p.draw_line((x,60.7 if i!=1 else 59.3),(x,78),width=.4)
                if i==1 and mode=='duplicate_stem':p.draw_line((x+.2,59.3),(x+.2,78),width=.4)
            if i==1 and mode=='third_target_head':m.insert_text((x-2.5,56),'\ue0a4',fontname='music',fontsize=17)
        for side in (-1,1):
            if mode==('no_left_parenthesis' if side==-1 else 'no_right_parenthesis'):continue
            x=140+side*5.35;y=60
            sh=p.new_shape();sh.draw_bezier((x,y-2.125),(x+side*3.4,y-1.0625),(x+side*3.4,y+1.0625),(x,y+2.125))
            sh.draw_bezier((x,y+2.125),(x+side*2.55,y+1.0625),(x+side*2.55,y-1.0625),(x,y-2.125))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        if mode!='no_bend':
            for _ in range(2 if mode=='duplicate_bend' else 1):
                a=(68.9,59.065);z=(140+(2.25 if bend_right else -2.25)-.55,56.94)
                if mode=='wrong_bend_source':a=(73.4,59.065)
                if mode=='wrong_bend_target':z=(z[0]+5,56.94)
                peak=(90,50.985);sh=p.new_shape();sh.draw_line(a,peak);sh.draw_line(peak,z)
                sh.finish(color=(0,0,0),width=.5);sh.commit()
        if mode!='no_tie':
            for _ in range(2 if mode=='duplicate_tie' else 1):
                a=75.45;z=132.1 if bend_right else 139.58;y=59.15
                if mode=='wrong_tie_source':a=70.95
                if mode=='wrong_tie_target':z-=7
                if mode=='wrong_tie_height':y-=4
                sh=p.new_shape();sh.draw_bezier((a,y),(a+6,y-4.5),(z-6,y-4.5),(z,y))
                sh.draw_bezier((z,y),(z-6,y-3.5),(a+6,y-3.5),(a,y))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
        if mode=='intervening_rest':m.insert_text((105,120),'\ue4e5',fontname='music',fontsize=17)
        if mode=='intervening_head':m.insert_text((103,60),'\ue0a4',fontname='music',fontsize=17)
        if mode in ('H','P','sl.'):p.insert_text((100,95),mode,fontname='Times-Roman',fontsize=6)
        if outlined:
            with fitz.open(stream=m.get_svg_image(text_as_path=True).encode(),filetype='svg') as svg:
                with fitz.open(stream=svg.convert_to_pdf(),filetype='pdf') as vector:p.show_pdf_page(p.rect,vector,0)
        doc.save(path)


class BentUnisonChordTests(unittest.TestCase):
    def test_both_unison_head_orders_preserve_the_entire_chord(self):
        for right,outlined in ((False,False),(True,False),(False,True),(True,True)):
            with self.subTest(right=right,outlined=outlined),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'chord.pdf';chord_fixture(pdf,bend_right=right,outlined=outlined)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertFalse(bar['issues']);self.assertEqual(len(bar['beats']),4)
                self.assertEqual([(n['string'],n['fret'],n['tie']) for n in bar['beats'][1]['notes']],[(2,4,True),(3,6,True)])

    def test_each_source_tone_needs_its_own_unique_connection(self):
        modes=('no_bend','duplicate_bend','wrong_bend_source','wrong_bend_target','no_tie','duplicate_tie',
               'wrong_tie_source','wrong_tie_target','wrong_tie_height','no_left_parenthesis','no_right_parenthesis',
               'missing_head','missing_source_head','third_target_head','third_source_note','unequal_target',
               'equal_source','cue_head','no_stem','no_source_stem','duplicate_stem','visible_target',
               'dead_source','grace_source','intervening_rest','intervening_head','H','P','sl.')
        for mode in modes:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'bad.pdf';chord_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('inferred_from') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_gp_and_midi_keep_both_strings_without_new_attacks(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'chord.pdf';chord_fixture(pdf,bend_right=True,outlined=True)
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
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end,
 held:s.tracks[0].staves[0].bars[0].voices[0].beats[1].notes.map(n=>[7-n.string,n.fret,n.isTieDestination]).sort((x,y)=>x[0]-y[0])}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
            self.assertEqual(json.loads(run.stdout),{'notes':[[0,1920],[0,1920],[1920,960],[1920,960],[2880,960],[2880,960]],
                                                    'end':3840,'held':[[2,4,True],[3,6,True]]})


if __name__=='__main__':unittest.main()
