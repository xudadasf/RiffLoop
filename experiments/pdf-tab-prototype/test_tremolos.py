import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import fitz
from recognize import recognize
from test_prototype import HERE,fixture,outlined_music
from symbols import font_buffer


def tremolo_fixture(path,outline=False,mode='normal',string=3):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
        y=100+(string-1)*6;target=140 if mode=='tie' else 70
        for x in (70,140,210,280):
            if mode=='rest' and x==target:p.insert_text((x,112),'\ue4e5',fontname='music',fontsize=17)
            else:
                token='(7)' if mode=='tie' and x==target else 'X' if mode=='dead' and x==target else '7'
                size=5 if mode=='grace' and x==target else 7
                width=fitz.get_text_length(token,fontname='helv',fontsize=size)
                p.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=size)
                if mode=='chord' and x==target:p.insert_text((x-1.95,y+8.4),'5',fontname='helv',fontsize=7)
            if mode!='no_stem' or x!=target:p.draw_line((x,y+4.4),(x,155),width=.4)
        if mode=='eighth':p.draw_rect(fitz.Rect(70,153,84,154.5),color=None,fill=(0,0,0))
        if mode=='dotted':p.insert_text((80,145),'\ue1e7',fontname='music',fontsize=17)
        if mode=='tie':
            sh=p.new_shape();sh.draw_bezier((74,y),(80,y+4),(125,y+4),(134,y))
            sh.draw_bezier((134,y),(125,y+3),(80,y+3),(74,y))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        x=target+(18 if mode=='wrong_column' else 0)
        ty=y+(40 if mode=='off_stem' else 9.5)
        code=0xe221 if mode=='two_strokes' else 0xe222
        for _ in range(2 if mode=='duplicate' else 1):
            if outline:outlined_music(p,[(code,x,ty,17)])
            else:p.insert_text((x,ty),chr(code),fontname='music',fontsize=17)
        doc.saveIncr()


class TremoloTests(unittest.TestCase):
    def test_stemless_tab_requires_matching_standard_staff_tremolo(self):
        for outline in (False,True):
            for mode in ('normal','no_mark','no_head','no_stem','wrong_column','duplicate','chord','detached_stem','two_strokes'):
                with self.subTest(outline=outline,mode=mode),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'mirrored.pdf';tremolo_fixture(pdf,outline,mode='no_stem')
                    with fitz.open(pdf) as doc:
                        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
                        for i in range(5):p.draw_line((30,60+i*4.25),(350,60+i*4.25),width=.4)
                        if mode!='no_head':p.insert_text((67.5,64.25),'\ue0a4',fontname='music',fontsize=17)
                        if mode=='chord':p.insert_text((67.5,68.5),'\ue0a4',fontname='music',fontsize=17)
                        if mode!='no_stem':p.draw_line((67.75,70 if mode=='detached_stem' else 64.8),(67.75,84.4),width=.4)
                        if mode!='no_mark':
                            x=90 if mode=='wrong_column' else 67.75
                            code=0xe221 if mode=='two_strokes' else 0xe222
                            for _ in range(2 if mode=='duplicate' else 1):
                                if outline:outlined_music(p,[(code,x,76,17)])
                                else:p.insert_text((x,76),chr(code),fontname='music',fontsize=17)
                        doc.saveIncr()
                    data=recognize(pdf);beat=data['systems'][0]['bars'][0]['beats'][0]
                    self.assertEqual(beat.get('tremolo_strokes'),3 if mode=='normal' else None)

    def test_three_strokes_on_a_quarter_stem_from_text_and_paths(self):
        for outline in (False,True):
            for string in (1,3,6):
                with self.subTest(outline=outline,string=string),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'tremolo.pdf';tremolo_fixture(pdf,outline,string=string)
                    data=recognize(pdf);bar=data['systems'][0]['bars'][0]
                    self.assertEqual(bar['issues'],[])
                    self.assertEqual([v['duration'] for v in bar['beats']],[4]*4)
                    self.assertEqual([v.get('tremolo_strokes') for v in bar['beats']],[3,None,None,None])

    def test_unconfirmed_or_unsupported_tremolos_do_not_change_playback(self):
        for outline in (False,True):
            for mode in ('rest','dead','grace','chord','no_stem','eighth','dotted','tie','wrong_column','off_stem','duplicate','two_strokes'):
                with self.subTest(outline=outline,mode=mode),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'tremolo.pdf';tremolo_fixture(pdf,outline,mode)
                    data=recognize(pdf)
                    self.assertFalse(any(v.get('tremolo_strokes') for s in data['systems'] for b in s['bars'] for v in b['beats']))

    def test_actual_gp_and_midi_repeat_at_32nd_note_intervals(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'tremolo.pdf';tremolo_fixture(pdf,True)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {auditTremolos}=require('./experiments/pdf-tab-prototype/audit-tremolos.cjs');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile())).generate();
const pred=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const beat=s.tracks[0].staves[0].bars[0].voices[0].beats[0],strokes=beat.tremoloPicking?.marks;
const verified=auditTremolos(pred,s.tracks[0],new Set([1]));
const unaligned=auditTremolos(pred,s.tracks[0],new Set());
if(beat.tremoloPicking)beat.tremoloPicking.marks=2;
const wrong=auditTremolos(pred,s.tracks[0],new Set([1]));
console.log(JSON.stringify({notes,strokes,verified,unaligned,wrong}));
'''
            run=subprocess.run(['node','-e',script,str(gp),str(raw)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(result.get('strokes'),3)
            self.assertEqual(result['notes'],[[i*120,120] for i in range(8)]+[[960,960],[1920,960],[2880,960]])
            self.assertEqual(len(result['verified']['verified']),1)
            self.assertEqual(result['verified']['mismatched'],[])
            self.assertEqual(len(result['unaligned']['unverified_predictions']),1)
            self.assertEqual(len(result['unaligned']['unaligned_reference']),1)
            self.assertEqual(len(result['wrong']['mismatched']),1)
            self.assertEqual(len(result['wrong']['not_recognized']),1)


if __name__=='__main__':unittest.main()
