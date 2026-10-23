import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from test_hidden_hold_evidence import base_page,HERE


def short_annotation_fixture(path,mode='valid',reverse=True,drawing_reverse=False,string=4):
    with fitz.open() as doc:
        p=base_page(doc);y=100+(string-1)*6
        def text(x,token,size=7,dy=0):
            w=fitz.get_text_length(token,fontname='helv',fontsize=size)
            p.insert_text((x-w/2,y+dy+2.4),token,fontname='helv',fontsize=size)
        def curve(a,z,dy=0):
            if drawing_reverse:a,z=z,a
            sh=p.new_shape();dx=z-a
            sh.draw_bezier((a,y+dy),(a+dx*.3,y+dy+3),(a+dx*.7,y+dy+3),(z,y+dy))
            sh.draw_bezier((z,y+dy),(a+dx*.7,y+dy+2),(a+dx*.3,y+dy+2),(a,y+dy))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        text(70,'3');p.draw_line((70,y+4.5),(70,146),width=.4)
        text(175,'X' if mode=='dead_source' else '5')
        p.draw_line((175,y+4.5),(175,146),width=.4)
        lx=175+fitz.get_text_length('5',fontname='helv',fontsize=7)/2+2
        label='<17>';edge=lx+fitz.get_text_length(label,fontname='helv',fontsize=5)-.1
        if mode!='missing_label':
            p.insert_text((lx,y+1.7),label,fontname='helv',fontsize=5)
        end=edge+(-2.4 if reverse else 2.4);x=end+5.6
        for _ in range(2 if mode=='duplicate_incoming' else 1):
            curve(edge+(2 if mode=='detached' else 0),end,3 if mode=='off_string' else 0)
        if mode!='missing_stem':p.draw_line((x,135),(x,146),width=.4)
        if mode=='second_stem':p.draw_line((x+1,135),(x+1,146),width=.4)
        if mode=='visible_target':text(x,'9')
        if mode=='other_string_target':text(x,'9',dy=-6)
        if mode=='intervening_rest':p.insert_text((181,112),'\ue4e5',fontname='music',fontsize=17)
        if mode in ('H','P','sl.'):
            p.insert_text((180,y-5),mode,fontname='Times-Roman',fontsize=6)
        token='(7)' if mode=='different_target' else '5' if mode=='plain_target' else '(5)'
        text(260,token);p.draw_line((260,y+4.5),(260,146),width=.4)
        if mode!='no_outgoing':
            for _ in range(2 if mode=='duplicate_outgoing' else 1):
                curve(x+5.6+(2 if mode=='asymmetric' else 0),254.4)
        doc.save(path)


class ShortAnnotatedTieTests(unittest.TestCase):
    def test_short_annotation_ties_use_the_annotation_edge_not_x_or_drawing_order(self):
        for reverse in (False,True):
            for drawing_reverse in (False,True):
                for string in (2,4):
                    with self.subTest(reverse=reverse,drawing_reverse=drawing_reverse,string=string),tempfile.TemporaryDirectory() as folder:
                        pdf=Path(folder)/'short.pdf'
                        short_annotation_fixture(pdf,reverse=reverse,drawing_reverse=drawing_reverse,string=string)
                        bar=recognize(pdf)['systems'][0]['bars'][0]
                        self.assertFalse(bar['issues'])
                        self.assertEqual([v['duration'] for v in bar['beats']],[4,4,4,4])
                        self.assertEqual([(n['string'],n['fret'],n['tie']) for v in bar['beats'] for n in v['notes']],
                                         [(string,3,False),(string,5,False),(string,5,True),(string,5,True)])

    def test_short_arcs_require_unique_two_sided_evidence_and_an_empty_target(self):
        for mode in ('missing_label','detached','off_string','dead_source','missing_stem','second_stem',
                     'visible_target','other_string_target','intervening_rest','H','P','sl.',
                     'duplicate_incoming','no_outgoing','duplicate_outgoing','asymmetric','different_target','plain_target'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'short.pdf';short_annotation_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('inferred_from') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_export_and_midi_preserve_the_chain_as_one_sustained_attack(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'short.pdf';short_annotation_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True,encoding='utf-8')
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
            self.assertEqual(data['notes'],[[0,960,53],[960,2880,55]])
            self.assertEqual(data['end'],3840)


if __name__=='__main__':unittest.main()
