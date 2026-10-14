import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import fitz
from recognize import recognize
from test_prototype import HERE,fixture
from symbols import font_buffer


def partial_chain_fixture(path,mode='valid'):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
        def text(x,y,token,font='helv',size=7):
            width=fitz.get_text_length(token,fontname=font,fontsize=size)
            p.insert_text((x-width/2,y+2.4),token,fontname=font,fontsize=size)
        def arc(a,z,y):
            sh=p.new_shape();sh.draw_bezier((a,y),(a+5,y+4),(z-5,y+4),(z,y))
            sh.draw_bezier((z,y),(z-5,y+3),(a+5,y+3),(a,y))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        # Two independent visible continuations measure the actual padding.
        width=fitz.get_text_length('(7)',fontname='helv',fontsize=7)/2+1.4
        for x in (70,140,210,280):
            token='(7)' if x in (140,210) and mode!='no_anchors' and not (mode=='one_anchor' and x==210) else '7'
            text(x,112,token,'cour' if mode=='wrong_font' else 'helv')
            p.draw_line((x,117),(x,150),width=.4)
        arc(75,140-width,112);arc(140+width,210-width,112)
        for y in range(180,211,6):p.draw_line((30,y),(350,y),width=.4)
        for x in (30,350):p.draw_line((x,180),(x,210),width=.5)
        p.insert_text((30,178),'2',fontname='Times-Roman',fontsize=6)
        text(70,192,'7');p.draw_line((70,197),(70,230),width=.4)
        for x in (140,210):
            if mode=='terminal_rest' and x==210:
                p.insert_text((x,192),'\ue4e5',fontname='music',fontsize=17)
            else:
                text(x,198,'(5)' if mode=='parenthesized_new_note' else 'X' if mode=='dead_new_note' else '5')
            if mode!='missing_stem' or x!=140:p.draw_line((x,203),(x,230),width=.4)
        if mode=='visible_pitch':text(140,192,'8')
        if mode=='ambiguous_stem':p.draw_line((141,203),(141,230),width=.4)
        if mode=='intervening_rest':p.insert_text((110,192),'\ue4e6',fontname='music',fontsize=17)
        p.insert_text((280,192),'\ue4e5',fontname='music',fontsize=17)
        y=194 if mode=='displaced_arc' else 192
        if mode!='no_incoming':arc(75,140-width+(1 if mode=='wrong_incoming_padding' else 0),y)
        if mode!='no_outgoing':
            arc(140+width+(1 if mode=='asymmetric' else 0),210-width+(1 if mode=='wrong_terminal_padding' else 0),y)
            if mode=='duplicate_outgoing':arc(140+width,210-width,y)
        doc.saveIncr()


class HiddenPartialChainTests(unittest.TestCase):
    def test_measured_chain_can_continue_while_another_string_is_attacked(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'partial.pdf';partial_chain_fixture(pdf)
            data=recognize(pdf);bar=data['systems'][1]['bars'][0]
            self.assertEqual(bar['issues'],[])
            self.assertEqual([len(v['notes']) for v in bar['beats']],[1,2,2,0])
            for beat in bar['beats'][1:3]:
                self.assertEqual(sorted((n['string'],n['fret'],n['tie']) for n in beat['notes']),[(3,7,True),(4,5,False)])

    def test_missing_conflicting_or_single_short_arcs_do_not_add_notes(self):
        for mode in ('no_anchors','one_anchor','wrong_font','no_incoming','no_outgoing','asymmetric',
                     'wrong_incoming_padding','wrong_terminal_padding','displaced_arc','duplicate_outgoing',
                     'missing_stem','ambiguous_stem','visible_pitch','intervening_rest','terminal_rest',
                     'parenthesized_new_note','dead_new_note'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'partial.pdf';partial_chain_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][1]['bars'][0]
                self.assertFalse(any(n.get('inferred_from') for v in bar['beats'] for n in v['notes']))

    def test_export_releases_the_tied_note_after_the_entire_chain(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'partial.pdf';partial_chain_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8')
            gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp),'2-2'],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const notes=[];
class Handler extends a.midi.AlphaSynthMidiFileHandler {
  addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration,key]);super.addNote(t,tick,duration,key,velocity,channel);}
}
new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile())).generate();
console.log(JSON.stringify(notes));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            self.assertEqual(sorted(json.loads(run.stdout)),[[0,2880,62],[960,960,55],[1920,960,55]])


if __name__=='__main__':unittest.main()
