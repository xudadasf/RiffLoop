import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def document_fixture(path,mode='valid',anchors_first=False):
    with fitz.open() as doc:
        pages=[doc.new_page(width=420,height=240) for _ in range(2)]
        # Adding pages invalidates old Page handles.
        pages=[doc[i] for i in range(2)]
        for pi,p in enumerate(pages):
            anchors=(pi==0)==anchors_first
            gap=7 if anchors and mode=='different_spacing' else 6
            y=100+2*gap;bottom=100+5*gap
            if pi==0:p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
            p.insert_font(fontname='music',fontbuffer=font_buffer())
            for i in range(6):p.draw_line((30,100+i*gap),(390,100+i*gap),width=.4)
            for x in (30,390):p.draw_line((x,100),(x,bottom),width=.5)
            p.insert_text((30,98),str(pi+1),fontname='Times-Roman',fontsize=6)
            for yy in (110,118.5):p.insert_text((38,yy),'\ue084',fontname='music',fontsize=17)
            def text(x,token,size=7,font='helv'):
                p.insert_text((x-fitz.get_text_length(token,fontname=font,fontsize=size)/2,y+size*.34),token,fontname=font,fontsize=size)
            def arc(a,z,yy):
                sh=p.new_shape();sh.draw_bezier((a,yy),(a+5,yy+4),(z-5,yy+4),(z,yy))
                sh.draw_bezier((z,yy),(z-5,yy+3),(a+5,yy+3),(a,yy))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
            half=fitz.get_text_length('(12)',fontname='helv',fontsize=7)/2+1.4
            if anchors:
                for i,x in enumerate((70,140,210,280)):
                    token='(12)' if i in (1,2) and not (mode=='one_anchor' and i==2) else '12'
                    text(x,token,8 if mode=='different_size' else 7,'cour' if mode=='different_font' else 'helv')
                    p.draw_line((x,y+5),(x,bottom+20),width=.4)
                arc(75,140-half,y);arc(140+half,210-half+(1 if mode=='inconsistent_padding' else 0),y)
            else:
                text(70,'12');p.draw_line((70,y+5),(70,bottom+20),width=.4)
                if mode!='missing_stem':p.draw_line((140,bottom+4.5),(140,bottom+15),width=.4)
                arc(75,140-half-(1 if mode=='wrong_target_padding' else 0),y)
                if mode=='visible_target':text(140,'14')
                if mode=='intervening_rest':p.insert_text((110,y),'\ue4e5',fontname='music',fontsize=17)
                for x in (210,280):p.insert_text((x,y),'\ue4e5',fontname='music',fontsize=17)
        if mode=='same_name_different_resource':
            p=pages[0 if anchors_first else 1]
            original=next(f[0] for f in p.get_fonts() if f[3]=='Helvetica')
            replacement=doc.get_new_xref();doc.update_object(replacement,doc.xref_object(original))
            resources=int(doc.xref_get_key(p.xref,'Resources')[1].split()[0])
            doc.xref_set_key(resources,'Font/helv',f'{replacement} 0 R')
        doc.save(path)


class DocumentTiePaddingTests(unittest.TestCase):
    def test_measurements_can_come_from_an_earlier_or_later_page(self):
        for first in (False,True):
            with self.subTest(anchors_first=first),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ties.pdf';document_fixture(pdf,anchors_first=first)
                data=recognize(pdf);bar=data['systems'][1 if first else 0]['bars'][0]
                self.assertFalse(bar['issues'])
                self.assertEqual([v['duration'] for v in bar['beats']],[4,4,4,4])
                self.assertEqual([(n['fret'],n['tie']) for v in bar['beats'] for n in v['notes']],[(12,False),(12,True)])

    def test_insufficient_or_incompatible_samples_do_not_supply_a_width(self):
        for mode in ('one_anchor','different_font','different_size','different_spacing','same_name_different_resource',
                     'inconsistent_padding','wrong_target_padding','missing_stem','visible_target','intervening_rest'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ties.pdf';document_fixture(pdf,mode)
                if mode=='same_name_different_resource':
                    with fitz.open(pdf) as d:
                        fonts=[next(f[0] for f in d[i].get_fonts() if f[3]=='Helvetica') for i in range(2)]
                        self.assertNotEqual(*fonts)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertFalse(any(n.get('inferred_from') for v in bar['beats'] for n in v['notes']))

    def test_export_holds_note_for_two_beats_without_adding_an_attack(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'ties.pdf';document_fixture(pdf)
            raw=root/'recognized.json';raw.write_text(json.dumps(recognize(pdf)),encoding='utf-8');gp=root/'out.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(raw),str(gp)],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
            script=r'''
const fs=require('fs'),a=require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const s=a.importer.ScoreLoader.loadScoreFromBytes(new Uint8Array(fs.readFileSync(process.argv[1])),new a.Settings());
const notes=[];class Handler extends a.midi.AlphaSynthMidiFileHandler {
 addNote(t,tick,duration,key,velocity,channel){notes.push([tick,duration]);super.addNote(t,tick,duration,key,velocity,channel);}
}
const g=new a.midi.MidiFileGenerator(s,new a.Settings(),new Handler(new a.midi.MidiFile()));g.generate();
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr);result=json.loads(run.stdout)
            self.assertEqual(result['notes'][0],[0,1920])
            self.assertEqual(len(result['notes']),3)
            self.assertEqual(result['end'],7680)


if __name__=='__main__':unittest.main()
