import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def transition_fixture(path,kind='partial',mode='normal',shift=2):
    strings=(1,2,3) if kind=='partial' else (5,6)
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=240)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(400,y),width=.4)
        for x in (30,220,400):p.draw_line((x,100),(x,130),width=.4)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for number,x in ((1,30),(2,220)):p.insert_text((x,98),str(number),fontname='Times-Roman',fontsize=6)
        edges={}
        for i,x in enumerate((70,110,150,190,245,285,325,365)):
            active=strings if i==3 or i==4 and kind=='dead' else (strings[0],)
            if i==4 and mode=='other_string':active=(strings[0]+1,)
            for j,string in enumerate(active):
                token=('13' if kind=='partial' else '20') if i==3 else str(13+shift) if i==4 and kind=='partial' else 'X' if i==4 else '8'
                if i==3 and kind=='partial' and j:token=str(10+j)
                if mode=='dead_source' and i==3:token='X'
                if mode=='mixed_target' and i==4 and j==0:token='8'
                width=fitz.get_text_length(token,fontname='helv',fontsize=7);y=100+(string-1)*6
                p.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7);edges[i,string]=(x-width/2,x+width/2)
            p.draw_line((x,100+(max(active)-1)*6+5),(x,155),width=.4)
        if mode!='no_label':p.insert_text((214,94),'sl.',fontname='Times-Italic',fontsize=6)
        side=-1 if kind=='partial' else 1;y=100+((min(strings) if side<0 else max(strings))-1)*6+side*2.5
        for _ in range(0 if mode=='no_arc' else 2 if mode=='duplicate_arc' else 1):
            sh=p.new_shape();sh.draw_bezier((190,y),(196,y+side*8),(239,y+side*8),(245,y))
            sh.draw_bezier((245,y),(239,y+side*7),(196,y+side*7),(190,y));sh.finish(color=None,fill=(0,0,0));sh.commit()
        for string in ((strings[0],) if kind=='partial' else strings):
            if (4,string) not in edges or mode=='partial_lines' and string==strings[-1]:continue
            y=100+(string-1)*6;rise=(1 if shift>0 else -1) if kind=='partial' else -1
            if mode=='wrong_slope':rise=-rise
            for _ in range(0 if mode=='no_line' else 2 if mode=='duplicate_line' else 1):
                p.draw_line((edges[3,string][1]+2,y+rise*1.5),(edges[4,string][0]-2,y-rise*1.5),width=.4)
        doc.save(path)


class PartialDeadChordSlideTests(unittest.TestCase):
    def test_identifies_only_the_connected_chord_tones(self):
        for kind,shift in (('partial',2),('partial',-4),('dead',2)):
            with self.subTest(kind=kind,shift=shift),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'slide.pdf';transition_fixture(pdf,kind,shift=shift)
                data=recognize(pdf);bars=data['systems'][0]['bars'];source=bars[0]['beats'][3]['notes'];target=bars[1]['beats'][0]['notes']
                self.assertFalse(any(b['issues'] for b in bars))
                self.assertEqual([n['string'] for n in source if n.get('legato_slide')],[1] if kind=='partial' else [5,6])
                self.assertTrue(all(n.get('slide_source_bar')==1 for n in target))
                if kind=='dead':self.assertTrue(all(n['dead'] and n['fret'] is None for n in target))

    def test_missing_or_ambiguous_evidence_is_not_promoted(self):
        for kind in ('partial','dead'):
            modes=['no_label','no_arc','no_line','duplicate_line','duplicate_arc','other_string','dead_source']
            modes+=['wrong_slope'] if kind=='partial' else ['partial_lines','mixed_target']
            for mode in modes:
                with self.subTest(kind=kind,mode=mode),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'slide.pdf';transition_fixture(pdf,kind,mode)
                    data=recognize(pdf)
                    self.assertFalse(any(n.get('legato_slide') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_gp_roundtrip_audit_and_actual_attack_count(self):
        for kind in ('partial','dead'):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'slide.pdf';transition_fixture(pdf,kind)
                data=recognize(pdf);raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const {auditSlides}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const score=load(),flat=load(),pred=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes){n.slideOutType=0;n.slideOrigin=null;n.slideTarget=null;}
console.log(JSON.stringify({audit:auditSlides(pred,score.tracks[0],new Set([1,2])),playback:comparePlayback(score,flat,0)}));'''
                run=subprocess.run(['node','-e',script,str(gp),str(raw)],cwd=HERE.parent.parent,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr);r=json.loads(run.stdout);count=1 if kind=='partial' else 2
                self.assertEqual(len(r['audit']['verified']),count);self.assertFalse(r['audit']['mismatched'])
                self.assertEqual(r['playback']['reference']['note_attacks']-r['playback']['actual']['note_attacks'],count)
                self.assertTrue(r['playback']['checks']['end_tick']);self.assertTrue(r['playback']['checks']['tempo_timeline'])
                for selection in ('1','2'):
                    run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(root/'partial.gp'),selection],capture_output=True,text=True)
                    self.assertNotEqual(run.returncode,0);self.assertIn('Slide',run.stderr)


if __name__=='__main__':unittest.main()
