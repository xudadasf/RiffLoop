import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from recognize import recognize
from test_prototype import HERE,hidden_staff_chord_fixture


class StaffTieBoundaryTests(unittest.TestCase):
    def test_complete_chord_ties_above_tab_are_not_cut_off_by_fixed_margin(self):
        for mode in ('single','chain'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'near-tab.pdf'
                hidden_staff_chord_fixture(pdf,mode,head_offset=36)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertEqual(bar['issues'],[])
                self.assertEqual(len(bar['beats']),4)
                self.assertEqual([len(v['notes']) for v in bar['beats']],[2]*4)
                self.assertEqual(sum(n['tie'] for v in bar['beats'] for n in v['notes']),4 if mode=='chain' else 2)

    def test_boundary_change_still_requires_complete_unobstructed_evidence(self):
        for mode in ('partial_arcs','no_arcs','shifted_head','missing_stem','rest_between','dead_source','visible_target','crosses_tab'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'near-tab.pdf'
                hidden_staff_chord_fixture(pdf,mode,head_offset=36,arc_depth=7 if mode=='crosses_tab' else 3)
                data=recognize(pdf)
                self.assertFalse(any(n.get('inferred_from')=='standard-heads-and-tie-curves'
                                     for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_export_extends_both_notes_without_retriggering_chord(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'near-tab.pdf'
            hidden_staff_chord_fixture(pdf,head_offset=36)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings()),notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(sorted(result['notes']),[[0,1920]]*2+[[1920,960]]*2+[[2880,960]]*2)
            self.assertEqual(result['end'],3840)


if __name__=='__main__':unittest.main()
