import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer
from test_staccato import staccato_fixture

HERE=Path(__file__).parent


def outline_marks(page,mode):
    with fitz.open() as doc:
        p=doc.new_page(width=page.rect.width,height=page.rect.height)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        x=159.3+(12 if mode=='wrong_column' else 0)
        y=86 if mode=='above_bend' else 158 if mode=='augmentation' else 116 if mode=='inside_staff' else 106
        if mode=='previous_row':x=163.3;y=158
        for _ in range(2 if mode=='duplicate' else 1):
            p.insert_text((x,y),'\ue4a2',fontname='music',fontsize=40 if mode=='large' else 17)
        if mode=='outlined_text':p.insert_text((148,108),'rit',fontname='Times-Roman',fontsize=7)
        with fitz.open(stream=p.get_svg_image(text_as_path=True).encode(),filetype='svg') as svg:
            with fitz.open(stream=svg.convert_to_pdf(),filetype='pdf') as vector:
                page.show_pdf_page(page.rect,vector,0)


def outline_fixture(path,mode='above'):
    source=path.with_name('source.pdf');staccato_fixture(source,'no_mark',mode=='standard')
    with fitz.open(source) as doc:
        p=doc[0]
        if mode=='chord':p.insert_text((158.0535,124.4),'5',fontname='helv',fontsize=7)
        if mode=='text':p.insert_text((148,108),'rit',fontname='Times-Roman',fontsize=7)
        if mode=='above_bend':p.insert_text((153,98),'full',fontname='Times-Roman',fontsize=7)
        if mode=='grouped_strokes':
            shape=p.new_shape()
            shape.draw_line((30,70),(400,70));shape.draw_line((30,110),(400,110))
            shape.finish(width=.4);shape.commit()
        if mode=='explicit_duplicate':p.insert_text((159.3,106),'\ue4a2',fontname='music',fontsize=17)
        if mode=='previous_row':
            for y in range(180,211,6):p.draw_line((30,y),(400,y),width=.4)
            for x in (30,400):p.draw_line((x,180),(x,210),width=.4)
            p.insert_text((30,178),'2',fontname='Times-Roman',fontsize=6)
            for x in (74,164,254,344):
                p.insert_text((x-1.9465,188.4),'7',fontname='helv',fontsize=7)
                p.draw_line((x,215),(x,235),width=.4)
        outline_marks(p,mode);doc.save(path)


class OutlinedStaccatoTests(unittest.TestCase):
    def test_centered_outline_dot_above_tab_is_staccato_even_on_mixed_font_pages(self):
        for mode in ('above','above_bend','grouped_strokes'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'outlined.pdf';outline_fixture(pdf,mode)
                data=recognize(pdf);bar=data['systems'][0]['bars'][0]
                self.assertEqual([v['notes'][0].get('staccato',False) for v in bar['beats']],[False,True,False,False])
                self.assertEqual([(v['duration'],v['dots']) for v in bar['beats']],[(4,0)]*4)
                self.assertFalse(bar['issues'])

    def test_augmentation_text_other_rows_and_ambiguous_marks_are_not_staccato(self):
        for mode in ('augmentation','inside_staff','wrong_column','large','duplicate','explicit_duplicate',
                     'text','outlined_text','chord','previous_row','standard'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ambiguous.pdf';outline_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('staccato') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_actual_gp_and_midi_shorten_only_the_marked_note(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'outlined.pdf';outline_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js'),notes=[];
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
            self.assertEqual(json.loads(run.stdout),{'notes':[[0,960],[960,480],[1920,960],[2880,960]],'end':3840})


if __name__=='__main__':unittest.main()
