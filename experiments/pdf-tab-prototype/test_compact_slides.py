import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def compact_fixture(path,mode='pair'):
    chain=mode not in ('pair','grace');positions=(70,83.5,97 if chain else 150,190,245,285,325,365)
    if mode=='grace':positions=(70,83.5,120,155,190,245,285,325,365)
    source=1 if chain else 0;target=source+1
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=240)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(400,y),width=.4)
        for x in (30,220,400):p.draw_line((x,100),(x,130),width=.4)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for number,x in ((1,30),(2,220)):p.insert_text((x,98),str(number),fontname='Times-Roman',fontsize=6)
        boxes={}
        for i,x in enumerate(positions):
            y=112 if mode=='other_string' and i==0 else 106
            fret=(17-i*2) if mode=='down_chain' and i<3 else 13+i*2 if i<3 else 15
            size=5 if mode=='grace' and i==0 else 7
            token=str(fret);width=fitz.get_text_length(token,fontname='helv',fontsize=size)
            p.insert_text((x-width/2,y+size*.34),token,fontname='helv',fontsize=size)
            if size==7:p.draw_line((x,y+5),(x,150),width=.4)
            boxes[i]=(x-width/2,x+width/2)
        def label(token,x):
            width=fitz.get_text_length(token,fontname='Times-Italic',fontsize=6)
            p.insert_text((x-width/2,96),token,fontname='Times-Italic',fontsize=6)
        label('sl.',(positions[source]+positions[target])/2)
        if chain and mode!='missing_label':label('P' if mode in ('wrong_label','down_chain') else 'H',(positions[0]+positions[1])/2)
        if mode=='rest':p.insert_text((76,112),'\ue4e5',fontname='music',fontsize=17)
        if mode!='no_arc':
            sx,tx=positions[0],positions[target];y=103.5
            sh=p.new_shape();sh.draw_bezier((sx,y),(sx,y-8),(tx,y-8),(tx,y))
            sh.draw_bezier((tx,y),(tx,y-7),(sx,y-7),(sx,y))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        rise=-1 if mode in ('wrong_slope','down_chain') else 1
        left=boxes[source][1]+(-1 if mode=='line_over_digit' else 2)
        p.draw_line((left,106+rise*1.5),(boxes[target][0]-2,106-rise*1.5),width=.4)
        doc.save(path)


class CompactSlideTests(unittest.TestCase):
    def test_grace_slide_keeps_written_rhythm_and_has_a_target(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'compact.pdf';compact_fixture(pdf,'grace')
            data=recognize(pdf);bar=data['systems'][0]['bars'][0]
            self.assertFalse(bar['issues']);self.assertTrue(bar['beats'][0]['grace'])
            self.assertTrue(bar['beats'][0]['notes'][0].get('legato_slide'))
            self.assertEqual(bar['beats'][1]['notes'][0].get('slide_source_bar'),1)

    def test_short_lines_and_shared_legato_curves(self):
        for mode in ('pair','chain','down_chain'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'compact.pdf';compact_fixture(pdf,mode)
                data=recognize(pdf);beats=data['systems'][0]['bars'][0]['beats']
                self.assertFalse(data['systems'][0]['bars'][0]['issues'])
                self.assertEqual([n.get('legato_slide',False) for v in beats for n in v['notes']],
                                 [True,False,False,False] if mode=='pair' else [False,True,False,False])

    def test_shared_curve_requires_each_transition_to_be_explained(self):
        for mode in ('missing_label','wrong_label','wrong_slope','no_arc','other_string','rest','line_over_digit'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'compact.pdf';compact_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('legato_slide') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_shared_curve_export_removes_only_slide_target_attack(self):
        for mode in ('chain','grace'):
            with tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'compact.pdf';compact_fixture(pdf,mode)
                raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load();
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes){n.slideOutType=0;n.slideTarget=null;n.slideOrigin=null;}
console.log(JSON.stringify(comparePlayback(actual,flat,0)));
'''
                run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
                self.assertEqual(result['actual']['note_attacks'],7 if mode=='chain' else 8);self.assertEqual(result['reference']['note_attacks'],8 if mode=='chain' else 9)


if __name__=='__main__':unittest.main()
