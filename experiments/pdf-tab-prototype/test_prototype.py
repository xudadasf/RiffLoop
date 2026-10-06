"""Small controlled fixtures complement the separately held-out real PDFs."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
import fitz
from recognize import recognize

HERE=Path(__file__).parent


def fixture(path,missing_stem=False):
    doc=fitz.open(); page=doc.new_page(width=400,height=250)
    page.insert_text((30,30),'Standard tuning',fontname='Times-Roman',fontsize=9)
    page.insert_text((30,45),'= 90',fontname='Times-Roman',fontsize=9)
    for y in range(100,131,6): page.draw_line((30,y),(350,y),width=.4)
    for x in [30,350]: page.draw_line((x,100),(x,130),width=.5)
    for i,fret in enumerate(['7','10','0','12']):
        x=70+i*70; y=100+i*6
        w=fitz.get_text_length(fret,fontname='helv',fontsize=7)
        page.insert_text((x-w/2,y+2.4),fret,fontname='helv',fontsize=7)
        if not (missing_stem and i==2): page.draw_line((x,y+5),(x,150),width=.5)
    doc.save(path)


class PrototypeTests(unittest.TestCase):
    def test_pdf_strings_frets_and_quarters_without_reference(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'source.pdf'; fixture(path)
            result=recognize(path); bars=[b for s in result['systems'] for b in s['bars']]
            self.assertEqual(len(bars),1)
            self.assertEqual([(n['string'],n['fret']) for b in bars[0]['beats'] for n in b['notes']],[(1,7),(2,10),(3,0),(4,12)])
            self.assertEqual([b['duration'] for b in bars[0]['beats']],[4]*4)
            self.assertEqual(bars[0]['issues'],[])
            data=Path(folder)/'recognized.json'; data.write_text(json.dumps(result),encoding='utf-8')
            out=Path(folder)/'test.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(out)],capture_output=True)
            self.assertEqual(run.returncode,0,run.stderr.decode('utf-8',errors='replace'))
            self.assertTrue(out.is_file())

    def test_unrecognized_rhythm_blocks_export(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'source.pdf'; fixture(path,missing_stem=True)
            result=recognize(path)
            self.assertTrue(result['systems'][0]['bars'][0]['issues'])
            data=Path(folder)/'recognized.json'; data.write_text(json.dumps(result),encoding='utf-8')
            out=Path(folder)/'test.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(out)],capture_output=True)
            self.assertNotEqual(run.returncode,0)
            self.assertFalse(out.exists())

    def test_image_only_pdf_is_not_silently_converted(self):
        with tempfile.TemporaryDirectory() as folder:
            vector=Path(folder)/'vector.pdf'; fixture(vector)
            with fitz.open(vector) as source:
                pixels=source[0].get_pixmap(matrix=fitz.Matrix(2,2))
            doc=fitz.open(); page=doc.new_page(width=400,height=250)
            page.insert_image(page.rect,pixmap=pixels)
            raster=Path(folder)/'scan.pdf'; doc.save(raster)
            self.assertEqual(recognize(raster)['systems'],[])

    def test_failed_rerun_removes_previous_export(self):
        with tempfile.TemporaryDirectory() as folder:
            out=Path(folder)/'experimental.gp'
            out.write_bytes(b'old successful output')
            run=subprocess.run([sys.executable,str(HERE/'convert.py'),str(Path(folder)/'missing.pdf'),
                                '--out',folder],capture_output=True)
            self.assertNotEqual(run.returncode,0)
            self.assertFalse(out.exists())


if __name__=='__main__': unittest.main()
