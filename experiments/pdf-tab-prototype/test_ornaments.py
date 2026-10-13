import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer
from test_prototype import outlined_music

HERE=Path(__file__).parent
GLYPHS={0xe567:'turn',0xe568:'inverted-turn',0xe56c:'upper-mordent',0xe56d:'lower-mordent'}


def ornament_fixture(path,code=0xe56c,outline=False,mode='normal'):
    with fitz.open() as doc:
        p=doc.new_page(width=400,height=250)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(370,y),width=.4)
        for x in (30,370):p.draw_line((x,100),(x,130),width=.4)
        p.insert_text((30,98),'1',fontname='Times-Roman',fontsize=6)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for i,x in enumerate((70,160,250,340)):
            for y in ((106,112) if mode=='chord' and i==1 else (106,)):
                token='X' if mode=='dead' and i==1 else '7'
                width=fitz.get_text_length(token,fontname='helv',fontsize=7)
                p.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7)
            p.draw_line((x,135),(x,155),width=.4)
        if mode!='no_mark':
            # Bravura music symbols are centered above the intended note.
            font=fitz.Font(fontbuffer=font_buffer())
            center=font.text_length(chr(code),fontsize=17)/2
            x=160-center+(15 if mode=='wrong_column' else 0)
            y=70 if mode=='outside_staff' else 96
            for _ in range(2 if mode=='duplicate' else 1):
                if outline:outlined_music(p,[(code,x,y,17)])
                else:p.insert_text((x,y),chr(code),fontname='music',fontsize=17)
        doc.save(path)


class OrnamentTests(unittest.TestCase):
    def test_text_and_outline_ornaments_preserve_written_rhythm(self):
        for code,name in GLYPHS.items():
            for outline in (False,True):
                with self.subTest(name=name,outline=outline),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'ornament.pdf';ornament_fixture(pdf,code,outline)
                    data=recognize(pdf);bar=data['systems'][0]['bars'][0]
                    self.assertFalse(bar['issues'])
                    self.assertEqual([v['duration'] for v in bar['beats']],[4]*4)
                    self.assertEqual([n.get('ornament') for v in bar['beats'] for n in v['notes']],[None,name,None,None])

    def test_ambiguous_or_missing_marks_are_not_assigned(self):
        for mode in ('chord','dead','no_mark','wrong_column','duplicate','outside_staff'):
            for outline in (False,True):
                with self.subTest(mode=mode,outline=outline),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'ornament.pdf';ornament_fixture(pdf,outline=outline,mode=mode)
                    data=recognize(pdf)
                    self.assertFalse(any(n.get('ornament') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))
                    if mode=='chord':self.assertEqual(data.get('ornament_marks',[{}])[0].get('reason'),'chord-note-scope')

    def test_trill_and_vibrato_glyphs_are_not_replaced_with_mordents(self):
        for code in (0xe566,0xeab2):
            for outline in (False,True):
                with self.subTest(code=code,outline=outline),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'ornament.pdf';ornament_fixture(pdf,code,outline)
                    data=recognize(pdf)
                    self.assertFalse(any(n.get('ornament') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_actual_gp_roundtrip_and_midi_add_the_short_attacks(self):
        for code,name in GLYPHS.items():
            with self.subTest(name=name),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'ornament.pdf';ornament_fixture(pdf,code,True)
                raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const {auditOrnaments}=require('./experiments/pdf-tab-prototype/audit-ornaments.cjs');
const {findRegressions}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load();
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes)n.ornament=0;
const pred=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const audit=auditOrnaments(pred,actual.tracks[0],new Set([1])),wrong=auditOrnaments(pred,flat.tracks[0],new Set([1])),unaligned=auditOrnaments(pred,actual.tracks[0],new Set());
const wrap=x=>({cases:[{case:'fixture',pdf:'ornament.pdf',track_index:0,...x}]});
console.log(JSON.stringify({ornament:actual.tracks[0].staves[0].bars[0].voices[0].beats[1].notes[0].ornament,playback:comparePlayback(actual,flat,0),audit,wrong,unaligned,
    regressions:findRegressions(wrap(wrong),wrap(audit)),unchanged:findRegressions(wrap(audit),wrap(audit))}));
'''
                run=subprocess.run(['node','-e',script,str(gp),str(raw)],cwd=HERE.parent.parent,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
                self.assertEqual(result['ornament'],{'turn':2,'inverted-turn':1,'upper-mordent':3,'lower-mordent':4}[name])
                self.assertEqual(result['playback']['actual']['note_attacks'],7 if 'turn' in name else 6)
                self.assertEqual(result['playback']['reference']['note_attacks'],4)
                self.assertTrue(result['playback']['checks']['end_tick'])
                self.assertEqual(len(result['audit']['verified']),1);self.assertFalse(result['audit']['mismatched'])
                self.assertEqual(len(result['wrong']['mismatched']),1)
                self.assertFalse(result['unaligned']['verified']);self.assertEqual(len(result['unaligned']['unverified_predictions']),1)
                self.assertEqual(len(result['regressions']),1);self.assertFalse(result['unchanged'])

    def test_unknown_ornament_blocks_export(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'ornament.pdf';ornament_fixture(pdf)
            data=recognize(pdf);data['systems'][0]['bars'][0]['beats'][1]['notes'][0]['ornament']='unknown'
            raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8')
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(root/'out.gp')],capture_output=True,text=True)
            self.assertNotEqual(run.returncode,0);self.assertIn('Unknown ornament',run.stderr)
            self.assertFalse((root/'out.gp').exists())


if __name__=='__main__':unittest.main()
