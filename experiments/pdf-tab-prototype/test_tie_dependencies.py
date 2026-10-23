import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize,read_ties,text_spans,lines_and_shapes
from test_prototype import fixture,HERE
from symbols import font_buffer


def dependency_fixture(path,mode='valid',visible=1,reverse=False):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
        def text(x,y,token,font='helv'):
            w=fitz.get_text_length(token,fontname=font,fontsize=7)
            p.insert_text((x-w/2,y+2.4),token,fontname=font,fontsize=7)
        def arc(a,z,y):
            sh=p.new_shape();sh.draw_bezier((a,y),(a+5,y+4),(z-5,y+4),(z,y))
            sh.draw_bezier((z,y),(z-5,y+3),(a+5,y+3),(a,y))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        width=lambda fret:fitz.get_text_length('('+str(fret)+')',fontname='helv',fontsize=7)/2+1.4
        for i,x in enumerate((70,140,210,280)):
            token='(7)' if i in (1,2) and mode!='no_samples' else '7'
            text(x,112,token,'cour' if mode=='different_font' else 'helv')
            p.draw_line((x,117),(x,150),width=.4)
        arc(75,140-width(7),112);arc(140+width(7),210-width(7)+(1 if mode=='inconsistent_samples' else 0),112)
        for y in range(180,211,6):p.draw_line((30,y),(350,y),width=.4)
        for x in (30,350):p.draw_line((x,180),(x,210),width=.5)
        p.insert_text((30,178),'2',fontname='Times-Roman',fontsize=6)
        frets=(10,10,8)
        for i,x in enumerate((70,140,210)):
            for tone,fret in enumerate(frets):
                if i==1 and tone!=visible:continue
                token='('+str(fret)+')' if i else str(fret)
                if i==2 and mode in ('no_samples','different_font'):token=str(fret)
                if i==1 and mode=='plain_target':token=str(fret)
                if i==1 and mode=='different_target':token='(11)'
                if i==0 and mode=='dead_source' and tone==visible:token='X'
                text(x,192+tone*6,token)
            if not (i==1 and mode=='missing_stem'):p.draw_line((x,209),(x,230),width=.4)
        if mode=='second_stem':p.draw_line((139,209),(139,230),width=.4)
        if mode=='intervening_rest':p.insert_text((105,192),'\ue4e6',fontname='music',fontsize=17)
        if mode=='occupied_hidden_string':text(140,192+((visible+1)%3)*6,'9')
        p.insert_text((280,192),'\ue4e5',fontname='music',fontsize=17)
        order=list(range(3));order=order[::-1] if reverse else order
        for tone in order:
            fret=frets[tone];y=192+tone*6
            start=70+fitz.get_text_length(str(fret),fontname='helv',fontsize=7)/2+1.4
            if not (tone==visible and mode=='no_visible_arc'):
                arc(start,140-width(fret)+(1 if mode=='wrong_padding' and tone!=visible else 0),y)
            # Without a confirmed visible tie, do not give the negative case
            # an independent outgoing chain that would legitimately prove it.
            if mode!='plain_target' or tone==visible:arc(140+width(fret),210-width(fret),y)
        doc.saveIncr()


class TieDependencyTests(unittest.TestCase):
    def test_visible_confirmation_precedes_hidden_chord_dependencies(self):
        for visible in range(3):
            for reverse in (False,True):
                with self.subTest(visible=visible,reverse=reverse),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'ties.pdf';dependency_fixture(pdf,visible=visible,reverse=reverse)
                    bar=recognize(pdf)['systems'][1]['bars'][0]
                    self.assertFalse(bar['issues'])
                    for beat in bar['beats'][1:3]:
                        self.assertEqual(sorted((n['string'],n['fret'],n['tie']) for n in beat['notes']),
                                         [(3,10,True),(4,10,True),(5,8,True)])

    def test_revisiting_the_reader_does_not_duplicate_inferred_strings(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'ties.pdf';dependency_fixture(pdf,visible=2)
            data=recognize(pdf);system=data['systems'][1];before=copy.deepcopy(system)
            with fitz.open(pdf) as doc:
                lines,shapes=lines_and_shapes(doc[0]);spans=text_spans(doc[0])
                for _ in range(3):read_ties(system,spans,lines,shapes)
            self.assertEqual(system,before)

    def test_unproven_visible_targets_and_bad_layout_still_block_hidden_chords(self):
        for mode in ('no_samples','different_font','inconsistent_samples','no_visible_arc','plain_target',
                     'different_target','dead_source','missing_stem','second_stem','intervening_rest','wrong_padding'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ties.pdf';dependency_fixture(pdf,mode)
                beat=recognize(pdf)['systems'][1]['bars'][0]['beats'][1]
                self.assertFalse(any(n.get('inferred_from') for n in beat['notes']))
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'ties.pdf';dependency_fixture(pdf,'occupied_hidden_string')
            beat=recognize(pdf)['systems'][1]['bars'][0]['beats'][1]
            self.assertEqual([n['fret'] for n in beat['notes'] if n['string']==5],[9])

    def test_exported_chord_has_three_sustained_notes_without_duplicate_attacks(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'ties.pdf';dependency_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp),'2-2'],capture_output=True,text=True,encoding='utf-8')
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings()),notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration,key]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,encoding='utf-8')
            self.assertEqual(run.returncode,0,run.stderr);data=json.loads(run.stdout)
            self.assertEqual(sorted(data['notes']),[[0,2880,53],[0,2880,60],[0,2880,65]])
            self.assertEqual(data['end'],3840)


if __name__=='__main__':unittest.main()
