import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import fitz
from recognize import recognize
from test_prototype import HERE,fixture
from symbols import font_buffer


def upper_tuplet_fixture(path,mode='valid'):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
        for i in range(5):p.draw_line((30,60+i*4.25),(350,60+i*4.25),width=.4)
        positions=[70,100,130,200,250,300]+([115] if mode=='extra_beat' else [])
        for x in positions:
            p.insert_text((x-1.95,114.4),'7',fontname='helv',fontsize=7)
            p.insert_text((x-2.5,68.5),'\ue0a4',fontname='music',fontsize=17)
            p.draw_line((x+2.25,55),(x+2.25,68),width=.4)
        sh=p.new_shape();sh.draw_polyline([(72,55),(132.5,55),(132.5,56.5),(72,56.5),(72,55)])
        sh.finish(color=None,fill=(0,0,0));sh.commit()
        font='helv' if mode=='digit_font' else 'tiit'
        label_x=197.75 if mode=='shifted_label' else 97.75
        p.insert_text((label_x,52),'3',fontname=font,fontsize=9)
        if mode!='no_bracket':
            left=25 if mode=='cross_bar' else 67.75
            for a,z in ((left,95),(105,132.25)):
                for _ in range(2 if mode=='duplicate' else 1):p.draw_line((a,49),(z,49),width=.4)
            if mode!='no_hook':
                for x in (left,132.25):p.draw_line((x,49),(x,47 if mode=='wrong_hook' else 51.125),width=.4)
        doc.saveIncr()


def below_head_tie_fixture(path,mode='valid'):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
        for i in range(5):p.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
        for i,x in enumerate((70,79,160,240)):
            y=62.75 if i==1 and mode=='different_head' else 58.5
            p.insert_text((x-2.5,y),'\ue0a4',fontname='music',fontsize=17)
            if not (i==1 and mode=='no_stem'):p.draw_line((x+2.25,44),(x+2.25,y-.5),width=.4)
            if i!=1 or mode=='visible':
                p.insert_text((x-1.95,114.4),str(7+max(0,i-1)),fontname='helv',fontsize=7)
        if mode=='flag':p.insert_text((81.25,44),'\ue242',fontname='music',fontsize=17)
        if mode=='intervening':p.insert_text((75-1.95,120.4),'5',fontname='helv',fontsize=7)
        if mode!='no_arc':
            a=72 if mode=='offset' else 70
            y=65 if mode=='distant' else 61
            for _ in range(2 if mode=='duplicate' else 1):
                sh=p.new_shape();sh.draw_bezier((a,y),(73,y+4),(76,y+4),(79,y))
                sh.draw_bezier((79,y),(76,y+3),(73,y+3),(a,y))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
        doc.saveIncr()


class UpperTupletAndTieTests(unittest.TestCase):
    def test_upper_triplet_needs_unique_bracket_and_exact_group(self):
        for mode in ('valid','no_bracket','no_hook','wrong_hook','shifted_label','extra_beat','cross_bar','duplicate','digit_font'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'upper.pdf';upper_tuplet_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                actual=[v['tuplet'] for v in bar['beats']]
                if mode=='valid':
                    self.assertEqual(actual,[[3,2]]*3+[[1,1]]*3)
                    self.assertEqual(bar['issues'],[])
                else:self.assertTrue(all(t==[1,1] for t in actual),actual)

    def test_hidden_single_tie_below_heads_needs_complete_evidence(self):
        for mode in ('valid','flag','no_stem','different_head','visible','intervening','no_arc','offset','distant','duplicate'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'tie.pdf';below_head_tie_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                inferred=[v for v in bar['beats'] if any(n.get('inferred_from') for n in v['notes'])]
                if mode in ('valid','flag'):
                    self.assertEqual(len(inferred),1)
                    self.assertTrue(inferred[0]['notes'][0]['tie'])
                    self.assertEqual(inferred[0]['duration'],16 if mode=='flag' else 4)
                else:self.assertEqual(inferred,[])

    def test_gp_and_midi_preserve_upper_triplet_and_hidden_tie(self):
        for kind,make,expected in (
                ('triplet',upper_tuplet_fixture,[[0,320],[320,320],[640,320],[960,960],[1920,960],[2880,960]]),
                ('tie',below_head_tie_fixture,[[0,1920],[1920,960],[2880,960]])):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'source.pdf';make(pdf)
                raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings()),notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile())).generate();
console.log(JSON.stringify(notes));
'''
                run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                self.assertEqual(json.loads(run.stdout),expected)


if __name__=='__main__':unittest.main()
