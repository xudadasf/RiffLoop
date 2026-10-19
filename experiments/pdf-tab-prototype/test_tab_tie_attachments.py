import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def attachment_fixture(path,boundary=False,harmonic=False,double_bar=False,dead_companion=False,
                       mode='valid',fret=7,page_break=False):
    with fitz.open() as doc:
        page=doc.new_page(width=400,height=500)
        page.insert_text((30,25),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        for si in range(2 if boundary else 1):
            if si and page_break:page=doc.new_page(width=400,height=500)
            top=280 if si and not page_break else 100;y=top+12
            page.insert_font(fontname='music',fontbuffer=font_buffer())
            for yy in range(top,top+31,6):page.draw_line((30,yy),(350,yy),width=.4)
            for x in (30,350):page.draw_line((x,top),(x,top+30),width=.5)
            if not si and double_bar and mode!='missing_inner_barline':
                page.draw_line((347.6,top),(347.6,top+30),width=.5)
            page.insert_text((30,top-2),str(si+1),fontname='Times-Roman',fontsize=6)
            if not si:
                for yy in (top+10,top+18.5):page.insert_text((38,yy),'\ue084',fontname='music',fontsize=17)
            source_x=280 if boundary else 70;target_x=70 if boundary else 140
            source_right=None;target_left=None
            for bi,x in enumerate((70,140,210,280)):
                source=si==0 and x==source_x
                target=(si==1 if boundary else si==0) and x==target_x
                if mode=='intervening_rest' and not boundary and bi==1:
                    page.insert_text((x,y),'\ue4e5',fontname='music',fontsize=17);continue
                if mode=='intervening_rest' and not boundary:target=bi==2
                token=str(fret+(1 if target and mode=='different_fret' else 0))
                if target and mode!='plain_target':token='('+token+')'
                if source and mode=='dead_origin':token='X'
                yy=y+6 if target and mode=='different_string' else y
                width=fitz.get_text_length(token,fontname='helv',fontsize=7)
                page.insert_text((x-width/2,yy+2.4),token,fontname='helv',fontsize=7)
                page.draw_line((x,yy+5),(x,top+50),width=.4)
                if source:
                    source_right=x+width/2
                    if harmonic:
                        label='19' if mode=='plain_annotation' else '<19>'
                        size=7 if mode=='large_annotation' else 5
                        ax=source_right+(8 if mode=='distant_annotation' else 1.4)
                        ay=y+(6 if mode=='annotation_other_string' else 0)
                        if mode!='missing_annotation':
                            page.insert_text((ax,ay+1.7),label,fontname='helv',fontsize=size)
                            if mode=='duplicate_annotation':page.insert_text((ax,ay+1.7),label,fontname='helv',fontsize=size)
                        source_right=ax+fitz.get_text_length(label,fontname='helv',fontsize=size)
                    if dead_companion:
                        page.insert_text((x-2.33,y+8.4),'X',fontname='helv',fontsize=7)
                if target:target_left=x-width/2
            def arc(a,z,yy):
                sh=page.new_shape();sh.draw_bezier((a,yy),(a+4,yy+4),(z-4,yy+4),(z,yy))
                sh.draw_bezier((z,yy),(z-4,yy+3),(a+4,yy+3),(a,yy))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
            if boundary:
                if not si and mode!='incoming_only':
                    arc(source_right+(-.28 if harmonic else 1.4)+(4 if mode=='detached_arc' else 0),
                        346.9 if double_bar else 349.3,y)
                elif si and mode!='outgoing_only':arc(40,target_left-1.4,y)
            else:arc(source_right+(-.28 if harmonic else 1.4)+(4 if mode=='detached_arc' else 0),target_left-1.4,y)
        doc.save(path)


class TabTieAttachmentTests(unittest.TestCase):
    def test_harmonic_annotation_is_part_of_the_printed_tie_origin(self):
        for boundary in (False,True):
            for fret in (7,15):
                with self.subTest(boundary=boundary,fret=fret),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'ties.pdf';attachment_fixture(pdf,boundary=boundary,harmonic=True,fret=fret,page_break=True)
                    data=recognize(pdf);bar=data['systems'][-1]['bars'][0]
                    target=bar['beats'][0 if boundary else 1]['notes'][0]
                    self.assertFalse(bar['issues']);self.assertTrue(target['tie'])
                    self.assertEqual((target['string'],target['fret']),(3,fret))

    def test_annotation_needs_unique_adjacent_ink_and_a_real_matching_tie(self):
        for mode in ('missing_annotation','plain_annotation','large_annotation','distant_annotation',
                     'annotation_other_string','duplicate_annotation','detached_arc','different_fret',
                     'different_string','plain_target','intervening_rest'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ties.pdf';attachment_fixture(pdf,harmonic=True,mode=mode)
                notes=[n for s in recognize(pdf)['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']]
                self.assertFalse(any(n['tie'] for n in notes))

    def test_boundary_accepts_printed_inner_barline_and_unrelated_dead_strings(self):
        for double,dead in ((True,False),(False,True),(True,True)):
            with self.subTest(double_bar=double,dead_companion=dead),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ties.pdf';attachment_fixture(pdf,boundary=True,double_bar=double,dead_companion=dead)
                data=recognize(pdf);target=data['systems'][1]['bars'][0]['beats'][0]['notes'][0]
                self.assertTrue(target['tie']);self.assertEqual(target['tie_source_bar'],1)
                self.assertFalse(any(n['tie'] for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes'] if n['dead']))

    def test_boundary_still_requires_both_sides_and_a_live_same_pitch_origin(self):
        for mode in ('missing_inner_barline','incoming_only','outgoing_only','different_fret','different_string','dead_origin','plain_target'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ties.pdf';attachment_fixture(pdf,boundary=True,double_bar=True,dead_companion=True,mode=mode)
                target=recognize(pdf)['systems'][1]['bars'][0]['beats'][0]['notes'][0]
                self.assertFalse(target['tie'])

    def test_gp_playback_extends_the_origin_without_an_extra_attack(self):
        for boundary in (False,True):
            with self.subTest(boundary=boundary),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'ties.pdf'
                attachment_fixture(pdf,boundary=boundary,harmonic=not boundary,double_bar=boundary,dead_companion=boundary)
                raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const notes=[];class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end}));
'''
                run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
                self.assertIn([2880 if boundary else 0,1920],result['notes'])
                self.assertFalse(any(t==3840 if boundary else t==960 for t,d in result['notes']))
                self.assertEqual(len(result['notes']),8 if boundary else 3)
                self.assertEqual(result['end'],7680 if boundary else 3840)


if __name__=='__main__':unittest.main()
