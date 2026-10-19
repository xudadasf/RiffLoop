import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def arc(page,a,z,y):
    sh=page.new_shape();sh.draw_bezier((a,y),(a+2,y-4),(z-2,y-4),(z,y))
    sh.draw_bezier((z,y),(z-2,y-3),(a+2,y-3),(a,y))
    sh.finish(color=None,fill=(0,0,0));sh.commit()


def beam(page,left,right,y):
    page.draw_polyline([(left,y),(right,y),(right,y+2),(left,y+2),(left,y)],color=None,fill=(0,0,0))


def base_page(doc,known_tuning=True,standard=False):
    p=doc.new_page(width=400,height=240);p.insert_font(fontname='music',fontbuffer=font_buffer())
    p.insert_text((30,25),('Standard tuning' if known_tuning else 'Unspecified tuning')+' = 90',fontname='Times-Roman',fontsize=9)
    for y in range(100,131,6):p.draw_line((30,y),(350,y),width=.4)
    for x in (30,350):p.draw_line((x,100),(x,130),width=.5)
    if standard:
        for i in range(5):p.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
    for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
    return p


def beamed_fixture(path,mode='valid',stub=False):
    with fitz.open() as doc:
        p=base_page(doc)
        for x,fret in ((70,8),(140,10),(230,7),(300,5)):
            token=str(fret);w=fitz.get_text_length(token,fontname='helv',fontsize=7)
            p.insert_text((x-w/2,102.4),token,fontname='helv',fontsize=7)
            p.draw_line((x,105),(x,146),width=.4)
        if mode!='missing_stem':p.draw_line((160,135),(160,146),width=.4)
        if mode=='second_stem':
            p.draw_line((159,135),(159,146),width=.4);beam(p,140,159,144)
        if mode!='missing_beam':beam(p,140,160,155 if mode=='detached_beam' else 144)
        if stub:beam(p,156,160,140)
        if mode=='visible_target':p.insert_text((158,102.4),'9',fontname='helv',fontsize=7)
        if mode=='intervening_rest':p.insert_text((150,112),'\ue4e5',fontname='music',fontsize=17)
        if mode!='no_arc':arc(p,140 if stub else 145.5,160 if stub else 152,96.3 if stub else 100+(3 if mode=='off_string' else 0))
        doc.save(path)


def partial_chord_fixture(path,mode='valid',middle_missing=False):
    with fitz.open() as doc:
        p=base_page(doc,mode!='unknown_tuning',True)
        # String order and pitch order intentionally differ: B4, E4, D4.
        notes=[(1,0),(2,5 if mode=='unison' else 12),(3,7)]
        kept=(0,2) if middle_missing else (0,1)
        for i,x in enumerate((70,140,210,280)):
            for rank,y in enumerate((50,58.5,67)):
                if i==1 and rank not in kept:continue
                if i==0 and mode=='incomplete_source' and rank==2:continue
                hy=y+(2.125 if i==1 and mode=='shifted_head' and rank==0 else 0)
                p.insert_text((x-2.5,hy),'\ue0a4',fontname='music',fontsize=17)
            if i!=1 or mode=='visible_target':
                for string,fret in notes:
                    token=str(fret);w=fitz.get_text_length(token,fontname='helv',fontsize=7)
                    p.insert_text((x-w/2,102.4+(string-1)*6),token,fontname='helv',fontsize=7)
            if not (i==1 and mode=='missing_stem'):p.draw_line((x+2.2,40),(x+2.2,67.5),width=.4)
        if mode=='intervening_rest':p.insert_text((105,112),'\ue4e5',fontname='music',fontsize=17)
        for rank in kept:
            if mode=='missing_arc' and rank==kept[-1]:continue
            for _ in range(2 if mode=='duplicate_arc' else 1):arc(p,73,137,(50,58.5,67)[rank]+.8)
        doc.save(path)


class HiddenHoldEvidenceTests(unittest.TestCase):
    def test_a_shared_beam_confirms_a_hidden_short_stem_without_padding_samples(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'beam.pdf';beamed_fixture(p)
            bar=recognize(p)['systems'][0]['bars'][0]
            self.assertFalse(bar['issues']);self.assertEqual([v['duration'] for v in bar['beats']],[4,8,8,4,4])
            self.assertEqual([(n['string'],n['fret'],n['tie']) for n in bar['beats'][2]['notes']],[(1,10,True)])

    def test_beam_edges_are_not_competing_rhythm_stems(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'stub.pdf';beamed_fixture(p,stub=True)
            beats=recognize(p)['systems'][0]['bars'][0]['beats']
            held=[v for v in beats if any(n['tie'] for n in v['notes'])]
            self.assertEqual(len(held),1);self.assertAlmostEqual(held[0]['x'],160,places=1)
            self.assertEqual(held[0]['duration'],16)

    def test_unsupported_stems_beams_and_arcs_do_not_fill_the_bar(self):
        for mode in ('missing_stem','missing_beam','detached_beam','second_stem','visible_target','intervening_rest','no_arc','off_string'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                p=Path(folder)/'bad.pdf';beamed_fixture(p,mode)
                data=recognize(p)
                self.assertFalse(any(n['tie'] for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_partial_chord_maps_staff_heads_using_known_unique_source_pitches(self):
        for middle in (False,True):
            with self.subTest(middle_missing=middle),tempfile.TemporaryDirectory() as folder:
                p=Path(folder)/'chord.pdf';partial_chord_fixture(p,middle_missing=middle)
                bar=recognize(p)['systems'][0]['bars'][0]
                self.assertFalse(bar['issues']);self.assertEqual(len(bar['beats']),4)
                self.assertEqual([(n['string'],n['fret'],n['tie']) for n in bar['beats'][1]['notes']],
                                 [(2,12,True),(3,7,True)] if middle else [(1,0,True),(2,12,True)])

    def test_partial_chord_requires_complete_source_unique_mapping_and_each_arc(self):
        for mode in ('unknown_tuning','unison','incomplete_source','shifted_head','missing_stem','visible_target',
                     'intervening_rest','missing_arc','duplicate_arc'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                p=Path(folder)/'bad.pdf';partial_chord_fixture(p,mode)
                data=recognize(p)
                self.assertFalse(any(n.get('inferred_from') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_gp_and_midi_preserve_hidden_holds_and_untied_chord_releases(self):
        for chord in (False,True):
            with self.subTest(chord=chord),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);p=root/'source.pdf';(partial_chord_fixture if chord else beamed_fixture)(p)
                raw=root/'recognized.json';raw.write_text(json.dumps(recognize(p)),encoding='utf-8');gp=root/'out.gp'
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
                self.assertEqual(run.returncode,0,run.stderr);data=json.loads(run.stdout)
                expected=([[0,960]]+[[0,1920]]*2+[[1920,960]]*3+[[2880,960]]*3 if chord else
                          [[0,960],[960,960],[1920,960],[2880,960]])
                self.assertEqual(sorted(data['notes']),sorted(expected));self.assertEqual(data['end'],3840)


if __name__=='__main__':unittest.main()
