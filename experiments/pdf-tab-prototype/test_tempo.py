import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def tempo_fixture(path,mode='valid'):
    with fitz.open() as doc:
        p=doc.new_page(width=400,height=340)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        p.insert_text((30,30),'Standard tuning',fontname='Times-Roman',fontsize=9)
        p.insert_text((30,45),'= 90',fontname='Times-Roman',fontsize=9)
        p.insert_text((20,45),'\ue1d5',fontname='music',fontsize=9.8)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for row in range(3):
            top=100+row*60
            for y in range(top,top+31,6):p.draw_line((30,y),(350,y),width=.4)
            for x in (30,350):p.draw_line((x,top),(x,top+30),width=.4)
            if row:
                p.insert_text((30,top-2),str(row+1),fontname='Times-Roman',fontsize=6)
                x=140 if mode=='mid_bar' and row==1 else 70
                if mode!='no_unit' or row!=1:
                    p.insert_text((x,top-12),'\ue1d3' if mode=='other_unit' and row==1 else '\ue1d5',fontname='music',fontsize=9.8)
                if mode=='dotted' and row==1:p.insert_text((x+6,top-12),'\ue1e7',fontname='music',fontsize=9.8)
                p.insert_text((x+10,top-12),' = '+str(120 if row==1 else 90),fontname='Times-Bold',fontsize=10)
                if mode=='conflict' and row==1:
                    p.insert_text((x,top-22),'\ue1d5',fontname='music',fontsize=9.8)
                    p.insert_text((x+10,top-22),' = 150',fontname='Times-Bold',fontsize=10)
            for x in (70,140,210,280):
                p.insert_text((x-2,top+14.4),'7',fontname='helv',fontsize=7)
                p.draw_line((x,top+17),(x,top+50),width=.4)
        doc.save(path)


class TempoTests(unittest.TestCase):
    def test_explicit_bar_start_tempos_survive_export_and_excerpt(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'tempo.pdf';tempo_fixture(pdf)
            data=recognize(pdf)
            self.assertEqual([b['tempo'] for s in data['systems'] for b in s['bars']],[90,120,90])
            self.assertFalse(data['tempo_issues'])
            source=root/'recognized.json';source.write_text(json.dumps(data),encoding='utf-8')
            for selection,expected in [('all',90),('2-3',120)]:
                gp=root/f'{selection}.gp';reference=root/f'{selection}.json'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(source),str(gp),selection],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                subprocess.run(['node',str(HERE/'gp-reference.cjs'),str(gp),str(reference)],check=True,capture_output=True)
                result=json.loads(reference.read_text(encoding='utf-8'))
                self.assertEqual(result['tempo'],expected)
                self.assertEqual([e['bpm'] for e in result['tempo_events']],[90,120,90] if selection=='all' else [120,90])
            run=subprocess.run([sys.executable,str(HERE/'verify_export.py'),str(root/'2-3.gp'),str(root/'all.gp'),
                '--track','PDF tablature','--bars','2-3','--out',str(root/'verification.json')],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr+run.stdout)
            for s in data['systems']:
                for b in s['bars']:b['tempo']=90
            source.write_text(json.dumps(data),encoding='utf-8')
            subprocess.run(['node',str(HERE/'gp-export.cjs'),str(source),str(root/'flat.gp')],check=True,capture_output=True)
            run=subprocess.run([sys.executable,str(HERE/'verify_export.py'),str(root/'flat.gp'),str(root/'all.gp'),
                '--track','PDF tablature','--bars','1-3','--out',str(root/'wrong.json')],capture_output=True,text=True)
            self.assertNotEqual(run.returncode,0)
            self.assertIn('tempo changes',json.loads((root/'wrong.json').read_text(encoding='utf-8'))['differences'])

    def test_uncertain_later_tempo_marks_block_export(self):
        for mode in ('other_unit','no_unit','mid_bar','conflict','dotted'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'tempo.pdf';tempo_fixture(pdf,mode)
                data=recognize(pdf);self.assertTrue(data['tempo_issues'])
                if mode=='conflict':self.assertTrue(any('冲突' in issue for issue in data['tempo_issues']))
                source=root/'recognized.json';source.write_text(json.dumps(data),encoding='utf-8')
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(source),str(root/'out.gp')],capture_output=True,text=True)
                self.assertNotEqual(run.returncode,0)
                self.assertFalse((root/'out.gp').exists())


if __name__=='__main__':unittest.main()
