import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def palm_fixture(path,mode='range'):
    with fitz.open() as doc:
        p=doc.new_page(width=480,height=240)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(110,141,6):p.draw_line((30,y),(450,y),width=.4)
        for x in (30,240,450):p.draw_line((x,110),(x,140),width=.4)
        for number,x in ((1,30),(2,240)):p.insert_text((x,108),str(number),fontname='Times-Roman',fontsize=6)
        for y in (120,128.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        positions=(70,120,170,220,270,320,370,420)
        for i,x in enumerate(positions):
            if mode=='rest' and i==3:
                p.insert_text((x-2,122),'\ue4e5',fontname='music',fontsize=17);continue
            for string in ((2,3) if mode=='chord' or mode=='mixed' and i==3 else (2,)):
                p.insert_text((x-1.9465,110+(string-1)*6+2.4),'7',fontname='helv',fontsize=7)
            p.draw_line((x,145),(x,165),width=.4)
        label='let ring' if mode=='other_label' else 'P.M.'
        start=120 if mode!='shifted_label' else 130
        width=fitz.get_text_length(label,fontname='Times-Bold',fontsize=8)
        p.insert_text((start-width/2,99),label,fontname='Times-Bold',fontsize=8)
        if mode!='isolated':
            end=330 if mode=='shifted_end' else 322.1 if mode=='digit_edge' else 320
            for _ in range(2 if mode=='duplicate_line' else 1):
                p.draw_line((start+width/2+2,96.4),(end,96.4),width=.4,dashes=None if mode=='solid' else '[2 2] 0')
            if mode!='no_cap':p.draw_line((end,94.3),(end,98.5),width=.4)
        doc.save(path)


class PalmMuteTests(unittest.TestCase):
    def test_explicit_range_crosses_bar_and_stops_at_cap(self):
        for mode in ('range','digit_edge','isolated','rest','mixed'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'palm.pdf';palm_fixture(pdf,mode)
                data=recognize(pdf);beats=[v for s in data['systems'] for b in s['bars'] for v in b['beats']]
                self.assertFalse(any(b['issues'] for s in data['systems'] for b in s['bars']))
                wanted={1} if mode=='isolated' else {1,2,3,4,5}
                if mode in ('rest','mixed'):wanted.remove(3)
                self.assertEqual({i for i,v in enumerate(beats) if any(n.get('palm_mute') for n in v['notes'])},wanted)
                if mode=='mixed':self.assertEqual(data['palm_mute_marks'][0]['status'],'partial')

    def test_incomplete_range_and_ambiguous_chord_are_not_inferred(self):
        for mode in ('no_cap','solid','duplicate_line','shifted_end','shifted_label','other_label','chord'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'palm.pdf';palm_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('palm_mute') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))
                if mode=='chord':self.assertEqual(data['palm_mute_marks'][0]['reason'],'chord-note-scope')

    def test_export_roundtrip_and_midi_shortening(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'palm.pdf';palm_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const {auditPalmMute}=require('./experiments/pdf-tab-prototype/audit-palm-mute.cjs');
const {findRegressions}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load(),notes=actual.tracks[0].staves[0].bars.flatMap(b=>b.voices[0].beats.flatMap(v=>v.notes));
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes)n.isPalmMute=false;
const pred=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const audit=auditPalmMute(pred,actual.tracks[0],new Set([1,2])),wrong=auditPalmMute(pred,flat.tracks[0],new Set([1,2])),unaligned=auditPalmMute(pred,actual.tracks[0],new Set());
const wrap=a=>({cases:[{case:'fixture',pdf:'palm.pdf',track_index:0,...a}]});
console.log(JSON.stringify({flags:notes.map(n=>n.isPalmMute),playback:comparePlayback(actual,flat,0),audit,wrong,unaligned,
    regressions:findRegressions(wrap(wrong),wrap(audit)),unchanged:findRegressions(wrap(audit),wrap(audit))}));
'''
            run=subprocess.run(['node','-e',script,str(gp),str(raw)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(result['flags'],[False,True,True,True,True,True,False,False])
            self.assertTrue(result['playback']['checks']['note_attacks'])
            self.assertEqual(result['playback']['differences']['note_releases']['count'],5)
            self.assertEqual(len(result['audit']['verified']),5);self.assertFalse(result['audit']['mismatched'])
            self.assertEqual(len(result['wrong']['mismatched']),5)
            self.assertFalse(result['unaligned']['verified']);self.assertEqual(len(result['unaligned']['unverified_predictions']),5)
            self.assertEqual(len(result['regressions']),5);self.assertFalse(result['unchanged'])
            for e in result['playback']['differences']['note_releases']['examples']:
                self.assertEqual(e['actual'][0],e['reference'][0]);self.assertLess(e['actual'][1],e['reference'][1])


if __name__=='__main__':unittest.main()
