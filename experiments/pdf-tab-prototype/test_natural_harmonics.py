import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from test_hidden_hold_evidence import base_page,arc

HERE=Path(__file__).parent


def token(page,x,y,text,size=7):
    width=fitz.get_text_length(text,fontname='helv',fontsize=size)
    page.insert_text((x-width/2,y+size*.34),text,fontname='helv',fontsize=size)
    return width


def harmonic_fixture(path,mode='quarters'):
    with fitz.open() as doc:
        p=base_page(doc)
        if mode in ('whole','chord','oversized_ring','off_center','open_ring','no_ring'):
            strings=(1,2,3) if mode=='chord' else (1,)
            width=0
            for string in strings:width=token(p,140,100+(string-1)*6,'<12>')
            if mode!='no_ring':
                rect=fitz.Rect(140-width/2-2.75,100-width/2-2.75,140+width/2+2.75,100+(strings[-1]-1)*6+width/2+2.75)
                if mode=='oversized_ring':rect.x0-=15;rect.x1+=15
                if mode=='off_center':rect.x0+=3;rect.x1+=3
                if mode=='open_ring':p.draw_bezier(rect.tl,rect.tr,rect.br,rect.bl)
                else:p.draw_oval(rect,width=.4)
        else:
            for i,x in enumerate((70,140,210,280)):
                text=('<7>','(<7>)','<12>','5')[i]
                if mode=='different_kind' and i==1:text='(7)'
                if mode=='malformed':text=('<7','7>','(<12>','<12>)')[i]
                if mode=='annotations':text='7'
                token(p,x,100,text)
                p.draw_line((x,105),(x,146),width=.4)
                if mode=='annotations':token(p,x+12,100,'<19>',5)
            if mode!='no_arc':
                a=70+fitz.get_text_length('<7>',fontname='helv',fontsize=7)/2+1
                z=140-fitz.get_text_length('(<7>)',fontname='helv',fontsize=7)/2-1
                arc(p,a,z,100)
        doc.save(path)


def harmonic_chain(path,ordinary_target=False):
    with fitz.open() as doc:
        p=base_page(doc)
        for x in (70,140,210,280):
            width=token(p,x,100,'<12>');p.draw_line((x,105),(x,146),width=.4)
        arc(p,280+width/2+1,350,100)
        p=base_page(doc);p.draw_line((190,100),(190,130),width=.5)
        text='(12)' if ordinary_target else '(<12>)'
        for x in (90,260):width=token(p,x,100,text)
        arc(p,40,90-width/2-1,100);arc(p,90+width/2+1,260-width/2-1,100)
        doc.save(path)


class NaturalHarmonicTests(unittest.TestCase):
    def test_primary_angle_tokens_and_real_tie_keep_rhythm(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'harmonics.pdf';harmonic_fixture(pdf)
            bar=recognize(pdf)['systems'][0]['bars'][0]
            self.assertFalse(bar['issues']);self.assertEqual([b['duration'] for b in bar['beats']],[4]*4)
            self.assertEqual([(n['fret'],n.get('harmonic'),n['tie']) for b in bar['beats'] for n in b['notes']],
                             [(7,'natural',False),(7,'natural',True),(12,'natural',False),(5,None,False)])

    def test_parentheses_without_arc_or_different_note_kind_do_not_tie(self):
        for mode in ('no_arc','different_kind'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'untied.pdf';harmonic_fixture(pdf,mode)
                notes=[n for s in recognize(pdf)['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']]
                self.assertEqual(len(notes),4);self.assertFalse(any(n['tie'] for n in notes))

    def test_small_artificial_harmonic_annotations_are_not_extra_notes(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'annotations.pdf';harmonic_fixture(pdf,'annotations')
            bar=recognize(pdf)['systems'][0]['bars'][0]
            self.assertEqual(len(bar['beats']),4)
            self.assertTrue(all(len(b['notes'])==1 and not b['notes'][0].get('harmonic') for b in bar['beats']))

    def test_malformed_angle_tokens_are_not_frets(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'bad.pdf';harmonic_fixture(pdf,'malformed')
            bar=recognize(pdf)['systems'][0]['bars'][0]
            self.assertFalse(any(b['notes'] for b in bar['beats']));self.assertTrue(bar['issues'])

    def test_cross_page_and_stemless_chain_require_the_same_harmonic_kind(self):
        for ordinary in (False,True):
            with self.subTest(ordinary_target=ordinary),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'chain.pdf';harmonic_chain(pdf,ordinary)
                bars=[b for s in recognize(pdf)['systems'] for b in s['bars']]
                self.assertEqual(len(bars),3)
                if ordinary:
                    self.assertFalse(bars[1]['beats'][0]['notes'][0]['tie']);self.assertTrue(bars[1]['issues'])
                else:
                    self.assertTrue(all(not b['issues'] for b in bars))
                    self.assertTrue(all(b['beats'][0]['duration']==1 and b['beats'][0]['notes'][0]['tie'] for b in bars[1:]))

    def test_whole_harmonics_use_enclosing_ellipse_for_single_note_or_chord(self):
        for mode,count in (('whole',1),('chord',3)):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'whole.pdf';harmonic_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertFalse(bar['issues']);self.assertEqual(len(bar['beats']),1)
                self.assertEqual(bar['beats'][0]['duration'],1);self.assertEqual(len(bar['beats'][0]['notes']),count)

    def test_arbitrary_enclosures_do_not_supply_whole_duration(self):
        for mode in ('oversized_ring','off_center','open_ring','no_ring'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'bad-ring.pdf';harmonic_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertEqual(len(bar['beats']),1);self.assertIsNone(bar['beats'][0]['duration']);self.assertTrue(bar['issues'])

    def test_export_readback_and_actual_midi_preserve_harmonic_pitch_and_timing(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'harmonics.pdf';harmonic_fixture(pdf)
            data=recognize(pdf);raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings()),notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration,key]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end,
 raw:s.tracks[0].staves[0].bars[0].voices[0].beats.map(b=>b.notes.map(n=>[n.harmonicType,n.harmonicValue]))}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
            result=json.loads(run.stdout)
            self.assertEqual(result['notes'],[[0,1920,83],[1920,960,76],[2880,960,69]])
            self.assertEqual(result['end'],3840);self.assertEqual(result['raw'],[[[1,7]],[[1,7]],[[1,12]],[[0,0]]])
            ordinary=json.loads(json.dumps(data))
            for b in ordinary['systems'][0]['bars'][0]['beats']:
                for n in b['notes']:n.pop('harmonic',None)
            plain=root/'ordinary.gp';raw.write_text(json.dumps(ordinary),encoding='utf-8')
            subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(plain)],capture_output=True,check=True)
            for exported,passed in ((gp,True),(plain,False)):
                report=root/'verified.json'
                run=subprocess.run(['python',str(HERE/'verify_export.py'),str(exported),str(gp),
                                    '--track','PDF tablature','--bars','1-1','--out',str(report)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0 if passed else 1,run.stderr)
                differences=json.loads(report.read_text(encoding='utf-8'))['differences']
                self.assertEqual(differences,[] if passed else ['bar 1: natural harmonic type or position differs'])
            # Unsupported or corrupted fields must not silently become ordinary notes.
            for value in ('unknown','natural'):
                note=data['systems'][0]['bars'][0]['beats'][0]['notes'][0]
                note['harmonic']=value;note['fret']=13
                raw.write_text(json.dumps(data),encoding='utf-8')
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertNotEqual(run.returncode,0)

    def test_harmonic_audit_detects_wrong_positions_lost_flags_and_unaligned_bars(self):
        script=r'''
const {auditHarmonics}=require('./experiments/pdf-tab-prototype/audit-harmonics.cjs');
const {findRegressions}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const track={staves:[{bars:[{index:0,voices:[{beats:[{index:0,notes:[{string:6,fret:7,harmonicType:1,harmonicValue:7}]}]}]}]}]};
const note={string:1,fret:7,harmonic:'natural'},pred={systems:[{bars:[{number:1,beats:[{notes:[note]}]}]}]};
const good=auditHarmonics(pred,track,new Set([1]));
const unaligned=auditHarmonics(pred,track,new Set());
track.staves[0].bars[0].voices[0].beats[0].notes[0].harmonicValue=12;
const wrong=auditHarmonics(pred,track,new Set([1]));
track.staves[0].bars[0].voices[0].beats[0].notes[0].harmonicValue=7;delete note.harmonic;
const lost=auditHarmonics(pred,track,new Set([1]));
const wrap=x=>({cases:[{case:'case-000',pdf:'a.pdf',track_index:0,...x}]});
console.log(JSON.stringify({verified:good.verified.length,wrong:wrong.mismatched.length,
 missing:lost.not_recognized.length,lost:findRegressions(wrap(lost),wrap(good)).length,
 unverified:unaligned.unverified_predictions.length,unalignedVerified:unaligned.verified.length}));
'''
        run=subprocess.run(['node','-e',script],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
        self.assertEqual(json.loads(run.stdout),{'verified':1,'wrong':1,'missing':1,'lost':1,'unverified':1,'unalignedVerified':0})


if __name__=='__main__':unittest.main()
