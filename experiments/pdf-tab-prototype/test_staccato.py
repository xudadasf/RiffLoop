import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def staccato_fixture(path,mode='above',standard=False):
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=240)
        p.insert_text((30,25),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(110,141,6):p.draw_line((30,y),(400,y),width=.4)
        if standard:
            for y in range(60,77,4):p.draw_line((30,y),(400,y),width=.4)
        for x in (30,400):p.draw_line((x,60 if standard else 110),(x,140),width=.4)
        p.insert_text((30,58 if standard else 108),'1',fontname='Times-Roman',fontsize=6)
        for y in (120,128.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for index,x in enumerate((70,160,250,340)):
            for string in ((2,3) if mode=='chord' else (2,)):
                p.insert_text((x-1.9465,110+(string-1)*6+2.4),'7',fontname='helv',fontsize=7)
            p.draw_line((x,145),(x,165),width=.4)
            if standard:
                p.insert_text((x-2.2,68),'\ue0a4',fontname='music',fontsize=17)
                p.draw_line((x+2.5,68),(x+2.5,43),width=.4)
        if mode!='no_mark':
            glyph='\ue1e7' if mode=='augmentation' else '\ue4a3' if mode=='below' else '\ue4a2'
            x=160-.7+(12 if mode=='wrong_column' else 0)
            y=(82 if standard else 150) if mode=='below' else (49 if standard else 106)
            if mode=='outside_staff':y=195
            if mode=='next_system':y=156
            for _ in range(2 if mode=='duplicate' else 1):p.insert_text((x,y),glyph,fontname='music',fontsize=17)
        if mode=='next_system':
            for y in range(180,211,6):p.draw_line((30,y),(400,y),width=.4)
            for x in (30,400):p.draw_line((x,180),(x,210),width=.4)
            p.insert_text((30,178),'2',fontname='Times-Roman',fontsize=6)
            for x in (70,160,250,340):
                p.insert_text((x-1.9465,188.4),'7',fontname='helv',fontsize=7)
                p.draw_line((x,215),(x,235),width=.4)
        doc.save(path)


class StaccatoTests(unittest.TestCase):
    def test_next_system_mark_does_not_shorten_previous_system(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'staccato.pdf';staccato_fixture(pdf,'next_system')
            data=recognize(pdf)
            self.assertEqual([n.get('staccato',False) for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']],
                             [False,False,False,False,False,True,False,False])

    def test_single_note_marks_and_augmentation_are_distinct(self):
        for standard in (False,True):
            for mode in ('above','below'):
                with self.subTest(standard=standard,mode=mode),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'staccato.pdf';staccato_fixture(pdf,mode,standard)
                    data=recognize(pdf);beats=data['systems'][0]['bars'][0]['beats']
                    self.assertEqual([v['notes'][0].get('staccato',False) for v in beats],[False,True,False,False])
                    self.assertFalse(data['systems'][0]['bars'][0]['issues'])
                    self.assertEqual(beats[1]['duration'],4);self.assertEqual(beats[1]['dots'],0)

    def test_ambiguous_chords_and_missing_or_misplaced_marks_are_not_inferred(self):
        for mode in ('chord','no_mark','augmentation','duplicate','wrong_column','outside_staff'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'staccato.pdf';staccato_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('staccato') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))
                if mode=='chord':self.assertEqual(data['staccato_marks'][0]['reason'],'chord-note-scope')

    def test_export_preserves_staccato_and_shortens_release_without_moving_attacks(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'staccato.pdf';staccato_fixture(pdf)
            data=recognize(pdf);raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const {auditStaccato}=require('./experiments/pdf-tab-prototype/audit-staccato.cjs');
const {findRegressions}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load();
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes)n.isStaccato=false;
const pred=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const audit=auditStaccato(pred,actual.tracks[0],new Set([1])),wrong=auditStaccato(pred,flat.tracks[0],new Set([1])),unaligned=auditStaccato(pred,actual.tracks[0],new Set());
const wrap=a=>({cases:[{case:'fixture',pdf:'staccato.pdf',track_index:0,...a}]});
console.log(JSON.stringify({staccato:actual.tracks[0].staves[0].bars[0].voices[0].beats[1].notes[0].isStaccato,playback:comparePlayback(actual,flat,0),audit,wrong,unaligned,
    regressions:findRegressions(wrap(wrong),wrap(audit)),unchanged:findRegressions(wrap(audit),wrap(audit))}));
'''
            run=subprocess.run(['node','-e',script,str(gp),str(raw)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertTrue(result['staccato'])
            self.assertTrue(result['playback']['checks']['note_attacks'])
            self.assertEqual(result['playback']['differences']['note_releases']['examples'],[{'index':1,'actual':[960,1440],'reference':[960,1920]}])
            self.assertEqual(len(result['audit']['verified']),1);self.assertFalse(result['audit']['mismatched'])
            self.assertEqual(len(result['wrong']['mismatched']),1)
            self.assertFalse(result['unaligned']['verified']);self.assertEqual(len(result['unaligned']['unverified_predictions']),1)
            self.assertEqual(len(result['regressions']),1);self.assertFalse(result['unchanged'])


if __name__=='__main__':unittest.main()
