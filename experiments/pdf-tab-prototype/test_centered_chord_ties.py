import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from test_prototype import HERE,fixture
from symbols import font_buffer


def centered_chord_fixture(path,mode='valid'):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
        for i in range(5):p.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
        for i,x in enumerate((70,88,180,260)):
            for tone,y in enumerate((58.5,67)):
                hy=y+(2.125 if mode=='different_head' and i==1 and tone==1 else 0)
                p.insert_text((x-2.5,hy),'\ue0a4',fontname='music',fontsize=17)
                if i!=1 or mode=='visible':
                    p.insert_text((x-1.95,114.4+tone*6),str(7+tone),fontname='helv',fontsize=7)
            if not (i==1 and mode=='missing_stem'):p.draw_line((x+2.25,44),(x+2.25,66.5),width=.4)
        if mode=='intervening_rest':p.insert_text((79,112),'\ue4e5',fontname='music',fontsize=17)
        for tone,(y,direction) in enumerate(((56,-1),(69.5,1))):
            if mode=='missing_upper' and tone==0 or mode=='missing_lower' and tone==1:continue
            y+=5 if mode=='distant' else 0
            a=73 if mode=='offset' else 70
            for _ in range(2 if mode=='duplicate' else 1):
                sh=p.new_shape();sh.draw_bezier((a,y),(a+5,y+direction*4),(83,y+direction*4),(88,y))
                sh.draw_bezier((88,y),(83,y+direction*3),(a+5,y+direction*3),(a,y))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
        doc.saveIncr()


class CenteredChordTieTests(unittest.TestCase):
    def test_each_chord_tone_can_have_its_own_centered_tie(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'chord.pdf';centered_chord_fixture(pdf)
            bar=recognize(pdf)['systems'][0]['bars'][0]
            self.assertEqual(bar['issues'],[])
            self.assertEqual(len(bar['beats']),4)
            self.assertEqual([n['tie'] for n in bar['beats'][1]['notes']],[True,True])

    def test_shared_missing_ambiguous_or_displaced_arcs_cannot_restore_chord(self):
        for mode in ('missing_upper','missing_lower','duplicate','offset','distant','different_head','missing_stem','intervening_rest','visible'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'chord.pdf';centered_chord_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('inferred_from')=='standard-heads-and-tie-curves'
                                     for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_actual_export_holds_both_chord_notes(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'chord.pdf';centered_chord_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r"""
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings()),notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end}));
"""
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(sorted(result['notes']),[[0,1920]]*2+[[1920,960]]*2+[[2880,960]]*2)
            self.assertEqual(result['end'],3840)


if __name__=='__main__':unittest.main()
