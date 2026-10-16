import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def mixed_fixture(path,mode='after',fault=None):
    xs=[70+35*i for i in range(8)];frets=[7,9,7,5,7,9,7,5]
    last=3 if mode=='before' else 4
    slides=[0,1] if mode=='before' else [1,2] if mode=='middle' else [2,3]
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
            y=112 if fault=='other_string' and i==2 else 106
            token=str(frets[i]);width=fitz.get_text_length(token,fontname='helv',fontsize=7)
            p.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7)
            p.draw_line((x,y+5),(x,150),width=.4);boxes.append((x-width/2,x+width/2))
        for i in range(0,8,2):p.draw_rect(fitz.Rect(xs[i],148,xs[i+1],150),color=None,fill=(0,0,0))
        def label(token,x):
            p.insert_text((x-fitz.get_text_length(token,fontname='Times-Italic',fontsize=6)/2,96),token,fontname='Times-Italic',fontsize=6)
        center=(xs[slides[0]]+xs[slides[-1]+1])/2
        label('sl.',center+15 if fault=='off_center' else center)
        if fault=='duplicate_slide_label':label('sl.',center)
        for i in range(last):
            if i not in slides:
                token='H' if frets[i+1]>frets[i] else 'P'
                if fault=='wrong_hp':token='P' if token=='H' else 'H'
                if fault!='missing_hp':label(token,(xs[i]+xs[i+1])/2)
                if fault=='duplicate_hp':label(token,(xs[i]+xs[i+1])/2)
            if i in slides or fault=='hp_diagonal':
                if fault=='missing_line' and i==slides[0]:continue
                rise=1 if frets[i+1]>frets[i] else -1
                if fault=='wrong_slope' and i==slides[0]:rise=-rise
                p.draw_line((boxes[i][1]+2,106+rise*1.5),(boxes[i+1][0]-2,106-rise*1.5),width=.4)
        if fault!='no_arc':
            for _ in range(2 if fault=='duplicate_arc' else 1):
                sx,tx=xs[0],xs[last];y=103.5
                sh=p.new_shape();sh.draw_bezier((sx,y),(sx,y-8),(tx,y-8),(tx,y))
                sh.draw_bezier((tx,y),(tx,y-7),(sx,y-7),(sx,y))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
        if fault=='rest':p.insert_text((xs[1]+15,112),'\ue4e5',fontname='music',fontsize=17)
        doc.save(path)
    return slides


class MixedSlideTests(unittest.TestCase):
    def test_group_before_after_and_between_hammer_pull_edges(self):
        for mode in ('before','after','middle'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'mixed.pdf';slides=mixed_fixture(pdf,mode);data=recognize(pdf)
                bar=data['systems'][0]['bars'][0];self.assertFalse(bar['issues'])
                self.assertEqual([i for i,v in enumerate(bar['beats']) if v['notes'][0].get('legato_slide')],slides)

    def test_incomplete_conflicting_or_ambiguous_chain_is_not_guessed(self):
        for fault in ('other_string','off_center','duplicate_slide_label','wrong_hp','missing_hp','duplicate_hp',
                      'hp_diagonal','missing_line','wrong_slope','no_arc','duplicate_arc','rest'):
            with self.subTest(fault=fault),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'mixed.pdf';mixed_fixture(pdf,fault=fault);data=recognize(pdf)
                self.assertFalse(any(n.get('legato_slide') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_gp_roundtrip_removes_only_two_slide_attacks(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'mixed.pdf';mixed_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load(),beats=actual.tracks[0].staves[0].bars[0].voices[0].beats;
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes){n.slideOutType=0;n.slideTarget=null;n.slideOrigin=null;}
console.log(JSON.stringify({slides:beats.map(b=>b.notes[0].slideOutType),playback:comparePlayback(actual,flat,0)}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(result['slides'],[0,0,2,2,0,0,0,0])
            self.assertEqual(result['playback']['actual']['note_attacks'],6)
            self.assertEqual(result['playback']['reference']['note_attacks'],8)
            self.assertTrue(result['playback']['checks']['end_tick'])
            self.assertTrue(result['playback']['checks']['tempo_timeline'])


if __name__=='__main__':unittest.main()
