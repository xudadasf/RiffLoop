import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def slide_fixture(path,mode='up',frets=None,string=2,source_index=3):
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=240)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(400,y),width=.4)
        for x in (30,220,400):p.draw_line((x,100),(x,130),width=.4)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for number,x in ((1,30),(2,220)):p.insert_text((x,98),str(number),fontname='Times-Roman',fontsize=6)
        source,target=frets or ((13,8) if mode=='down' else (8,13))
        note_y=100+(string-1)*6
        positions=(70,110,150,190,245,285,325,365)
        sx,tx=positions[source_index:source_index+2]
        boxes={}
        for i,x in enumerate(positions):
            y=note_y+6 if mode=='other_string' and i==source_index+1 else note_y
            fret=source if i==source_index else target if i==source_index+1 else 7
            token=str(fret);width=fitz.get_text_length(token,fontname='helv',fontsize=7)
            p.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7)
            p.draw_line((x,y+5),(x,150),width=.4);boxes[i]=(x-width/2,x+width/2)
        if mode=='intervening_rest':p.insert_text((232,112),'\ue4e5',fontname='music',fontsize=17)
        if mode!='no_label':p.insert_text(((sx+tx)/2-3,96),'sl.',fontname='Times-Italic',fontsize=6)
        if mode!='no_arc':
            side=1 if mode=='lower_arc' else -1
            sh=p.new_shape();sh.draw_bezier((sx,note_y+side*2.5),(sx+6,note_y+side*11),(tx-6,note_y+side*11),(tx,note_y+side*2.5))
            sh.draw_bezier((tx,note_y+side*2.5),(tx-6,note_y+side*10),(sx+6,note_y+side*10),(sx,note_y+side*2.5))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        if mode!='no_line':
            rise=1 if target>source else -1
            if mode=='wrong_slope':rise=-rise
            p.draw_line((boxes[source_index][1]+2,note_y+rise*1.5),(boxes[source_index+1][0]-2,note_y-rise*1.5),width=.4)
        doc.save(path)


class SlideTests(unittest.TestCase):
    def test_same_rule_handles_other_frets_strings_and_within_bar_positions(self):
        for frets,string,index in (((2,7),1,1),((15,3),6,2),((10,17),4,3)):
            with self.subTest(frets=frets,string=string,index=index),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'slide.pdf';slide_fixture(pdf,frets=frets,string=string,source_index=index)
                data=recognize(pdf)
                self.assertEqual([m['status'] for m in data['slide_marks']],['recognized'])
                notes=[n for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes'] if n.get('legato_slide')]
                self.assertEqual([(n['fret'],n['slide_target_fret'],n['string']) for n in notes],[(frets[0],frets[1],string)])

    def test_legato_slide_is_recognized_exported_and_changes_playback(self):
        for mode in ('up','down','lower_arc'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'slide.pdf';slide_fixture(pdf,mode)
                data=recognize(pdf);bars=data['systems'][0]['bars']
                self.assertTrue(bars[0]['beats'][-1]['notes'][0].get('legato_slide'))
                self.assertEqual(bars[1]['beats'][0]['notes'][0].get('slide_source_bar'),1)
                self.assertFalse(any(b['issues'] for b in bars))
                raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8')
                gp=root/'slide.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const {auditSlides,findRegressions}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load(),n=actual.tracks[0].staves[0].bars[0].voices[0].beats[3].notes[0];
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes){n.slideOutType=0;n.slideTarget=null;n.slideOrigin=null;}
const pred=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),audit=auditSlides(pred,actual.tracks[0],new Set([1,2]));
pred.systems[0].bars[0].beats[3].notes[0].slide_target_fret=24;
const wrong=auditSlides(pred,actual.tracks[0],new Set([1,2]));
const unaligned=auditSlides(pred,actual.tracks[0],new Set([1]));
const baseline={cases:[{case:'fixture',pdf:'slide.pdf',track_index:0,...audit}]};
const missing={cases:[{case:'fixture',pdf:'slide.pdf',track_index:0,...wrong}]};
console.log(JSON.stringify({slide:n.slideOutType,target:n.slideTarget.fret,comparison:comparePlayback(actual,flat,0),audit,wrong,unaligned,
    regressions:findRegressions(missing,baseline),unchanged:findRegressions(baseline,baseline)}));
'''
                result=subprocess.run(['node','-e',script,str(gp),str(raw)],cwd=HERE.parent.parent,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                checked=json.loads(result.stdout)
                self.assertEqual(checked['slide'],2)
                self.assertEqual(checked['target'],8 if mode=='down' else 13)
                self.assertFalse(checked['comparison']['checks']['note_attacks'])
                self.assertEqual(checked['comparison']['actual']['note_attacks'],7)
                self.assertEqual(len(checked['audit']['verified']),1)
                self.assertFalse(checked['audit']['mismatched'])
                self.assertEqual(len(checked['wrong']['mismatched']),1)
                self.assertEqual(len(checked['wrong']['not_recognized']),1)
                self.assertFalse(checked['unaligned']['mismatched'])
                self.assertEqual(len(checked['unaligned']['unverified_predictions']),1)
                self.assertEqual(len(checked['regressions']),1)
                self.assertFalse(checked['unchanged'])
                for selection in ('1','2'):
                    run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(root/f'{selection}.gp'),selection],capture_output=True,text=True)
                    self.assertNotEqual(run.returncode,0)
                    self.assertIn('Slide',run.stderr)

    def test_incomplete_or_conflicting_slide_evidence_is_not_inferred(self):
        for mode in ('no_label','no_arc','no_line','other_string','intervening_rest','wrong_slope'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'slide.pdf';slide_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('legato_slide') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))


if __name__=='__main__':unittest.main()
