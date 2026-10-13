import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def chord_fixture(path,mode='up',strings=(4,5,6),index=3):
    positions=(70,110,150,213,226.7,285,325,365) if mode=='dense_two_arcs' else (70,110,150,190,245,285,325,365)
    sx,tx=positions[index:index+2]
    source=([10,10,8] if mode=='dense_two_arcs' else [9,9,7])[:len(strings)];shift=-2 if mode=='down' else 2
    target=[f+shift for f in source]
    if mode=='revoiced':target[-1]+=1
    if mode=='stationary_tone':target[-1]=source[-1]
    if mode=='opposite_tone':target[-1]=source[-1]-shift
    with fitz.open() as doc:
        p=doc.new_page(width=420,height=240)
        p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        p.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(100,131,6):p.draw_line((30,y),(400,y),width=.4)
        for x in (30,220,400):p.draw_line((x,100),(x,130),width=.4)
        for y in (110,118.5):p.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
        for number,x in ((1,30),(2,220)):p.insert_text((x,98),str(number),fontname='Times-Roman',fontsize=6)
        edges={}
        for i,x in enumerate(positions):
            for j,string in enumerate(strings):
                if mode=='missing_tone' and i==index+1 and j==len(strings)-1:continue
                fret=source[j] if i<=index else target[j];y=100+(string-1)*6
                token=str(fret);width=fitz.get_text_length(token,fontname='helv',fontsize=7)
                p.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7)
                edges[i,string]=(x-width/2,x+width/2)
            p.draw_line((x,100+(max(strings)-1)*6+5),(x,155),width=.4)
        if mode!='no_label':p.insert_text(((sx+tx)/2-3,96),'sl.',fontname='Times-Italic',fontsize=6)
        sides=[] if mode=='no_arc' else [-1,1] if mode in ('two_arcs','dense_two_arcs') else [1,1] if mode=='duplicate_arc' else [-1] if mode=='upper_arc' else [1]
        for side in sides:
            y=100+((min(strings) if side<0 else max(strings))-1)*6
            if mode=='inner_arc':y=100+(strings[1]-1)*6
            sh=p.new_shape();sh.draw_bezier((sx,y+side*2.5),(sx+6,y+side*11),(tx-6,y+side*11),(tx,y+side*2.5))
            sh.draw_bezier((tx,y+side*2.5),(tx-6,y+side*10),(sx+6,y+side*10),(sx,y+side*2.5))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        for j,string in enumerate(strings):
            if (index+1,string) not in edges or mode=='partial_lines' and j==len(strings)-1:continue
            y=100+(string-1)*6;rise=1 if target[j]>source[j] else -1
            if mode=='wrong_line' and j==0:rise=-rise
            start=edges[index,string][1]+(-1 if mode=='line_over_digit' and j==0 else 2)
            p.draw_line((start,y+rise*1.5),(edges[index+1,string][0]-2,y-rise*1.5),width=.4)
        if mode=='intervening_rest':p.insert_text((232,112),'\ue4e5',fontname='music',fontsize=17)
        doc.save(path)


class ChordSlideTests(unittest.TestCase):
    def test_parallel_chord_slide_roundtrip_and_playback(self):
        for mode in ('up','down','upper_arc','no_label','two_arcs','dense_two_arcs'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);pdf=root/'chord.pdf';chord_fixture(pdf,mode)
                data=recognize(pdf);bars=data['systems'][0]['bars']
                self.assertFalse(any(b['issues'] for b in bars))
                self.assertEqual(sum(n.get('legato_slide',False) for n in bars[0]['beats'][3]['notes']),3)
                self.assertFalse(any(m['status']=='unsupported' for m in data['slide_marks']))
                raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8');gp=root/'out.gp'
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)
                script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load();
for(const bar of flat.tracks[0].staves[0].bars)for(const beat of bar.voices[0].beats)for(const n of beat.notes){n.slideOutType=0;n.slideTarget=null;n.slideOrigin=null;}
const notes=actual.tracks[0].staves[0].bars[0].voices[0].beats[3].notes;
console.log(JSON.stringify({slides:notes.map(n=>[7-n.string,n.slideOutType,n.slideTarget.fret]),playback:comparePlayback(actual,flat,0)}));
'''
                run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
                shift=-2 if mode=='down' else 2
                offset=1 if mode=='dense_two_arcs' else 0
                self.assertEqual(sorted(result['slides']),[[4,2,9+shift+offset],[5,2,9+shift+offset],[6,2,7+shift+offset]])
                self.assertEqual(result['playback']['actual']['note_attacks'],21)
                self.assertEqual(result['playback']['reference']['note_attacks'],24)
                for selection in ('1','2'):
                    run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(root/f'{selection}.gp'),selection],capture_output=True,text=True)
                    self.assertNotEqual(run.returncode,0);self.assertIn('Slide',run.stderr)

    def test_chord_rule_handles_other_strings_and_within_bar(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'chord.pdf';chord_fixture(pdf,strings=(1,2),index=1)
            data=recognize(pdf)
            self.assertEqual(sum(n.get('legato_slide',False) for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']),2)

    def test_partial_or_conflicting_chord_evidence_is_not_inferred(self):
        for mode in ('no_arc','partial_lines','wrong_line','revoiced','stationary_tone','opposite_tone','inner_arc','missing_tone','intervening_rest','duplicate_arc','line_over_digit'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'chord.pdf';chord_fixture(pdf,mode)
                data=recognize(pdf)
                self.assertFalse(any(n.get('legato_slide') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))


if __name__=='__main__':unittest.main()
