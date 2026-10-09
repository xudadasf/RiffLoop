"""Small controlled fixtures complement the separately held-out real PDFs."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
import fitz
from recognize import recognize
from symbols import font_buffer,outline_spans
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
import io

HERE=Path(__file__).parent


def fixture(path,missing_stem=False,meter=True,empty=False,hidden_tie=False,slur=False):
    doc=fitz.open(); page=doc.new_page(width=400,height=250)
    page.insert_text((30,30),'Standard tuning',fontname='Times-Roman',fontsize=9)
    page.insert_text((30,45),'= 90',fontname='Times-Roman',fontsize=9)
    for y in range(100,131,6): page.draw_line((30,y),(350,y),width=.4)
    for x in [30,350]: page.draw_line((x,100),(x,130),width=.5)
    if meter:
        page.insert_font(fontname='music',fontbuffer=font_buffer())
        numerator,denominator=(4,4) if meter is True else meter
        page.insert_text((38,110),chr(0xe080+numerator),fontsize=17,fontname='music')
        page.insert_text((38,118.5),chr(0xe080+denominator),fontsize=17,fontname='music')
    for i,fret in enumerate([] if empty else ['7','10','0','12']):
        x=70+i*70; y=100+i*6
        w=fitz.get_text_length(fret,fontname='helv',fontsize=7)
        if not (hidden_tie and i==1): page.insert_text((x-w/2,y+2.4),fret,fontname='helv',fontsize=7)
        if not (missing_stem and i==2): page.draw_line((x,y+5),(x,150),width=.5)
    if hidden_tie or slur:
        shape=page.new_shape()
        shape.draw_bezier((70,104),(90,108),(120,108),(140,104))
        shape.draw_bezier((140,104),(120,107),(90,107),(70,104))
        shape.finish(color=None,fill=(0,0,0)); shape.commit()
    doc.save(path)
    doc.close()


def boundary_fixture(path,page_break=False,standard=False,arcs='both',changed_pitch=False,
                     number_gap=False,source_rest=False,partial_chord=False,ambiguous_arc=False,
                     parentheses=True):
    doc=fitz.open(); page=doc.new_page(width=400,height=500)
    page.insert_text((30,25),'Standard tuning = 90',fontname='Times-Roman',fontsize=9)
    for index in range(2):
        if index and page_break: page=doc.new_page(width=400,height=500)
        top=100 if not index or page_break else 280
        page.insert_font(fontname='music',fontbuffer=font_buffer())
        for y in range(top,top+31,6): page.draw_line((30,y),(350,y),width=.4)
        for x in (30,350): page.draw_line((x,top),(x,top+30),width=.5)
        if standard:
            for i in range(5): page.draw_line((30,top-40+i*4.25),(350,top-40+i*4.25),width=.4)
        page.insert_text((30,top-(42 if standard else 2)),str(index+1+(1 if index and number_gap else 0)),
                         fontname='Times-Roman',fontsize=6)
        if not index:
            for y in (top+10,top+18.5):page.insert_text((38,y),'\ue084',fontsize=17,fontname='music')
        for beat,x in enumerate((70,140,210,280)):
            if not index and beat==3 and source_rest:
                page.insert_text((x,top+12),'\ue4e5',fontsize=17,fontname='music');continue
            for string,fret in ([(2,5),(3,7)] if standard or ambiguous_arc else [(3,7)]):
                token=str(fret+(1 if index and beat==0 and changed_pitch else 0))
                if index and beat==0 and parentheses:token='('+token+')'
                width=fitz.get_text_length(token,fontname='helv',fontsize=7)
                page.insert_text((x-width/2,top+(string-1)*6+2.4),token,fontname='helv',fontsize=7)
            page.draw_line((x,top+17),(x,top+50),width=.5)
        draw_arc=(not index and arcs in ('both','outgoing')) or (index and arcs in ('both','incoming'))
        if draw_arc:
            for y in ([top-28,top-24] if standard else [top+(9 if ambiguous_arc else 12)]):
                if partial_chord and standard and index and y==top-24:continue
                a,z=(283,349) if not index else (40,62)
                sh=page.new_shape()
                sh.draw_bezier((a,y),(a+4,y+4),(z-4,y+4),(z,y))
                sh.draw_bezier((z,y),(z-4,y+3),(a+4,y+3),(a,y))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
    doc.save(path);doc.close()


def wide_tie_fixture(path,mode='chain'):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        page=doc[0];boxes=[]
        for i,token in enumerate(['14','(14)','(14)','12']):
            x=70+i*70;y=112
            if i==1:
                if mode=='rest':
                    page.insert_font(fontname='music',fontbuffer=font_buffer())
                    page.insert_text((x,y),'\ue4e5',fontsize=17,fontname='music');boxes.append(None);continue
                if mode=='intervening_note':token='8'
                if mode=='different_pitch':token='(15)'
                if mode=='plain':token='14'
                if mode=='cross_string':y=118
            width=fitz.get_text_length(token,fontname='helv',fontsize=7)
            page.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7)
            page.draw_line((x,y+5),(x,150),width=.5)
            boxes.append((x-width/2,x+width/2))
        pairs=[] if mode=='no_arc' else ([(0,1),(1,2)] if mode=='chain' else
              [(0,2)] if mode in ('rest','intervening_note') else [(0,1)])
        for start,end in pairs:
            a=boxes[start][1]+1.4;z=boxes[end][0]-1.4
            sh=page.new_shape()
            sh.draw_bezier((a,112),(a+4,108),(z-4,108),(z,112))
            sh.draw_bezier((z,112),(z-4,109),(a+4,109),(a,112))
            sh.finish(color=None,fill=(0,0,0));sh.commit()
        doc.saveIncr()


def hidden_staff_chord_fixture(path,mode='single'):
    fixture(path,empty=True)
    with fitz.open(path) as doc:
        page=doc[0];page.insert_font(fontname='music',fontbuffer=font_buffer())
        for i in range(5):page.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
        for i,x in enumerate((70,140,210,280)):
            hidden=i==1 or mode=='chain' and i==2
            for tone,y in enumerate((50,58.5)):
                hy=y+(2.125 if mode=='shifted_head' and i==1 and tone==0 else 0)
                page.insert_text((x-2.5,hy),'\ue0a4',fontname='music',fontsize=17)
                if not hidden or mode=='visible_target':
                    token='X' if mode=='dead_source' and i==0 else str(tone+5)
                    width=fitz.get_text_length(token,fontname='helv',fontsize=7)
                    page.insert_text((x-width/2,102.4+tone*6),token,fontname='helv',fontsize=7)
            if not (mode=='missing_stem' and i==1):page.draw_line((x+2.2,40),(x+2.2,58),width=.5)
        if mode=='rest_between':page.insert_text((105,112),'\ue4e5',fontname='music',fontsize=17)
        for source,target in ([(70,140),(140,210)] if mode=='chain' else [(70,140)]):
            for tone,y in enumerate((50.8,59.3)):
                if mode=='no_arcs' or mode=='partial_arcs' and tone==1:continue
                sh=page.new_shape();a=source+3;z=target-3
                sh.draw_bezier((a,y),(a+5,y+3),(z-5,y+3),(z,y))
                sh.draw_bezier((z,y),(z-5,y+2),(a+5,y+2),(a,y))
                sh.finish(color=None,fill=(0,0,0));sh.commit()
        doc.saveIncr()


class PrototypeTests(unittest.TestCase):
    def test_hidden_staff_chord_and_chain_survive_gp_roundtrip(self):
        for mode in ('single','chain'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'chord.pdf';hidden_staff_chord_fixture(pdf,mode)
                result=recognize(pdf);bar=result['systems'][0]['bars'][0]
                self.assertEqual(bar['issues'],[])
                self.assertEqual(len(bar['beats']),4)
                self.assertEqual([len(b['notes']) for b in bar['beats']],[2]*4)
                self.assertTrue(all(n['tie'] for n in bar['beats'][1]['notes']))
                self.assertEqual(sum(n['tie'] for b in bar['beats'] for n in b['notes']),4 if mode=='chain' else 2)
                data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)

    def test_hidden_staff_chord_needs_every_tone_arc_head_and_stem(self):
        for mode in ('partial_arcs','no_arcs','shifted_head','missing_stem','rest_between','dead_source','visible_target'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'chord.pdf';hidden_staff_chord_fixture(pdf,mode)
                result=recognize(pdf)
                self.assertFalse(any(n.get('inferred_from')=='standard-heads-and-tie-curves'
                                     for s in result['systems'] for b in s['bars'] for v in b['beats'] for n in v['notes']))

    def test_wide_parenthesized_tie_chain_and_gp_roundtrip(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'wide.pdf';wide_tie_fixture(pdf)
            result=recognize(pdf);bar=result['systems'][0]['bars'][0]
            self.assertEqual(bar['issues'],[])
            self.assertEqual([b['notes'][0]['tie'] for b in bar['beats']],[False,True,True,False])
            data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],
                               capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)

    def test_wide_tie_does_not_join_rest_other_note_or_slur(self):
        for mode in ['rest','intervening_note','different_pitch','plain','cross_string','no_arc']:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'wide.pdf';wide_tie_fixture(pdf,mode)
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertFalse(any(n['tie'] for b in bar['beats'] for n in b['notes']))

    def test_boundary_ties_same_page_and_next_page_roundtrip(self):
        for page_break in (False,True):
            for standard in (False,True):
                with self.subTest(page_break=page_break,standard=standard), tempfile.TemporaryDirectory() as folder:
                    pdf=Path(folder)/'boundary.pdf'
                    boundary_fixture(pdf,page_break=page_break,standard=standard)
                    result=recognize(pdf)
                    self.assertEqual(len(result['systems']),2)
                    target=result['systems'][1]['bars'][0]
                    self.assertEqual(target['issues'],[])
                    self.assertTrue(all(n['tie'] and n['tie_source_bar']==1 for n in target['beats'][0]['notes']))
                    data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
                    run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],
                                       capture_output=True,text=True)
                    self.assertEqual(run.returncode,0,run.stderr)

    def test_boundary_ties_require_both_arcs_pitch_continuity_and_origin(self):
        cases=[{'arcs':'none'},{'arcs':'outgoing'},{'arcs':'incoming'},
               {'changed_pitch':True},{'number_gap':True},{'source_rest':True},
               {'standard':True,'partial_chord':True},{'ambiguous_arc':True},{'parentheses':False}]
        for options in cases:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'boundary.pdf';boundary_fixture(pdf,**options)
                result=recognize(pdf)
                self.assertFalse(any(n['tie'] for b in result['systems'][1]['bars'][0]['beats'] for n in b['notes']))

    def test_boundary_tie_cannot_export_without_previous_system(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'boundary.pdf';boundary_fixture(pdf,page_break=True)
            data=Path(folder)/'recognized.json';data.write_text(json.dumps(recognize(pdf)),encoding='utf-8')
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp'),'2-2'],
                               capture_output=True,text=True)
            self.assertNotEqual(run.returncode,0)
            self.assertFalse((Path(folder)/'out.gp').exists())

    def test_cross_string_slur_does_not_invent_tied_note(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'slur.pdf';fixture(path,slur=True)
            bar=recognize(path)['systems'][0]['bars'][0]
            self.assertEqual(len(bar['beats']),4)
            self.assertFalse(any(n['tie'] for b in bar['beats'] for n in b['notes']))

    def test_chord_dot_columns_are_counted_once(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder)/'base.pdf';fixture(base,empty=True)
            with fitz.open(base) as doc:
                p=doc[0]
                for i in range(5):p.draw_line((30,40+i*4.25),(350,40+i*4.25),width=.4)
                for y in (100,106):p.insert_text((98.05,y+2.4),'7',fontname='helv',fontsize=7)
                p.draw_line((100,111),(100,150),width=.4)
                p.insert_font(fontname='music',fontbuffer=font_buffer())
                for y in (40,44.25):
                    p.insert_text((97.5,y),'\ue0a4',fontname='music',fontsize=17)
                    p.insert_text((103.8,y+2.125),'\ue1e7',fontname='music',fontsize=17)
                path=Path(folder)/'dots.pdf';doc.save(path)
            beat=recognize(path)['systems'][0]['bars'][0]['beats'][0]
            self.assertEqual(len(beat['notes']),2)
            self.assertEqual(beat['dots'],1)

    def test_ledger_fragments_do_not_hide_standard_staff(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder)/'base.pdf';fixture(base)
            with fitz.open(base) as doc:
                for i in range(5): doc[0].draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
                for x in (70,160,250): doc[0].draw_line((x,58.6),(x+26,58.6),width=.4)
                path=Path(folder)/'ledger.pdf';doc.save(path)
            self.assertEqual(recognize(path)['systems'][0]['standard']['count'],5)

    def test_circled_tab_notes_are_half_notes(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder)/'base.pdf';fixture(base,empty=True)
            with fitz.open(base) as doc:
                page=doc[0]
                for x in (100,250):
                    page.insert_text((x-1.95,102.4),'7',fontname='helv',fontsize=7)
                    page.draw_oval(fitz.Rect(x-5,95,x+5,105),width=.4)
                    page.draw_line((x,140),(x,146),width=.4)
                path=Path(folder)/'halves.pdf';doc.save(path)
            bar=recognize(path)['systems'][0]['bars'][0]
            self.assertEqual([b['duration'] for b in bar['beats']],[2,2])
            self.assertEqual(bar['issues'],[])

    def test_unknown_mark_is_not_assumed_to_be_silence(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder)/'base.pdf';fixture(base,empty=True)
            with fitz.open(base) as doc:
                doc[0].draw_polyline([(150,105),(158,114),(146,118),(150,105)],fill=(0,0,0))
                path=Path(folder)/'unknown.pdf';doc.save(path)
            bar=recognize(path)['systems'][0]['bars'][0]
            self.assertTrue(bar['issues'])
            self.assertFalse(any(b.get('fullBarRest') for b in bar['beats']))

    def test_outlined_rest_uses_font_not_reference_gp(self):
        font=TTFont(io.BytesIO(font_buffer())); glyphs=font.getGlyphSet()
        pen=SVGPathPen(glyphs); glyphs[font.getBestCmap()[0xe4e6]].draw(pen)
        svg='<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80"><path transform="translate(30 40) scale(.02 -.02)" d="'+pen.getCommands()+'"/></svg>'
        with fitz.open(stream=svg.encode(),filetype='svg') as doc:
            with fitz.open(stream=doc.convert_to_pdf(),filetype='pdf') as pdf:
                symbols=outline_spans(pdf[0].get_drawings())
        self.assertEqual([s['text'] for s in symbols],['\ue4e6'])

    def test_hidden_tie_recovers_fret_and_survives_gp_roundtrip(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'tie.pdf'; fixture(path,hidden_tie=True)
            result=recognize(path); bar=result['systems'][0]['bars'][0]
            self.assertEqual(bar['issues'],[])
            self.assertEqual(len(bar['beats']),4)
            note=bar['beats'][1]['notes'][0]
            self.assertEqual((note['string'],note['fret'],note['tie']),(1,7,True))
            data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'tie.gp')],capture_output=True)
            self.assertEqual(run.returncode,0,run.stderr.decode('utf-8',errors='replace'))

    def test_three_four_empty_bar_survives_gp_roundtrip(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'rest.pdf'; fixture(path,empty=True,meter=(3,4))
            result=recognize(path);bar=result['systems'][0]['bars'][0]
            self.assertEqual(bar['meter'],[3,4]);self.assertEqual(bar['issues'],[])
            data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'rest.gp')],capture_output=True)
            self.assertEqual(run.returncode,0,run.stderr.decode('utf-8',errors='replace'))

    def test_empty_bar_is_rest_only_with_confirmed_meter(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'empty.pdf'; fixture(path,empty=True)
            bar=recognize(path)['systems'][0]['bars'][0]
            self.assertEqual(bar['issues'],[])
            self.assertTrue(bar['beats'][0]['fullBarRest'])
            fixture(Path(folder)/'unknown.pdf',meter=False,empty=True)
            unknown=recognize(Path(folder)/'unknown.pdf')['systems'][0]['bars'][0]
            self.assertTrue(unknown['issues'])
            self.assertEqual(unknown['beats'],[])

    def test_pdf_strings_frets_and_quarters_without_reference(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'source.pdf'; fixture(path)
            result=recognize(path); bars=[b for s in result['systems'] for b in s['bars']]
            self.assertEqual(len(bars),1)
            self.assertEqual([(n['string'],n['fret']) for b in bars[0]['beats'] for n in b['notes']],[(1,7),(2,10),(3,0),(4,12)])
            self.assertEqual([b['duration'] for b in bars[0]['beats']],[4]*4)
            self.assertEqual(bars[0]['issues'],[])
            data=Path(folder)/'recognized.json'; data.write_text(json.dumps(result),encoding='utf-8')
            out=Path(folder)/'test.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(out)],capture_output=True)
            self.assertEqual(run.returncode,0,run.stderr.decode('utf-8',errors='replace'))
            self.assertTrue(out.is_file())

    def test_unrecognized_rhythm_blocks_export(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'source.pdf'; fixture(path,missing_stem=True)
            result=recognize(path)
            self.assertTrue(result['systems'][0]['bars'][0]['issues'])
            data=Path(folder)/'recognized.json'; data.write_text(json.dumps(result),encoding='utf-8')
            out=Path(folder)/'test.gp'
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(out)],capture_output=True)
            self.assertNotEqual(run.returncode,0)
            self.assertFalse(out.exists())

    def test_image_only_pdf_is_not_silently_converted(self):
        with tempfile.TemporaryDirectory() as folder:
            vector=Path(folder)/'vector.pdf'; fixture(vector)
            with fitz.open(vector) as source:
                pixels=source[0].get_pixmap(matrix=fitz.Matrix(2,2))
            doc=fitz.open(); page=doc.new_page(width=400,height=250)
            page.insert_image(page.rect,pixmap=pixels)
            raster=Path(folder)/'scan.pdf'; doc.save(raster)
            self.assertEqual(recognize(raster)['systems'],[])

    def test_failed_rerun_removes_previous_export(self):
        with tempfile.TemporaryDirectory() as folder:
            out=Path(folder)/'experimental.gp'
            out.write_bytes(b'old successful output')
            run=subprocess.run([sys.executable,str(HERE/'convert.py'),str(Path(folder)/'missing.pdf'),
                                '--out',folder],capture_output=True)
            self.assertNotEqual(run.returncode,0)
            self.assertFalse(out.exists())


if __name__=='__main__': unittest.main()
