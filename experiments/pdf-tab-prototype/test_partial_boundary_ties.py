"""A boundary tie can continue one string while another is attacked again."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import fitz
from recognize import recognize
from test_prototype import HERE,boundary_fixture


def partial_fixture(path,page_break=False,extra='both',token='9',**options):
    boundary_fixture(path,page_break=page_break,**options)
    with fitz.open(path) as doc:
        for index in range(2):
            if extra!='both' and extra!=('target' if index else 'source'):continue
            page=doc[index if page_break else 0]
            top=100 if not index or page_break else 280
            x=70 if index else 280
            width=fitz.get_text_length(token,fontname='helv',fontsize=7)
            page.insert_text((x-width/2,top+2.4),token,fontname='helv',fontsize=7)
        doc.saveIncr()


class PartialBoundaryTieTests(unittest.TestCase):
    def test_only_parenthesized_string_continues_across_rows_and_pages(self):
        for page_break in (False,True):
            for extra in ('both','target','source'):
                with self.subTest(page_break=page_break,extra=extra),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'partial.pdf';partial_fixture(pdf,page_break,extra)
                    data=recognize(pdf);target=data['systems'][1]['bars'][0]
                    self.assertEqual(target['issues'],[])
                    notes=target['beats'][0]['notes']
                    self.assertEqual([(n['string'],n['fret']) for n in notes if n['tie']],[(3,7)])
                    self.assertTrue(all(n.get('tie_source_bar')==1 for n in notes if n['tie']))
                    self.assertTrue(all(not n['tie'] for n in notes if n['string']==1))

    def test_parentheses_without_an_arc_or_origin_do_not_tie_extra_note(self):
        for extra in ('both','target'):
            with self.subTest(extra=extra),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'partial.pdf';partial_fixture(pdf,extra=extra,token='(9)')
                notes=recognize(pdf)['systems'][1]['bars'][0]['beats'][0]['notes']
                self.assertEqual([(n['string'],n['fret']) for n in notes if n['tie']],[(3,7)])

    def test_partial_chord_keeps_boundary_evidence_requirements(self):
        cases=[{'arcs':'none'},{'arcs':'incoming'},{'arcs':'outgoing'},
               {'changed_pitch':True},{'number_gap':True},{'source_rest':True},
               {'parentheses':False},{'ambiguous_arc':True}]
        for options in cases:
            with self.subTest(options=options),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'partial.pdf';partial_fixture(pdf,extra='target',**options)
                notes=recognize(pdf)['systems'][1]['bars'][0]['beats'][0]['notes']
                self.assertFalse(any(n['tie'] for n in notes))

    def test_standard_staff_arcs_do_not_identify_partial_chord_strings(self):
        for extra in ('both','target','source'):
            with self.subTest(extra=extra),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'partial.pdf';partial_fixture(pdf,extra=extra,standard=True)
                notes=recognize(pdf)['systems'][1]['bars'][0]['beats'][0]['notes']
                self.assertFalse(any(n['tie'] for n in notes))

    def test_export_preserves_new_attack_and_continuation_and_requires_origin(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'partial.pdf';partial_fixture(pdf,True)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8')
            gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load();
const notes=actual.tracks[0].staves[0].bars[1].voices[0].beats[0].notes;
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes){n.isTieDestination=false;n.isTieOrigin=false;n.tieOrigin=null;n.tieDestination=null;}
console.log(JSON.stringify({notes:notes.map(n=>[7-n.string,n.fret,n.isTieDestination]),playback:comparePlayback(actual,flat,0)}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(sorted(result['notes']),[[1,9,False],[3,7,True]])
            self.assertEqual(result['playback']['actual']['note_attacks'],9)
            self.assertEqual(result['playback']['reference']['note_attacks'],10)
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(root/'excerpt.gp'),'2-2'],capture_output=True,text=True)
            self.assertNotEqual(run.returncode,0)
            self.assertFalse((root/'excerpt.gp').exists())


if __name__=='__main__':unittest.main()
