import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from test_hidden_hold_evidence import arc,beam,base_page

HERE=Path(__file__).parent


def annotated_fixture(path,mode='valid',string=3,dotted=True,calibrated=False):
    with fitz.open() as doc:
        p=base_page(doc)
        for i,(x,si,fret) in enumerate(((70,5,3),(105,4,2),(140,5,3),(175,string,4),(290,4,2))):
            if i==1 and mode=='partial_same_string':si=5
            y=100+(si-1)*6;token='X' if i==3 and mode=='dead_source' else str(fret)
            if i==1 and mode=='partial_dead_target':token='X'
            if i==1 and mode=='partial_parenthesized_target':token='(2)'
            size=5 if i==3 and mode=='grace_source' else 7
            w=fitz.get_text_length(token,fontname='helv',fontsize=size)
            p.insert_text((x-w/2,y+2.4),token,fontname='helv',fontsize=size)
            p.draw_line((x,y+4.5),(x,146),width=.4)
            if i in (0,3):
                label='16' if mode=='plain_label' and i==3 else '<16>'
                sz=7 if mode=='large_label' and i==3 else 5
                lx=x+w/2+(8 if mode=='distant_label' and i==3 else 2)
                ly=y+(6 if mode=='wrong_label_string' and i==3 else 0)
                if mode!='missing_label' or i!=3:
                    p.insert_text((lx,ly+1.7),label,fontname='helv',fontsize=sz)
                    if i==3 and mode=='duplicate_label':p.insert_text((lx,ly+1.7),label,fontname='helv',fontsize=sz)
                edge=lx+fitz.get_text_length(label,fontname='helv',fontsize=sz)-.1
                if i==0:
                    # A nearby other-string attack alone cannot prove a hidden hold.
                    if mode!='partial_no_arc':
                        for _ in range(2 if mode=='partial_duplicate_arc' else 1):
                            arc(p,edge,96 if mode=='partial_wrong_padding' else 99.4,
                                y+(3 if mode=='partial_off_string' else 0))
                elif mode!='no_arc':
                    for _ in range(2 if mode=='duplicate_arc' else 1):
                        arc(p,edge+(4 if mode=='detached_arc' else 0),
                            199 if mode=='far_endpoint' else 204.4,y+(3 if mode=='off_string_arc' else 0))
            if i==3 and mode=='source_chord':p.insert_text((x-1.95,y+8.4),'7',fontname='helv',fontsize=7)
        beam(p,70,105,144);beam(p,140,175,144)
        p.insert_text((290,146),'\ue241',fontname='music',fontsize=17)
        if mode!='missing_stem':p.draw_line((210,120 if mode=='long_stem' else 135),(210,146),width=.4)
        if mode=='second_stem':p.draw_line((211,135),(211,146),width=.4)
        if dotted:p.insert_text((212,146),'\ue1e7',fontname='music',fontsize=17)
        if mode in ('visible_target','other_string_target'):
            y=100+(string-1)*6+(6 if mode=='other_string_target' else 0)
            p.insert_text((208.05,y+2.4),'9',fontname='helv',fontsize=7)
        if mode=='intervening_note':p.insert_text((197,102.4),'8',fontname='helv',fontsize=7)
        if mode=='intervening_rest':p.insert_text((197,112),'\ue4e5',fontname='music',fontsize=17)
        if mode in ('H','P','sl.'):
            p.insert_text((194,100+(string-1)*6-5),mode,fontname='Times-Roman',fontsize=6)
        if mode=='partial_conflict':p.insert_text((90,119),'H',fontname='Times-Roman',fontsize=6)
        if mode=='partial_intervening_rest':p.insert_text((96,112),'\ue4e5',fontname='music',fontsize=17)
        if calibrated:
            p=doc.new_page(width=400,height=240);font='cour' if mode=='different_font' else 'helv'
            for y in range(100,131,6):p.draw_line((30,y),(350,y),width=.4)
            for x in (30,350):p.draw_line((x,100),(x,130),width=.5)
            for i,x in enumerate((70,140,210,280)):
                token='(12)' if i in (1,2) and not (mode=='one_sample' and i==2) else '12'
                w=fitz.get_text_length(token,fontname=font,fontsize=7)
                p.insert_text((x-w/2,114.4),token,fontname=font,fontsize=7)
                p.draw_line((x,117),(x,150),width=.4)
            half=fitz.get_text_length('(12)',fontname='helv',fontsize=7)/2+1.4
            arc(p,75,140-half,112);arc(p,140+half,210-half+(1 if mode=='inconsistent_samples' else 0),112)
        doc.save(path)


class AnnotatedHiddenHoldTests(unittest.TestCase):
    def test_partial_hold_requires_independently_measured_cutout(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'hold.pdf';annotated_fixture(pdf,calibrated=True)
            bar=recognize(pdf)['systems'][0]['bars'][0]
            self.assertFalse(bar['issues'])
            self.assertEqual([(n['string'],n['fret'],n['tie']) for n in bar['beats'][1]['notes']],[(4,2,False),(5,3,True)])

    def test_partial_hold_rejects_bad_measurements_and_conflicting_destinations(self):
        for mode in ('one_sample','different_font','inconsistent_samples','partial_wrong_padding','partial_no_arc',
                     'partial_duplicate_arc','partial_off_string','partial_conflict','partial_dead_target',
                     'partial_same_string','partial_parenthesized_target','partial_intervening_rest'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'hold.pdf';annotated_fixture(pdf,mode,calibrated=True)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertFalse(any(n['tie'] and n['string']==5 for v in bar['beats'] for n in v['notes']))

    def test_unique_annotation_arc_and_short_stem_recover_the_printed_duration(self):
        for string in (2,3):
            for dotted in (False,True):
                with self.subTest(string=string,dotted=dotted),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'hold.pdf';annotated_fixture(pdf,string=string,dotted=dotted)
                    bar=recognize(pdf)['systems'][0]['bars'][0]
                    held=[v for v in bar['beats'] if any(n['tie'] for n in v['notes'])]
                    self.assertEqual(len(held),1)
                    self.assertEqual((held[0]['duration'],held[0]['dots']),(4,int(dotted)))
                    self.assertEqual([(n['string'],n['fret']) for n in held[0]['notes']],[(string,4)])
                    self.assertNotIn('tie_annotation_right',held[0]['notes'][0])
                    self.assertEqual(bool(bar['issues']),not dotted)  # Never fill a deficit from the meter.

    def test_missing_or_ambiguous_evidence_does_not_invent_a_destination(self):
        for mode in ('no_arc','duplicate_arc','detached_arc','off_string_arc','far_endpoint',
                     'missing_label','plain_label','large_label','distant_label','wrong_label_string',
                     'duplicate_label','missing_stem','second_stem','long_stem','visible_target',
                     'other_string_target','intervening_note','intervening_rest','source_chord',
                     'dead_source','grace_source','H','P','sl.'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'hold.pdf';annotated_fixture(pdf,mode)
                data=recognize(pdf)
                # A full-size <16> is a separate natural harmonic, not this annotation.
                self.assertFalse(any(n.get('inferred_from') and n.get('harmonic')!='natural'
                                     for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_gp_and_midi_keep_the_hold_without_a_new_attack(self):
        self.check_midi(False)
        self.check_midi(True)

    def check_midi(self,calibrated):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'hold.pdf';annotated_fixture(pdf,calibrated=calibrated)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True,encoding='utf-8')
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings()),notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
const held=s.tracks[0].staves[0].bars[0].voices[0].beats[4];
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end,tie:held.notes[0].isTieDestination}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,encoding='utf-8')
            self.assertEqual(run.returncode,0,run.stderr);data=json.loads(run.stdout)
            expected=[[0,960 if calibrated else 480],[480,480],[960,480],[1440,1920],[3360,480]]
            if calibrated:expected.extend([[3840,2880],[6720,960]])
            self.assertEqual(data['notes'],expected)
            self.assertTrue(data['tie']);self.assertEqual(data['end'],7680 if calibrated else 3840)


if __name__=='__main__':unittest.main()
