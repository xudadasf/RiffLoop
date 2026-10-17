import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer
from test_prototype import HERE


def whole_context_fixture(path,mode='combined'):
    chain=mode in ('combined','outgoing','different_target','displaced_arc','duplicate_arc')
    right=550 if chain else 370
    with fitz.open() as doc:
        p=doc.new_page(width=600,height=230)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(right,y),width=.4)
        for x in (30,190,370,*([550] if chain else [])):p.draw_line((x,100),(x,130),width=.5)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for x in (70,100,130,160,260,*([440] if chain else [])):
            token='(8)' if mode=='different_target' and x==440 else '(7)' if x>190 else '7'
            w=fitz.get_text_length(token,fontname='helv',fontsize=7)
            p.insert_text((x-w/2,114.4),token,fontname='helv',fontsize=7)
            if x<190:p.draw_line((x,117),(x,150),width=.4)
        half=fitz.get_text_length('(7)',fontname='helv',fontsize=7)/2+1.4
        def arc(a,z,y=112):
            sh=p.new_shape();sh.draw_bezier((a,y),(a+5,y+4),(z-5,y+4),(z,y))
            sh.draw_bezier((z,y),(z-5,y+3),(a+5,y+3),(a,y))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        arc(164,260-half)
        if chain:arc(260+half,440-half,115 if mode=='displaced_arc' else 112)
        if mode=='duplicate_arc':arc(260+half,440-half)
        if mode=='boundary':arc(260+half,right)
        if mode in ('combined','clef'):
            with fitz.open() as text:
                page=text.new_page(width=600,height=230)
                page.insert_font(fontname='music',fontbuffer=font_buffer())
                page.insert_text((194,118),'\ue06d',fontname='music',fontsize=17)
                with fitz.open(stream=page.get_svg_image(text_as_path=True).encode(),filetype='svg') as svg:
                    with fitz.open(stream=svg.convert_to_pdf(),filetype='pdf') as vector:
                        p.show_pdf_page(p.rect,vector,0)
        if mode in ('combined','hairpin','crescendo','one_arm','duplicate','parallel','uneven','inside_staff','unknown_mark'):
            bottom=112 if mode=='inside_staff' else 130
            a,z=230,right-3;mid=bottom+9
            lines=[((a,mid-4.25),(z,mid)),((a,mid+4.25),(z,mid))]
            if mode=='crescendo':lines=[((a,mid),(z,mid-4.25)),((a,mid),(z,mid+4.25))]
            if mode=='one_arm':lines=lines[:1]
            if mode=='duplicate':lines.append(lines[0])
            if mode=='parallel':lines[1]=((a,mid+4.25),(z,mid+8.5))
            if mode=='uneven':lines[1]=((a,mid+4.25),(z,mid+2))
            for a,z in lines:p.draw_line(a,z,width=.4)
        if mode=='unknown_mark':p.draw_circle((300,150),1,color=None,fill=(0,0,0))
        doc.save(path)


class WholeTieContextTests(unittest.TestCase):
    def test_known_clef_outgoing_tie_and_hairpins_preserve_whole_continuations(self):
        for mode in ('clef','outgoing','hairpin','crescendo','boundary','combined'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'context.pdf';whole_context_fixture(pdf,mode)
                bars=recognize(pdf)['systems'][0]['bars']
                self.assertTrue(all(not b['issues'] for b in bars),[(b['number'],b['issues']) for b in bars])
                self.assertTrue(all(b['beats'][0]['duration']==1 for b in bars[1:]))
                self.assertTrue(all(n['tie'] for b in bars[1:] for n in b['beats'][0]['notes']))

    def test_unidentified_or_ambiguous_marks_still_block_whole_duration(self):
        for mode in ('different_target','displaced_arc','duplicate_arc','one_arm','duplicate','parallel','uneven','inside_staff','unknown_mark'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'context.pdf';whole_context_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][0]['bars'][1]
                self.assertIsNone(bar['beats'][0]['duration'])
                self.assertTrue(bar['issues'])

    def test_gp_roundtrip_and_midi_keep_the_entire_continuation_chain(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'context.pdf';whole_context_fixture(pdf)
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
            self.assertEqual(result['notes'],[[0,960],[960,960],[1920,960],[2880,8640]])
            self.assertEqual(result['end'],11520)


if __name__=='__main__':unittest.main()
