import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from test_hidden_hold_evidence import base_page,arc,beam
from test_natural_harmonics import token

HERE=Path(__file__).parent


def mixed_half_fixture(path,mode='valid'):
    with fitz.open() as doc:
        hy,fy=(112,100) if mode=='upper_attack' else (100,112)
        origin,fret=('14','12') if mode=='two_digits' else ('5','7')
        p=base_page(doc)
        if mode!='cross_page':p.draw_line((150,100),(150,130),width=.5)
        token(p,70,hy,origin);p.draw_circle((70,hy),5 if mode=='two_digits' else 4,width=.4)
        if mode=='cross_page':arc(p,75,350,hy);p=base_page(doc)
        token(p,190,hy,'(6)' if mode=='different_fret' else '('+origin+')')
        token(p,190,fy,fret)
        if mode=='extra_attack':token(p,190,124,'3')
        for x in (250,310):
            token(p,x,fy,fret);p.draw_line((x,fy+5),(x,146),width=.4)
        if mode!='no_arc':
            half=fitz.get_text_length('('+origin+')',fontname='helv',fontsize=7)/2+1
            arc(p,40 if mode=='cross_page' else 75,190-half,hy)
        if mode=='rest_between':p.insert_text((160,112),'\ue4e5',fontname='music',fontsize=17)
        if mode!='no_stem':p.draw_line((190,134.5 if mode=='long_stem' else 139),(190,145),width=.4)
        if mode=='two_stems':p.draw_line((190.8,139),(190.8,145),width=.4)
        if mode=='beam':beam(p,190,250,143)
        if mode=='flag':p.insert_text((190,145),'\ue240',fontname='music',fontsize=17)
        if mode!='no_ring':
            cx=193 if mode=='off_center' else 190;cy=hy if mode=='wrong_note' else fy
            for _ in range(2 if mode=='duplicate_ring' else 1):
                if mode=='open_curve':p.draw_bezier((cx+4,cy),(cx+4,cy+4),(cx-4,cy+4),(cx-4,cy))
                else:p.draw_circle((cx,cy),4,width=.4)
        doc.save(path)


class MixedHalfChordTests(unittest.TestCase):
    def test_confirmed_hold_and_circled_attack_share_the_half_note_stem(self):
        for mode in ('valid','upper_attack','two_digits','cross_page'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'mixed.pdf';mixed_half_fixture(pdf,mode)
                bars=[b for s in recognize(pdf)['systems'] for b in s['bars']]
                self.assertTrue(all(not b['issues'] for b in bars))
                self.assertEqual([b['duration'] for b in bars[1]['beats']],[2,4,4])
                self.assertEqual([(n['string'],n['tie']) for n in bars[1]['beats'][0]['notes']],
                                 [(1,False),(3,True)] if mode=='upper_attack' else [(1,True),(3,False)])

    def test_incomplete_or_conflicting_evidence_does_not_lengthen_the_beat(self):
        for mode in ('no_arc','different_fret','rest_between','extra_attack','no_stem','long_stem',
                     'two_stems','beam','flag','no_ring','off_center','wrong_note','duplicate_ring','open_curve'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'bad.pdf';mixed_half_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][0]['bars'][1]
                beat=next(b for b in bar['beats'] if abs(b['x']-190)<1)
                self.assertNotEqual(beat['duration'],2)

    def test_gp_and_midi_keep_the_attack_separate_from_the_continuing_note(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'mixed.pdf';mixed_half_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js'),notes=[];
const score=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration,key]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(score,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
            actual=json.loads(run.stdout)
            self.assertEqual(actual['notes'],[[0,5760,69],[3840,1920,62],[5760,960,62],[6720,960,62]])
            self.assertEqual(actual['end'],7680)


if __name__=='__main__':unittest.main()
