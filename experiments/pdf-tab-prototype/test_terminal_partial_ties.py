import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer
from test_prototype import fixture,HERE


def terminal_partial_fixture(path,mode='valid',fret='7',target_string=4):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        p=doc[0];p.insert_font(fontname='music',fontbuffer=font_buffer())
        def text(x,y,token,font='helv',size=7):
            width=fitz.get_text_length(token,fontname=font,fontsize=size)
            p.insert_text((x-width/2,y+2.4),token,fontname=font,fontsize=size)
        def arc(a,z,y,end_y=None):
            end_y=y if end_y is None else end_y
            sh=p.new_shape()
            sh.draw_bezier((a,y),(a+5,y+4),(z-5,end_y+4),(z,end_y))
            sh.draw_bezier((z,end_y),(z-5,end_y+3),(a+5,y+3),(a,y))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        width=fitz.get_text_length('('+fret+')',fontname='helv',fontsize=7)/2+1.4
        for x in (70,140,210,280):
            text(x,112,'('+fret+')' if x in (140,210) and mode!='no_anchors' else fret,
                 'cour' if mode=='wrong_font' else 'helv')
            p.draw_line((x,117),(x,150),width=.4)
        arc(75,140-width,112)
        arc(140+width,210-width+(1 if mode=='inconsistent' else 0),112)
        for y in range(180,211,6):p.draw_line((30,y),(350,y),width=.4)
        for x in (30,350):p.draw_line((x,180),(x,210),width=.4)
        p.insert_text((30,178),'2',fontname='Times-Roman',fontsize=6)
        for x in (70,140):
            text(x,192,fret if x==70 or mode=='plain_source' else '('+fret+')')
            p.draw_line((x,197),(x,230),width=.4)
        if mode!='unconfirmed_source':arc(75,140-width,192)
        token='(5)' if mode=='parenthesized_target' else 'X' if mode=='dead_target' else '<7>' if mode=='harmonic_target' else '10'
        target_y=180+(target_string-1)*6
        text(210,target_y,token,size=5 if mode=='grace_target' else 7)
        if mode!='missing_stem':p.draw_line((210,target_y+5),(210,230),width=.4)
        if mode=='ambiguous_stem':p.draw_line((211,target_y+5),(211,230),width=.4)
        if mode=='visible_pitch':text(210,192,'8')
        if mode=='intervening_rest':p.insert_text((175,192),'\ue4e6',fontname='music',fontsize=17)
        if mode=='intervening_note':text(175,186,'9')
        if mode in ('H','P','sl.'):text(175,184,mode,font='Times-Roman')
        p.insert_text((280,192),'\ue4e5',fontname='music',fontsize=17)
        if mode!='no_arc':
            for _ in range(2 if mode=='duplicate_arc' else 1):
                y=194 if mode=='displaced_arc' else 192
                arc(140+width+(1 if mode=='wrong_source_padding' else 0),
                    210-width+(1 if mode=='wrong_target_padding' else 0),y,
                    target_y if mode=='cross_string_slur' else y)
        doc.saveIncr()


class TerminalPartialTieTests(unittest.TestCase):
    def test_confirmed_printed_continuation_can_end_beside_a_new_attack(self):
        for fret,target_string in (('7',2),('7',4),('12',2),('12',4)):
            with self.subTest(fret=fret,target_string=target_string),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'partial.pdf';terminal_partial_fixture(pdf,fret=fret,target_string=target_string)
                bar=recognize(pdf)['systems'][1]['bars'][0]
                self.assertFalse(bar['issues'])
                self.assertEqual([len(v['notes']) for v in bar['beats']],[1,1,2,0])
                self.assertEqual(sorted((n['string'],n['fret'],n['tie']) for n in bar['beats'][2]['notes']),
                                 sorted([(3,int(fret),True),(target_string,10,False)]))

    def test_unconfirmed_or_ambiguous_endings_do_not_invent_hidden_notes(self):
        modes=('no_anchors','wrong_font','inconsistent','unconfirmed_source','plain_source','no_arc',
               'wrong_source_padding','wrong_target_padding','displaced_arc','cross_string_slur','duplicate_arc',
               'missing_stem','ambiguous_stem','parenthesized_target','dead_target','harmonic_target','grace_target',
               'visible_pitch','intervening_rest','intervening_note','H','P','sl.')
        for mode in modes:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ambiguous.pdf';terminal_partial_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][1]['bars'][0]
                self.assertFalse(any(n.get('inferred_from') for v in bar['beats'] for n in v['notes']))

    def test_gp_roundtrip_and_midi_preserve_the_held_note_and_new_attack(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'partial.pdf';terminal_partial_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp),'2-2'],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js'),notes=[];
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration,key]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes:notes.sort((a,b)=>a[0]-b[0]),end:g.tickLookup.masterBars.at(-1).end}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
            self.assertEqual(json.loads(run.stdout),{'notes':[[0,2880,62],[1920,960,60]],'end':3840})


if __name__=='__main__':unittest.main()
