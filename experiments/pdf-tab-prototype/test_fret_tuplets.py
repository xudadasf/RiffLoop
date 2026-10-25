import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def fret_tuplet_fixture(path,font='helv',fret=3,triplet=False):
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=240)
        p.insert_text((30,25),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(400,y),width=.4)
        for x in (30,400):p.draw_line((x,100),(x,130),width=.4)
        p.insert_text((30,98),'1',fontname='Times-Roman',fontsize=6)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        positions=(70,95,120,190,270,350) if triplet else tuple(range(70,351,40))
        for i,x in enumerate(positions):
            token=str(fret) if i==len(positions)-1 else '8'
            width=fitz.get_text_length(token,fontname=font,fontsize=7)
            p.insert_text((x-width/2,132.4),token,fontname=font,fontsize=7)
            p.draw_line((x,135),(x,158),width=.4)
        if triplet:
            p.draw_rect((70,156,120,158),color=None,fill=(0,0,0))
            p.insert_text((93,180),'3',fontname='Times-Roman',fontsize=8)
            for left,right in ((66,90),(100,124)):p.draw_line((left,177),(right,177),width=.4)
            for x in (66,124):p.draw_line((x,173),(x,177),width=.4)
        else:
            for left,right in zip(positions[::2],positions[1::2]):p.draw_rect((left,156,right,158),color=None,fill=(0,0,0))
        doc.save(path)


class FretTupletTests(unittest.TestCase):
    def test_recognized_fret_is_never_reused_as_a_tuplet_digit_across_fonts(self):
        for font in ('helv','hebo','heit'):
            for fret in (3,5,6,7):
                with self.subTest(font=font,fret=fret),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'fret.pdf';fret_tuplet_fixture(pdf,font,fret)
                    bar=recognize(pdf)['systems'][0]['bars'][0]
                    self.assertEqual([v['tuplet'] for v in bar['beats']],[[1,1]]*8)
                    self.assertEqual([v['duration'] for v in bar['beats']],[8]*8)
                    self.assertEqual(bar['beats'][-1]['notes'][0]['fret'],fret)
                    self.assertFalse(bar['issues'])

    def test_real_bracketed_triplet_and_fret_three_can_coexist(self):
        for font in ('helv','hebo','heit'):
            with self.subTest(font=font),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'triplet.pdf';fret_tuplet_fixture(pdf,font,3,True)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertEqual([v['tuplet'] for v in bar['beats']],[[3,2]]*3+[[1,1]]*3)
                self.assertEqual([v['duration'] for v in bar['beats']],[8]*3+[4]*3)
                self.assertFalse(bar['issues'])

    def test_gp_roundtrip_and_midi_keep_plain_and_triplet_rhythm(self):
        for triplet in (False,True):
            with self.subTest(triplet=triplet),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'fret.pdf';fret_tuplet_fixture(pdf,triplet=triplet)
                data=recognize(pdf);raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const score=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const notes=[];let end;
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick+this.tickShift,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
 finishTrack(t,tick){end=tick+this.tickShift;super.finishTrack(t,tick);}
}
new a.midi.MidiFileGenerator(score,new a.Settings(),new Handler(new a.midi.MidiFile())).generate();
console.log(JSON.stringify({notes,end}));'''
                run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
                expected=[[0,320],[320,320],[640,320],[960,960],[1920,960],[2880,960]] if triplet else [[i*480,480] for i in range(8)]
                self.assertEqual(result['notes'],expected);self.assertEqual(result['end'],3840)


if __name__=='__main__':unittest.main()
