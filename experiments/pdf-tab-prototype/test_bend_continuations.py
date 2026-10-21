import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def bend_fixture(path,mode='valid',visible=False,whole=False):
    with fitz.open() as doc:
        p=doc.new_page(width=400,height=220)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        p.insert_text((30,25),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        for yy in range(100,131,6):p.draw_line((30,yy),(350,yy),width=.4)
        for i in range(5):p.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
        for x in ((30,180,350) if whole else (30,350)):
            p.draw_line((x,100),(x,130),width=.4)
        for yy in (110,118.5):p.insert_text((38,yy),'\ue084',fontname='music',fontsize=17)
        p.insert_text((30,48),'1',fontname='Times-Roman',fontsize=6)
        if whole:p.insert_text((180,48),'2',fontname='Times-Roman',fontsize=6)
        target=250 if whole else 140;hy=57.875
        if mode=='wrong_height':hy=62.125
        for i,x in enumerate((70,target) if whole else (70,target,210,280)):
            y=hy if i==1 else 60
            size=12.75 if i==1 and mode=='cue_head' else 17
            if not (i==0 and mode=='missing_source_head'):
                p.insert_text((x-(3.59 if whole else 2.5),y),'\ue0a2' if whole else '\ue0a4',fontname='music',fontsize=size)
            if not whole and not (i==1 and mode=='missing_stem'):
                p.draw_line((x-2.2,y-.5),(x-2.2,y+18),width=.4)
                if i==1 and mode=='duplicate_stem':p.draw_line((x+2,y-.5),(x+2,y+18),width=.4)
            if i!=1 or visible or whole or mode in ('visible_attack','different_fret','different_string','target_rest'):
                token='(12)' if i==1 else '12'
                if i==1 and mode=='visible_attack':token='12'
                if i==1 and mode=='different_fret':token='(13)'
                if i==0 and mode=='dead_source':token='X'
                if i==1 and mode=='target_rest':
                    p.insert_text((x,112),'\ue4e5',fontname='music',fontsize=17);continue
                size=5 if i==0 and mode=='grace_source' else 7
                w=fitz.get_text_length(token,fontname='helv',fontsize=size)
                p.insert_text((x-w/2,108.4 if i==1 and mode=='different_string' else 102.4),token,fontname='helv',fontsize=size)
                if i==0 and mode=='source_chord':p.insert_text((x-1.95,108.4),'5',fontname='helv',fontsize=7)
        for side in (-1,1):
            if mode==('no_left_parenthesis' if side==-1 else 'no_right_parenthesis'):continue
            for _ in range(2 if mode=='duplicate_parenthesis' and side==1 else 1):
                x=target+side*(4.3 if whole else 3.3);y=hy+(5 if mode=='offset_parentheses' else 0)
                sh=p.new_shape();sh.draw_bezier((x,y-2.125),(x+side*3.4,y-1.0625),(x+side*3.4,y+1.0625),(x,y+2.125))
                sh.draw_bezier((x,y+2.125),(x+side*2.55,y+1.0625),(x+side*2.55,y-1.0625),(x,y-2.125))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
        if mode!='no_bend':
            for _ in range(2 if mode=='duplicate_bend' else 1):
                a=(71.15,56.94);z=(target-.55,hy-3.06);peak=(70+(target-70)/3,48.86)
                if mode=='displaced_source':a=(80,56.94)
                if mode=='displaced_target':z=(target-8,hy-3.06)
                if mode=='flat_bend':peak=(peak[0],56.94)
                sh=p.new_shape();sh.draw_line(a,peak)
                if mode!='half_bend':sh.draw_line((peak[0]+3,peak[1]) if mode=='broken_bend' else peak,z)
                sh.finish(color=(0,0,0),width=.5);sh.commit()
        if mode=='intervening_rest':p.insert_text((105,112),'\ue4e5',fontname='music',fontsize=17)
        if mode=='intervening_head':p.insert_text((103,60),'\ue0a4',fontname='music',fontsize=17)
        if mode in ('H','P','sl.'):p.insert_text((100,88),mode,fontname='Times-Roman',fontsize=6)
        doc.save(path)


class BendContinuationTests(unittest.TestCase):
    def test_single_bent_hold_with_hidden_or_printed_tab_and_whole_notes(self):
        for visible,whole in ((False,False),(True,False),(True,True)):
            with self.subTest(visible=visible,whole=whole),tempfile.TemporaryDirectory() as folder:
                p=Path(folder)/'bend.pdf';bend_fixture(p,visible=visible,whole=whole)
                bars=[b for s in recognize(p)['systems'] for b in s['bars']]
                self.assertFalse(any(b['issues'] for b in bars))
                beats=[v for b in bars for v in b['beats']]
                self.assertEqual([v['notes'][0]['tie'] for v in beats],[False,True] if whole else [False,True,False,False])

    def test_missing_or_ambiguous_bend_evidence_never_creates_a_hold(self):
        modes=('no_bend','half_bend','broken_bend','flat_bend','duplicate_bend','displaced_source','displaced_target',
               'no_left_parenthesis','no_right_parenthesis','duplicate_parenthesis','offset_parentheses',
               'wrong_height','cue_head','missing_stem','duplicate_stem','missing_source_head','dead_source',
               'grace_source','source_chord','visible_attack','different_fret','different_string','target_rest',
               'intervening_rest','intervening_head','H','P','sl.')
        for mode in modes:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                p=Path(folder)/'ambiguous.pdf';bend_fixture(p,mode)
                data=recognize(p)
                self.assertFalse(any(n['tie'] for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_export_and_actual_midi_preserve_hold_timing(self):
        for whole in (False,True):
            with self.subTest(whole=whole),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'bend.pdf';bend_fixture(pdf,visible=whole,whole=whole)
                raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js'),notes=[];
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end}));
'''
                run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
                self.assertEqual(json.loads(run.stdout),{'notes':[[0,7680]] if whole else [[0,1920],[1920,960],[2880,960]],
                                                        'end':7680 if whole else 3840})


if __name__=='__main__':unittest.main()
