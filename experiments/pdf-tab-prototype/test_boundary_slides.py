import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def boundary_fixture(path,mode='up',chord=False,new_page=False):
    strings=(4,5,6) if chord else (2,)
    source=(11,11,9) if chord else (8,)
    shift=-5 if mode=='down' else 2
    target=[f+shift for f in source]
    if mode=='same_fret':target=list(source)
    if mode=='partial':target[-1]=source[-1]
    with fitz.open() as doc:
        page=doc.new_page(width=420,height=440)
        page.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
        for row in range(2):
            if row and new_page:page=doc.new_page(width=420,height=440)
            top=100 if not row or new_page else 270
            page.insert_font(fontname='music',fontbuffer=font_buffer())
            for y in range(top,top+31,6):page.draw_line((30,y),(400,y),width=.4)
            for x in (30,400):page.draw_line((x,top),(x,top+30),width=.4)
            page.insert_text((30,top-2),str(3 if row and mode=='skipped_bar' else row+1),fontname='Times-Roman',fontsize=6)
            if not row:
                for y in (top+10,top+18.5):page.insert_text((38,y),'\ue084',fontname='music',fontsize=17)
            boxes={}
            for index,x in enumerate((70,160,250,340)):
                for j,string in enumerate(strings):
                    if row and mode=='missing_tone' and j==len(strings)-1:continue
                    actual_string=string+1 if row and mode=='other_string' else string
                    y=top+(actual_string-1)*6;fret=(target if row else source)[j]
                    token=str(fret);width=fitz.get_text_length(token,fontname='helv',fontsize=7)
                    page.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7)
                    boxes[index,string]=(x-width/2,x+width/2)
                page.draw_line((x,top+35),(x,top+55),width=.4)
            if row and mode=='intervening_rest':page.insert_text((55,top+12),'\ue4e5',fontname='music',fontsize=17)
            if not row:
                if mode!='no_label' and not chord:page.insert_text((360,top-4),'sl.',fontname='Times-Italic',fontsize=6)
                for j,string in enumerate(strings):
                    if mode=='no_line' or mode=='partial_lines' and j==len(strings)-1:continue
                    y=top+(string-1)*6;rise=-1 if mode=='down' else 1
                    if mode=='wrong_slope':rise=-rise
                    end=380 if mode=='short_line' else 398
                    page.draw_line((boxes[3,string][1]+2,y+rise*1.5),(end,y),width=.4)
            if mode=='no_out_arc' and not row or mode=='no_in_arc' and row:continue
            sides=(-1,1) if mode=='two_arcs' else (-1,) if mode=='upper' else (1,)
            if mode=='wrong_side' and row:sides=(-1,)
            for side in sides:
                y=top+((min(strings) if side<0 else max(strings))-1)*6+side*2.5
                sx,tx=(64,70) if row else (340,398)
                if mode=='wrong_target' and row:sx,tx=154,160
                if mode=='short_arc' and not row:tx=380
                for _ in range(2 if mode=='duplicate_arc' and row else 1):
                    sh=page.new_shape()
                    sh.draw_bezier((sx,y),(sx,y+side*8),(tx,y+side*8),(tx,y))
                    sh.draw_bezier((tx,y),(tx,y+side*7),(sx,y+side*7),(sx,y))
                    sh.finish(color=None,fill=(0,0,0));sh.commit()
        doc.save(path)


class BoundarySlideTests(unittest.TestCase):
    def test_paired_boundary_evidence_across_rows_and_pages(self):
        for chord in (False,True):
            for new_page in (False,True):
                for mode in ('up','down','upper','two_arcs'):
                    with self.subTest(chord=chord,new_page=new_page,mode=mode),tempfile.TemporaryDirectory() as folder:
                        pdf=Path(folder)/'boundary.pdf';boundary_fixture(pdf,mode,chord,new_page)
                        data=recognize(pdf);source=data['systems'][0]['bars'][0]['beats'][-1]
                        self.assertEqual(sum(n.get('legato_slide',False) for n in source['notes']),3 if chord else 1)
                        self.assertFalse(any(m['status']=='unsupported' for m in data['slide_marks']))
                        self.assertFalse(any(b['issues'] for s in data['systems'] for b in s['bars']))

    def test_missing_or_conflicting_boundary_evidence_is_not_joined(self):
        modes=('same_fret','other_string','no_line','partial_lines','wrong_slope','short_line',
               'no_out_arc','no_in_arc','wrong_side','wrong_target','short_arc','duplicate_arc',
               'skipped_bar','intervening_rest','missing_tone')
        for chord in (False,True):
            for mode in modes+(('partial',) if chord else ('no_label',)):
                with self.subTest(chord=chord,mode=mode),tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'boundary.pdf';boundary_fixture(pdf,mode,chord,True)
                    data=recognize(pdf)
                    self.assertFalse(any(n.get('legato_slide') for s in data['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_boundary_chord_export_playback_and_excerpt_guards(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'boundary.pdf';boundary_fixture(pdf,'down',True,True)
            data=recognize(pdf);raw=root/'recognized.json';raw.write_text(json.dumps(data),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const {comparePlayback}=require('./experiments/pdf-tab-prototype/verify-playback.cjs');
const load=()=>a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const actual=load(),flat=load();
for(const b of flat.tracks[0].staves[0].bars)for(const v of b.voices)for(const beat of v.beats)for(const n of beat.notes){n.slideOutType=0;n.slideTarget=null;n.slideOrigin=null;}
const notes=actual.tracks[0].staves[0].bars[0].voices[0].beats[3].notes;
console.log(JSON.stringify({slides:notes.map(n=>[7-n.string,n.slideOutType,n.slideTarget?.fret]),playback:comparePlayback(actual,flat,0)}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(sorted(result['slides']),[[4,2,6],[5,2,6],[6,2,4]])
            self.assertEqual(result['playback']['actual']['note_attacks'],21)
            self.assertEqual(result['playback']['reference']['note_attacks'],24)
            for selection in ('1','2'):
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(root/f'{selection}.gp'),selection],capture_output=True,text=True)
                self.assertNotEqual(run.returncode,0);self.assertIn('Slide',run.stderr)


if __name__=='__main__':unittest.main()
