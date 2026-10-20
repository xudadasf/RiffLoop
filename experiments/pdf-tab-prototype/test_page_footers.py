import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import fitz
from recognize import recognize
from symbols import font_buffer

HERE=Path(__file__).parent


def footer_fixture(path,mode='footer',standard=False,meter=(4,4),pages=2):
    with fitz.open() as doc:
        for index in range(pages):
            p=doc.new_page(width=400,height=300 if mode!='body_fraction' else 450)
            p.insert_font(fontname='music',fontbuffer=font_buffer())
            if not index:p.insert_text((30,30),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
            top=251 if mode=='near_staff' else 240
            for y in range(top,top+31,6):p.draw_line((30,y),(350,y),width=.4)
            for x in (30,350):p.draw_line((x,top),(x,top+30),width=.4)
            if standard:
                for y in range(top-40,top-15,6):p.draw_line((30,y),(350,y),width=.4)
            p.insert_text((30,top-(42 if standard else 2)),str(index+1),fontname='Times-Roman',fontsize=6)
            if meter and not index:
                for y,digit in zip((top+10,top+18.5),meter):
                    p.insert_text((38,y),chr(0xe080+digit),fontname='music',fontsize=17)
            label=f'{index+1}/{pages}'
            if mode=='wrong_total':label=f'{index+1}/{pages+1}'
            if mode=='wrong_page':label=f'{pages-index}/{pages}'
            if mode=='extra_text':label+=' tempo'
            size=12 if mode=='large' else 8
            x=(200 if mode=='centered' else 350)-fitz.get_text_length(label,fontname='Times-Roman',fontsize=size)
            y=top+15 if mode=='inside_staff' else 287
            for _ in range(2 if mode=='duplicate' else 1):
                p.insert_text((x,y),label,fontname='Times-Roman',fontsize=size)
            if mode=='unknown_ink':p.draw_circle((150,top+15),1,color=None,fill=(0,0,0))
            if mode=='unknown_text':p.insert_text((160,top+25),'?',fontname='helv',fontsize=7)
            if mode=='notes':
                for x in (80,150,220,290):
                    p.insert_text((x-1.95,top+2.4),'7',fontname='helv',fontsize=7)
                    p.draw_line((x,top+5),(x,top+50),width=.4)
        doc.save(path)


class PageFooterTests(unittest.TestCase):
    def test_page_numbers_do_not_block_empty_bars_with_confirmed_meter(self):
        for standard,pages,meter in ((False,1,(4,4)),(False,2,(3,4)),(True,2,(4,4))):
            with self.subTest(standard=standard,pages=pages,meter=meter),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'footer.pdf';footer_fixture(pdf,standard=standard,pages=pages,meter=meter)
                data=recognize(pdf);bars=[b for s in data['systems'] for b in s['bars']]
                self.assertEqual(len(bars),pages)
                for b in bars:
                    self.assertFalse(b['issues'])
                    self.assertEqual(b['meter'],list(meter))
                    self.assertEqual(len(b['beats']),1)
                    self.assertTrue(b['beats'][0]['fullBarRest'])

    def test_fraction_or_unknown_ink_cannot_be_removed_as_footer(self):
        for mode in ('wrong_total','wrong_page','extra_text','large','centered','inside_staff',
                     'near_staff','body_fraction','duplicate','unknown_ink','unknown_text','no_meter'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ambiguous.pdf';footer_fixture(pdf,mode,meter=False if mode=='no_meter' else (4,4))
                for s in recognize(pdf)['systems']:
                    for bar in s['bars']:
                        self.assertTrue(bar['issues'])
                        self.assertFalse(any(v.get('fullBarRest') for v in bar['beats']))

    def test_notes_and_actual_gp_midi_silence_keep_their_timing(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);pdf=root/'notes.pdf';footer_fixture(pdf,'notes')
            for s in recognize(pdf)['systems']:
                for bar in s['bars']:
                    self.assertFalse(bar['issues'])
                    self.assertEqual([v['duration'] for v in bar['beats']],[4]*4)
                    self.assertEqual([v['notes'][0]['fret'] for v in bar['beats']],[7]*4)
            pdf=root/'rest.pdf';footer_fixture(pdf,meter=(3,4))
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
console.log(JSON.stringify({notes,end:g.tickLookup.masterBars.at(-1).end,bars:s.masterBars.length,
 meters:s.masterBars.map(b=>[b.timeSignatureNumerator,b.timeSignatureDenominator])}));
'''
            run=subprocess.run(['node','-e',script,str(gp)],cwd=HERE.parent.parent,capture_output=True,text=True,check=True)
            self.assertEqual(json.loads(run.stdout),{'notes':[],'end':5760,'bars':2,'meters':[[3,4],[3,4]]})


if __name__=='__main__':unittest.main()
