import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def dead_slide_fixture(path,mode='up',string=2,fret=13):
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=240)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(400,y),width=.4)
        for x in (30,220,400):p.draw_line((x,100),(x,130),width=.4)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for number,x in ((1,30),(2,220)):p.insert_text((x,98),str(number),fontname='Times-Roman',fontsize=6)
        sy=100+(string-1)*6;boxes={}
        positions=(70,110,150,190,245,285,325,365)
        for i,x in enumerate(positions):
            y=sy+6 if mode=='other_string' and i==4 else sy
            token='X' if i==3 or i==4 and mode=='dead_target' else str(fret) if i==4 else '7'
            size=5 if mode=='grace' and i==3 else 7
            width=fitz.get_text_length(token,fontname='helv',fontsize=size)
            p.insert_text((x-width/2,y+size*.34),token,fontname='helv',fontsize=size)
            p.draw_line((x,y+5),(x,150),width=.4);boxes[i]=(x-width/2,x+width/2)
            if mode=='chord' and i==3:p.insert_text((x-1.9,sy+8.4),'5',fontname='helv',fontsize=7)
        if mode=='rest':p.insert_text((229,112),'\ue4e5',fontname='music',fontsize=17)
        if mode!='no_label':p.insert_text((214,96),'sl.',fontname='Times-Italic',fontsize=6)
        for _ in range(0 if mode=='no_arc' else 2 if mode=='duplicate_arc' else 1):
            sh=p.new_shape();sh.draw_bezier((190,sy-2.5),(196,sy-11),(239,sy-11),(245,sy-2.5))
            sh.draw_bezier((245,sy-2.5),(239,sy-10),(196,sy-10),(190,sy-2.5))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        for _ in range(0 if mode=='no_line' else 2 if mode=='duplicate_line' else 1):
            rise=-1 if mode=='down' else 0 if mode=='horizontal' else 1
            shift=12 if mode=='detached' else 0
            p.draw_line((boxes[3][1]+2+shift,sy+rise*1.5),(boxes[4][0]-2,sy-rise*1.5),width=.4)
        doc.save(path)


class DeadSlideTests(unittest.TestCase):
    def test_visible_line_slur_and_label_identify_dead_source_without_inventing_fret(self):
        for mode,string,fret in (('up',1,17),('up',2,14),('down',6,8),('down',4,3),('up',4,0)):
            with self.subTest(mode=mode,string=string,fret=fret),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'slide.pdf';dead_slide_fixture(pdf,mode,string,fret)
                data=recognize(pdf);bars=data['systems'][0]['bars'];note=bars[0]['beats'][3]['notes'][0]
                self.assertTrue(note.get('legato_slide'))
                self.assertTrue(note['dead']);self.assertIsNone(note['fret'])
                self.assertEqual(note['slide_target_fret'],fret)
                self.assertEqual(bars[1]['beats'][0]['notes'][0]['slide_source_bar'],1)
                self.assertFalse(any(b['issues'] for b in bars))

    def test_incomplete_ambiguous_or_unsupported_dead_slides_are_rejected(self):
        for mode in ('no_label','no_line','no_arc','duplicate_line','duplicate_arc','other_string',
                     'dead_target','chord','rest','grace','horizontal','detached'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'slide.pdf';dead_slide_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('legato_slide') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_roundtrip_audit_and_playback_keep_dead_distinct_from_open_string(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'slide.pdf';dead_slide_fixture(pdf)
            data=recognize(pdf);raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8')
            gp=root/'slide.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {auditSlides,findRegressions}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const pred=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),score=load(),flat=load();
const note=score.tracks[0].staves[0].bars[0].voices[0].beats[3].notes[0];
for(const bar of flat.tracks[0].staves[0].bars)for(const v of bar.voices)for(const b of v.beats)for(const n of b.notes){n.slideOutType=0;n.slideOrigin=null;n.slideTarget=null;}
const audit=auditSlides(pred,score.tracks[0],new Set([1,2]));
const unaligned=auditSlides(pred,score.tracks[0],new Set([1]));
note.isDead=false;
const wrong=auditSlides(pred,score.tracks[0],new Set([1,2]));note.isDead=true;
const wrap=v=>({cases:[{case:'fixture',pdf:'slide.pdf',track_index:0,...v}]});
console.log(JSON.stringify({dead:note.isDead,fret:note.fret,slide:note.slideOutType,target:note.slideTarget?.fret,
 audit,wrong,unaligned,lost:findRegressions(wrap(wrong),wrap(audit)),playback:comparePlayback(score,flat,0)}));'''
            run=subprocess.run(['node','-e',script,str(gp),str(raw)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertTrue(result['dead']);self.assertEqual(result['slide'],2);self.assertEqual(result['target'],13)
            self.assertEqual(len(result['audit']['verified']),1);self.assertFalse(result['audit']['mismatched'])
            self.assertIsNone(result['audit']['verified'][0]['fret'])
            self.assertEqual(len(result['wrong']['mismatched']),1);self.assertEqual(len(result['lost']),1)
            self.assertEqual(len(result['unaligned']['unverified_predictions']),1)
            self.assertTrue(result['playback']['checks']['end_tick'])
            self.assertFalse(result['playback']['checks']['note_attacks'])
            for selection in ('1','2'):
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(root/'partial.gp'),selection],capture_output=True,text=True)
                self.assertNotEqual(run.returncode,0);self.assertIn('Slide',run.stderr)


if __name__=='__main__':unittest.main()
