import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer
from test_prototype import fixture

HERE=Path(__file__).parent


def inherited_width_fixture(path,mode='valid'):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
        half=fitz.get_text_length('(12)',fontname='helv',fontsize=7)/2+1.4
        def arc(a,z,y):
            sh=p.new_shape();sh.draw_bezier((a,y),(a+5,y+4),(z-5,y+4),(z,y))
            sh.draw_bezier((z,y),(z-5,y+3),(a+5,y+3),(a,y))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        for i,x in enumerate((70,140,210,280)):
            token='(12)' if i in (1,2) and not (mode=='one_anchor' and i==2) else '12'
            p.insert_text((x-fitz.get_text_length(token,fontname='helv',fontsize=7)/2,114.4),token,fontname='helv',fontsize=7)
            p.draw_line((x,117),(x,150),width=.4)
        arc(75,140-half,112);arc(140+half,210-half,112)
        for y in range(180,211,6):p.draw_line((30,y),(350,y),width=.4)
        for x in (30,350):p.draw_line((x,180),(x,210),width=.5)
        p.insert_text((30,178),'2',fontname='Times-Roman',fontsize=6)
        p.insert_text((70-fitz.get_text_length('12',fontname='helv',fontsize=7)/2,194.4),'12',fontname='helv',fontsize=7)
        p.draw_line((70,197),(70,230),width=.4)
        for x in (140,210):p.draw_line((x,214.5),(x,225),width=.4)
        # First incoming slur ends near the stem; the next uses the wider cutout.
        arc(75,137,192)
        arc(140+half+(1 if mode=='wrong_offset' else 0),210-half,192)
        p.insert_text((280,192),'\ue4e5',fontname='music',fontsize=17)
        if mode=='rest_between':p.insert_text((180,192),'\ue4e5',fontname='music',fontsize=17)
        doc.saveIncr()


class HiddenWidthInheritanceTests(unittest.TestCase):
    def test_recovered_note_keeps_measured_width_for_the_following_tie(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'width.pdf';inherited_width_fixture(pdf)
            data=recognize(pdf);bar=data['systems'][1]['bars'][0]
            self.assertEqual(bar['issues'],[])
            self.assertEqual([v['duration'] for v in bar['beats']],[4,4,4,4])
            self.assertEqual([n['tie'] for v in bar['beats'] for n in v['notes']],[False,True,True])
            raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const score=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
console.log(JSON.stringify(comparePlayback(score,score,0).actual));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(result['note_attacks'],3);self.assertEqual(result['end_tick'],7680)

    def test_missing_measurements_misaligned_arc_and_rest_still_block_continuation(self):
        for mode in ('one_anchor','wrong_offset','rest_between'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'width.pdf';inherited_width_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][1]['bars'][0]
                hidden=[n for v in bar['beats'] for n in v['notes'] if n.get('inferred_from')]
                self.assertEqual(len(hidden),1)
                if mode!='rest_between':self.assertTrue(bar['issues'])
                else:self.assertEqual(sum(not v['notes'] for v in bar['beats']),2)


if __name__=='__main__':unittest.main()
