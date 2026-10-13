import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def grouped_fixture(path,mode='group'):
    compact=mode in ('cutouts','pair_cutout','wrong_compact_slope','line_over_digit')
    pair=mode in ('pair_cutout','wrong_compact_slope','line_over_digit')
    xs=(70,80,90,100) if compact else (70,100,130,160)
    frets=(12,14,12,10);last=1 if pair else 3
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=240)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(400,y),width=.4)
        for x in (30,400):p.draw_line((x,100),(x,130),width=.4)
        p.insert_text((30,98),'1',fontname='Times-Roman',fontsize=6)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        boxes=[]
        for i,x in enumerate(xs):
            y=112 if mode=='other_string' and i==1 else 106
            token=str(frets[i]);width=fitz.get_text_length(token,fontname='helv',fontsize=7)
            p.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7)
            p.draw_line((x,y+5),(x,150),width=.4);boxes.append((x-width/2,x+width/2))
        center=(xs[0]+xs[last])/2
        if mode!='no_label':
            if mode=='off_center':center=(xs[0]+xs[1])/2
            for _ in range(2 if mode=='duplicate_label' else 1):
                p.insert_text((center-fitz.get_text_length('sl.',fontname='Times-Italic',fontsize=6)/2,96),'sl.',fontname='Times-Italic',fontsize=6)
        if mode=='mixed_labels':p.insert_text(((xs[0]+xs[1])/2,96),'H',fontname='Times-Italic',fontsize=6)
        if mode=='rest':p.insert_text((85,112),'\ue4e5',fontname='music',fontsize=17)
        if mode!='no_arc':
            for _ in range(2 if mode=='duplicate_arc' else 1):
                sy=103.5;tx=xs[last]
                sh=p.new_shape();sh.draw_bezier((xs[0],sy),(xs[0],sy-8),(tx,sy-8),(tx,sy))
                sh.draw_bezier((tx,sy),(tx,sy-7),(xs[0],sy-7),(xs[0],sy))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
        for i in range(last):
            if compact and mode not in ('wrong_compact_slope','line_over_digit') or mode=='missing_line' and i==1:continue
            rise=1 if frets[i+1]>frets[i] else -1
            if mode in ('wrong_slope','wrong_compact_slope') and i==0:rise=-rise
            margin=-1 if mode=='line_over_digit' else .2 if compact else 2
            p.draw_line((boxes[i][1]+margin,106+rise*1.5),(boxes[i+1][0]-margin,106-rise*1.5),width=.4)
        doc.save(path)


class GroupedSlideTests(unittest.TestCase):
    def test_one_centered_slide_label_covers_all_transitions_under_its_slur(self):
        for mode in ('group','cutouts','pair_cutout'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'group.pdf';grouped_fixture(pdf,mode);data=recognize(pdf)
                bar=data['systems'][0]['bars'][0];self.assertFalse(bar['issues'])
                self.assertEqual([n.get('legato_slide',False) for v in bar['beats'] for n in v['notes']],
                                 [True,False,False,False] if mode=='pair_cutout' else [True,True,True,False])

    def test_incomplete_or_conflicting_group_evidence_is_not_used(self):
        for mode in ('no_label','off_center','duplicate_label','mixed_labels','rest','no_arc','duplicate_arc','other_string','missing_line','wrong_slope','wrong_compact_slope','line_over_digit'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'group.pdf';grouped_fixture(pdf,mode);data=recognize(pdf)
                self.assertFalse(any(n.get('legato_slide') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_export_chain_removes_three_attacks_without_changing_bar_length(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'group.pdf';grouped_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const {auditSlides}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load();
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes){n.slideOutType=0;n.slideTarget=null;n.slideOrigin=null;}
console.log(JSON.stringify({playback:comparePlayback(actual,flat,0),audit:auditSlides(JSON.parse(fs.readFileSync(process.argv[2],'utf8')),actual.tracks[0],new Set([1]))}));
'''
            run=subprocess.run(['node','-e',script,str(gp),str(raw)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(result['playback']['actual']['note_attacks'],1)
            self.assertEqual(result['playback']['reference']['note_attacks'],4)
            self.assertTrue(result['playback']['checks']['end_tick'])
            self.assertEqual(len(result['audit']['verified']),3);self.assertFalse(result['audit']['mismatched'])


if __name__=='__main__':unittest.main()
