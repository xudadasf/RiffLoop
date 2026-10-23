import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from test_hidden_hold_evidence import base_page,HERE
from test_whole_tie_context import whole_context_fixture


def slide_out_fixture(path,direction='down',mode='valid',string=3,fret=7):
    with fitz.open() as doc:
        p=base_page(doc);y=100+(string-1)*6
        for i,x in enumerate((70,140,152 if mode=='connecting' else 210,280)):
            token='X' if i==1 and mode=='dead' else str(fret)
            size=5 if i==1 and mode=='grace' else 7
            w=fitz.get_text_length(token,fontname='helv',fontsize=size)
            p.insert_text((x-w/2,y+2.4),token,fontname='helv',fontsize=size)
            p.draw_line((x,y+4.5),(x,146),width=.4)
        edge=140+fitz.get_text_length(str(fret),fontname='helv',fontsize=7)/2
        a=edge+(6 if mode=='detached' else 1.7)
        dx=7 if mode=='too_long' else 2 if mode=='too_short' else 4
        dy=(2 if mode=='wrong_slope' else dx)*(1 if direction=='down' else -1)
        cy=y+(3 if mode=='off_string' else 0)
        for _ in range(2 if mode=='duplicate' else 1):
            p.draw_line((a,cy-dy/2),(a+dx,cy+dy/2),width=1.5 if mode=='thick' else .6)
        if mode=='chord':
            other_y=y+12;w=fitz.get_text_length('9',fontname='helv',fontsize=7)
            p.insert_text((140-w/2,other_y+2.4),'9',fontname='helv',fontsize=7)
            p.draw_line((140+w/2+1.7,other_y-2),(140+w/2+5.7,other_y+2),width=.6)
        doc.save(path)


def whole_slide_fixture(path,direction='down',mode='valid'):
    whole_context_fixture(path,'plain')
    with fitz.open(path) as doc:
        p=doc[0];edge=260+fitz.get_text_length('(7)',fontname='helv',fontsize=7)/2
        dy=4 if direction=='down' else -4
        for _ in range(2 if mode=='duplicate' else 1):
            p.draw_line((edge+1.7,112-dy/2),(edge+5.7,112+dy/2),width=.6)
        if mode=='unknown_mark':p.draw_circle((300,145),1,color=None,fill=(0,0,0))
        doc.saveIncr()


class SlideOutTests(unittest.TestCase):
    def test_audit_preserves_direction_missing_and_unaligned_events(self):
        script=r'''
const a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {auditSlideOuts}=require('./experiments/pdf-tab-prototype/audit-slide-outs.cjs');
const {findRegressions}=require('./experiments/pdf-tab-prototype/audit-slides.cjs');
const pred={systems:[{bars:[{number:1,beats:[{notes:[{string:3,fret:7,slide_out:'down'}]}]}]}]};
const ref={staves:[{bars:[{index:0,voices:[{beats:[{index:0,notes:[{string:4,fret:7,isDead:false,slideOutType:a.model.SlideOutType.OutDown}]}]}]}]}]};
const yes=auditSlideOuts(pred,ref,new Set([1])),unaligned=auditSlideOuts(pred,ref,new Set());
pred.systems[0].bars[0].beats[0].notes[0].slide_out='up';
const wrong=auditSlideOuts(pred,ref,new Set([1]));
const event=Object.fromEntries(Object.entries(yes).filter(([k])=>k!=='verified'));
const regressions=findRegressions({cases:[{case:'x',pdf:'x.pdf',track_index:0,...event,verified:[]}]},
 {cases:[{case:'x',pdf:'x.pdf',track_index:0,...yes}]});
console.log(JSON.stringify({yes,wrong,unaligned,regressions}));
'''
        run=subprocess.run(['node','-e',script],cwd=HERE.parent.parent,capture_output=True,text=True,encoding='utf-8')
        self.assertEqual(run.returncode,0,run.stderr);data=json.loads(run.stdout)
        self.assertEqual(len(data['yes']['verified']),1);self.assertFalse(data['yes']['mismatched'])
        self.assertEqual(len(data['wrong']['mismatched']),1);self.assertEqual(len(data['wrong']['not_recognized']),1)
        self.assertFalse(data['unaligned']['verified']);self.assertEqual(len(data['unaligned']['unverified_predictions']),1)
        self.assertEqual(len(data['regressions']),1)

    def test_detached_slide_outs_support_direction_fret_string_and_chords(self):
        for direction,string,fret,mode in (('up',1,15,'valid'),('down',6,3,'valid'),('down',2,7,'chord')):
            with self.subTest(direction=direction,string=string,mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'out.pdf';slide_out_fixture(pdf,direction,mode,string,fret)
                beat=recognize(pdf)['systems'][0]['bars'][0]['beats'][1]
                self.assertEqual(beat['notes'][0].get('slide_out'),direction)
                if mode=='chord':self.assertEqual([n.get('slide_out') for n in beat['notes']],['down','down'])

    def test_connections_and_ambiguous_or_unrelated_strokes_are_not_slide_outs(self):
        for mode in ('connecting','detached','too_short','too_long','wrong_slope','off_string','duplicate','thick','dead','grace'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'out.pdf';slide_out_fixture(pdf,mode=mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('slide_out') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_proven_outgoing_stroke_preserves_whole_hold_but_unknown_ink_still_blocks(self):
        for direction in ('up','down'):
            with self.subTest(direction=direction),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'whole.pdf';whole_slide_fixture(pdf,direction)
                bar=recognize(pdf)['systems'][0]['bars'][1]
                self.assertFalse(bar['issues']);self.assertEqual(bar['beats'][0]['duration'],1)
                self.assertEqual(bar['beats'][0]['notes'][0].get('slide_out'),direction)
        for mode in ('unknown_mark','duplicate'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'whole.pdf';whole_slide_fixture(pdf,mode=mode)
                bar=recognize(pdf)['systems'][0]['bars'][1]
                self.assertIsNone(bar['beats'][0]['duration']);self.assertTrue(bar['issues'])

    def test_gp_roundtrip_and_midi_keep_terminal_slide_and_sustained_timing(self):
        for direction in ('up','down'):
            with self.subTest(direction=direction),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'whole.pdf';whole_slide_fixture(pdf,direction)
                data=recognize(pdf);raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True,encoding='utf-8')
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings()),notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end,slide:a.model.SlideOutType[s.tracks[0].staves[0].bars[1].voices[0].beats[0].notes[0].slideOutType]}));
'''
                run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,encoding='utf-8')
                self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
                self.assertEqual(result['slide'],'Out'+direction.title())
                self.assertEqual(result['notes'],[[0,960],[960,960],[1920,960],[2880,4800]])
                self.assertEqual(result['end'],7680)


if __name__=='__main__':unittest.main()
