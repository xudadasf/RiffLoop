"""Small controlled fixtures complement the separately held-out real PDFs."""
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
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


def outlined_meter(page,meter):
    outlined_music(page,[(0xe080+value,38,y,17) for value,y in zip(meter,(110,118.5))])


def outlined_music(page,symbols):
    font=TTFont(io.BytesIO(font_buffer()));glyphs=font.getGlyphSet();paths=[]
    for code,x,y,size in symbols:
        pen=SVGPathPen(glyphs);glyphs[font.getBestCmap()[code]].draw(pen)
        paths.append(f'<path transform="translate({x} {y}) scale({size/font["head"].unitsPerEm} {-size/font["head"].unitsPerEm})" d="{pen.getCommands()}"/>')
    svg='<svg xmlns="http://www.w3.org/2000/svg" width="400" height="250">'+''.join(paths)+'</svg>'
    with fitz.open(stream=svg.encode(),filetype='svg') as source:
        with fitz.open(stream=source.convert_to_pdf(),filetype='pdf') as vector:
            page.show_pdf_page(page.rect,vector,0)
    font.close()


class PrototypeTests(unittest.TestCase):
    def test_rhythm_diagnostic_checks_timeline_not_only_total_or_pitch(self):
        from diagnostics import rhythm_reason
        import copy
        beat={'voice':0,'duration':4,'dots':0,'grace':False,'tuplet':[1,1],
              'notes':[{'string':3,'fret':7,'dead':False,'tie':False}]}
        reference={'meter':[4,4],'meter_source':'pdf','issues':[],
                   'beats':[copy.deepcopy(beat) for _ in range(4)]}
        for mode in ('same','pitch','shifted_onset','rest','reattack','unknown','meter'):
            with self.subTest(mode=mode):
                actual=copy.deepcopy(reference);expected=copy.deepcopy(reference)
                if mode=='pitch':actual['beats'][0]['notes'][0]['fret']=9
                if mode=='shifted_onset':
                    actual['beats'][0]['duration']=8;actual['beats'][1]['dots']=1
                if mode=='rest':actual['beats'][1]['notes']=[]
                if mode=='reattack':expected['beats'][1]['notes'][0]['tie']=True
                if mode=='unknown':actual['beats'][0]['duration']=None
                if mode=='meter':actual['meter']=[3,4]
                reason='pass' if mode in ('same','pitch') else {'unknown':'unknown_duration','meter':'meter'}.get(mode,'timing_attack_rest')
                self.assertEqual(rhythm_reason(actual,expected),reason)

    def test_wide_hidden_chord_cutout_requires_paired_arcs_and_same_pitch(self):
        for mode in ('valid','no_outgoing','wrong_pitch','asymmetric','shifted_string','no_stem','intervening','outgoing_rest'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'wide-cutout.pdf';fixture(pdf,empty=True)
                with fitz.open(pdf) as doc:
                    p=doc[0];p.draw_line((190,100),(190,130),width=.5)
                    p.insert_font(fontname='music',fontbuffer=font_buffer())
                    p.insert_text((70,112),'\ue4e5',fontsize=17,fontname='music')
                    for string,fret in ((2,12),(3,13)):
                        y=100+(string-1)*6
                        for x in (110,260):
                            token=str(fret+(1 if mode=='wrong_pitch' and x==260 else 0))
                            if x==260:token='('+token+')'
                            width=fitz.get_text_length(token,fontname='helv',fontsize=7)
                            p.insert_text((x-width/2,y+2.4),token,fontname='helv',fontsize=7)
                        z=260-width/2-1.4
                        pairs=[(116,152.2)]
                        if mode!='no_outgoing':pairs.append((169 if mode=='asymmetric' else 167.8,z))
                        for a,b in pairs:
                            ay=y+2 if mode=='shifted_string' else y
                            sh=p.new_shape();sh.draw_bezier((a,ay),(a+8,ay+4),(b-8,ay+4),(b,ay))
                            sh.draw_bezier((b,ay),(b-8,ay+3),(a+8,ay+3),(a,ay))
                            sh.finish(color=None,fill=(0,0,0));sh.commit()
                    p.draw_oval(fitz.Rect(104,101,116,117),width=.4)
                    p.draw_line((110,139),(110,145),width=.5)
                    if mode!='no_stem':p.draw_line((160,134.5),(160,145),width=.5)
                    if mode=='intervening':p.insert_text((140,112),'\ue4e5',fontsize=17,fontname='music')
                    if mode=='outgoing_rest':p.insert_text((225,112),'\ue4e5',fontsize=17,fontname='music')
                    doc.saveIncr()
                result=recognize(pdf);bars=result['systems'][0]['bars']
                inferred=[n for b in bars for beat in b['beats'] for n in beat['notes'] if n.get('inferred_from')]
                if mode=='valid':
                    self.assertEqual(len(inferred),2)
                    self.assertEqual([b['issues'] for b in bars],[[],[]])
                    self.assertEqual([beat['duration'] for b in bars for beat in b['beats']],[4,2,4,1])
                    self.assertTrue(all(n['tie'] for n in bars[1]['beats'][0]['notes']))
                    data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
                    run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],capture_output=True,text=True)
                    self.assertEqual(run.returncode,0,run.stderr)
                else:
                    self.assertFalse(inferred)
                    self.assertTrue(bars[1]['issues'])

    def test_export_verification_requires_explicit_index_for_duplicate_track_names(self):
        import verify_export
        beat={'voice':0,'duration':1,'dots':0,'grace':False,'tuplet':[1,1],
              'notes':[{'string':3,'fret':7,'dead':False,'tie':False}]}
        track={'name':'Guitar','track':0,'staff':0,'tuning':[64,59,55,50,45,40],
               'bars':[{'number':1,'meter':[4,4],'beats':[beat]}]}
        actual={'tempo':90,'tracks':[track]}
        empty={**track,'track':1,'bars':[{'number':1,'meter':[4,4],'beats':[{**beat,'notes':[]}]}]}
        reference={'tempo':90,'tracks':[track,empty]}
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/'verification.json'
            def import_score(command,**kwargs):
                data=actual if command[-2]=='actual.gp' else reference
                Path(command[-1]).write_text(json.dumps(data),encoding='utf-8')
            base=['verify_export.py','actual.gp','reference.gp','--track','Guitar','--bars','1-1','--out',str(output)]
            for index,code in [(None,None),(0,0),(1,1),(2,None)]:
                args=base+([] if index is None else ['--track-index',str(index)])
                with self.subTest(index=index),patch.object(sys,'argv',args),patch.object(verify_export.subprocess,'run',side_effect=import_score):
                    if code is None:
                        with self.assertRaises(ValueError):verify_export.main()
                    else:
                        self.assertEqual(verify_export.main(),code)

    def test_stemless_whole_continuation_requires_clean_notation_and_proven_ties(self):
        modes=('single','chord','cutout','off_staff_line','no_arc','different_pitch','plain_number','unknown_mark',
               'short_line','extra_beat','invalid_source','three_four')
        for mode in modes:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'whole-tie.pdf';fixture(pdf,empty=True,meter=(3,4) if mode=='three_four' else True)
                with fitz.open(pdf) as doc:
                    page=doc[0];page.draw_line((190,100),(190,130),width=.5)
                    tones=[(3,7),(4,9)] if mode=='chord' else [(3,7)]
                    xs=(70,115,160) if mode=='three_four' else (70,100,130,160)
                    for x in (*xs,260):
                        for string,fret in tones:
                            token=str(fret+(1 if x==260 and mode=='different_pitch' else 0))
                            if x==260 and mode!='plain_number':token='('+token+')'
                            w=fitz.get_text_length(token,fontname='helv',fontsize=7)
                            page.insert_text((x-w/2,100+(string-1)*6+2.4),token,fontname='helv',fontsize=7)
                        if x!=260 and not (mode=='invalid_source' and x==100):page.draw_line((x,123),(x,150),width=.5)
                    if mode!='no_arc':
                        for string,fret in tones:
                            y=100+(string-1)*6;token='('+str(fret)+')'
                            z=260-fitz.get_text_length(token,fontname='helv',fontsize=7)/2-1.4
                            sh=page.new_shape();sh.draw_bezier((164,y),(170,y+4),(z-6,y+4),(z,y))
                            sh.draw_bezier((z,y),(z-6,y+3),(170,y+3),(164,y))
                            sh.finish(color=None,fill=(0,0,0));sh.commit()
                    if mode=='unknown_mark':page.draw_circle((300,143),2,color=None,fill=(0,0,0))
                    if mode in ('cutout','off_staff_line'):
                        y=112 if mode=='cutout' else 115
                        page.draw_line((193,y),(202,y),width=.4)
                    if mode=='short_line':page.draw_line((260,155),(260,158),width=.5)
                    if mode=='extra_beat':
                        page.insert_text((307,114.4),'9',fontname='helv',fontsize=7)
                        page.draw_line((310,123),(310,150),width=.5)
                    doc.saveIncr()
                result=recognize(pdf);bars=result['systems'][0]['bars'];bar=bars[1]
                if mode in ('single','chord','cutout','three_four'):
                    self.assertEqual(bar['beats'][0]['duration'],1)
                    if mode=='three_four':self.assertTrue(bar['issues']);continue
                    self.assertTrue(all(not b['issues'] for b in bars))
                    self.assertTrue(all(n['tie'] for n in bar['beats'][0]['notes']))
                    data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
                    run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],capture_output=True,text=True)
                    self.assertEqual(run.returncode,0,run.stderr)
                else:
                    self.assertIsNone(bar['beats'][0]['duration'])
                    self.assertTrue(bar['issues'])

    def test_next_system_ink_does_not_block_an_empty_bar(self):
        for local_mark in (False,True):
            with self.subTest(local_mark=local_mark),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'nearby-system.pdf';fixture(pdf,empty=True)
                with fitz.open(pdf) as doc:
                    page=doc[0]
                    for i in range(5):page.draw_line((30,166+i*4.25),(350,166+i*4.25),width=.4)
                    for y in range(210,241,6):page.draw_line((30,y),(350,y),width=.4)
                    for x in (30,350):page.draw_line((x,210),(x,240),width=.5)
                    sh=page.new_shape();sh.draw_polyline([(70,155),(90,149),(110,155)])
                    sh.finish(color=(0,0,0),width=.5);sh.commit()
                    if local_mark:page.draw_line((140,139),(145,143),width=.5)
                    doc.saveIncr()
                bar=recognize(pdf)['systems'][0]['bars'][0]
                if local_mark:self.assertTrue(bar['issues'])
                else:
                    self.assertEqual(bar['issues'],[])
                    self.assertTrue(bar['beats'][0]['fullBarRest'])

    def test_hidden_tab_tie_can_join_a_partly_visible_chord(self):
        for mode in ('chord','hidden_chord','single_visible','displaced_arc','visible_same_string','rest_between','note_between','target_rest'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'partial-chord.pdf';fixture(pdf,empty=True)
                with fitz.open(pdf) as doc:
                    page=doc[0]
                    for i,x in enumerate((70,140,210,280)):
                        if mode in ('rest_between','target_rest') and i==1:
                            page.insert_font(fontname='music',fontbuffer=font_buffer())
                            w=fitz.Font(fontbuffer=font_buffer()).text_length('\ue4e5',fontsize=17)
                            page.insert_text((x-w/2,112),'\ue4e5',fontname='music',fontsize=17)
                            # Nearby vertical ink must not turn a rest into a note.
                            if mode=='target_rest':page.draw_line((x,120),(x,150),width=.5)
                            continue
                        tones=[(3,7)] if i==0 else [(1,5),(2,6)] if i==1 else [(3,8)]
                        if mode=='hidden_chord' and i<2:tones=[(3,7),(4,9)] if i==0 else []
                        if mode=='single_visible' and i==1:tones=[(2,5)]
                        if mode in ('rest_between','note_between','target_rest'):
                            tones=[(3,7)] if i==0 else [(1,5),(2,6)]
                        if mode=='visible_same_string' and i==1:tones.append((3,8))
                        for string,fret in tones:
                            token=str(fret);w=fitz.get_text_length(token,fontname='helv',fontsize=7)
                            page.insert_text((x-w/2,100+(string-1)*6+2.4),token,fontname='helv',fontsize=7)
                        page.draw_line((x,120),(x,150),width=.5)
                    target=210 if mode in ('rest_between','note_between') else 140
                    for y in ([112,118] if mode=='hidden_chord' else [116] if mode=='displaced_arc' else [112]):
                        sh=page.new_shape();a,z=74,target-5
                        sh.draw_bezier((a,y),(a+5,y+4),(z-5,y+4),(z,y))
                        sh.draw_bezier((z,y),(z-5,y+3),(a+5,y+3),(a,y))
                        sh.finish(color=None,fill=(0,0,0));sh.commit()
                    doc.saveIncr()
                result=recognize(pdf);bar=result['systems'][0]['bars'][0]
                inferred=[n for v in bar['beats'] for n in v['notes'] if n.get('inferred_from')]
                self.assertEqual(len(inferred),2 if mode=='hidden_chord' else 1 if mode=='chord' else 0)
                if mode in ('chord','hidden_chord'):
                    self.assertEqual((inferred[0]['string'],inferred[0]['fret'],inferred[0]['tie']),(3,7,True))
                    self.assertEqual(len(bar['beats']),4)
                    self.assertEqual(bar['issues'],[])
                    data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
                    run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],capture_output=True,text=True)
                    self.assertEqual(run.returncode,0,run.stderr)

    def test_outlined_half_heads_and_dead_note_beams_roundtrip(self):
        for dead,tones in [(False,1),(True,1),(True,3)]:
            with self.subTest(dead=dead,tones=tones),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'heads.pdf';fixture(pdf,empty=True,meter=False)
                with fitz.open(pdf) as doc:
                    page=doc[0];outlined_meter(page,(2,4) if dead else (4,4))
                    for i in range(5):page.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
                    xs=[70+i*34 for i in range(8)] if dead else [100,230]
                    for x in xs:
                        token='X' if dead else '7';w=fitz.get_text_length(token,fontname='helv',fontsize=7)
                        for tone in range(tones):
                            page.insert_text((x-w/2,114.4+tone*6),token,fontname='helv',fontsize=7)
                            outlined_music(page,[(0xe0a9 if dead else 0xe0a3,x-2.5,58.5+tone*4.25,17)])
                        page.draw_line((x-2.25,59),(x-2.25,80),width=.5)
                    if dead:
                        for y in (76,79):
                            sh=page.new_shape();a,z=xs[0]-2.25,xs[-1]-2.25
                            sh.draw_polyline([(a,y),(z,y),(z,y+1),(a,y+1),(a,y)])
                            sh.finish(color=None,fill=(0,0,0));sh.commit()
                    doc.saveIncr()
                result=recognize(pdf);bar=result['systems'][0]['bars'][0]
                self.assertEqual([b['duration'] for b in bar['beats']],[16]*8 if dead else [2,2])
                self.assertEqual(bar['issues'],[])
                data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)

    def test_cross_head_without_stem_or_matching_tab_dead_note_stays_unknown(self):
        for stem,token in [(False,'X'),(True,'7')]:
            with self.subTest(stem=stem,token=token),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'cross.pdf';fixture(pdf,empty=True,meter=False)
                with fitz.open(pdf) as doc:
                    page=doc[0];outlined_meter(page,(4,4))
                    for i in range(5):page.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
                    page.insert_text((98,114.4),token,fontname='helv',fontsize=7)
                    outlined_music(page,[(0xe0a9,97.5,58.5,17)])
                    if stem:page.draw_line((97.75,59),(97.75,80),width=.5)
                    doc.saveIncr()
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertIsNone(bar['beats'][0]['duration'])
                self.assertTrue(bar['issues'])

    def test_short_beam_touching_stem_is_not_a_rest(self):
        for edge in ('left','right'):
            with self.subTest(edge=edge),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'beam.pdf';fixture(pdf,empty=True,meter=False)
                with fitz.open(pdf) as doc:
                    page=doc[0];outlined_meter(page,(4,4))
                    for i in range(5):page.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
                    page.draw_rect(fitz.Rect(120,54.25,123.74,56.38),color=None,fill=(0,0,0))
                    x=119.75 if edge=='left' else 123.99
                    page.draw_line((x,44),(x,59.3),width=.5)
                    doc.saveIncr()
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertEqual(bar['beats'],[])
                self.assertTrue(bar['issues'])

    def test_outlined_whole_and_half_rests_use_staff_position(self):
        cases=[(kind,meter,standard) for kind,meter in [('whole',(4,4)),('whole',(3,4)),('half',(4,4))]
               for standard in (False,True)]
        for kind,meter,standard in cases:
            with self.subTest(kind=kind,meter=meter,standard=standard),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'rests.pdf';fixture(pdf,empty=True,meter=False)
                with fitz.open(pdf) as doc:
                    page=doc[0];outlined_meter(page,meter)
                    if standard:
                        for i in range(5):page.draw_line((30,50+i*4.25),(350,50+i*4.25),width=.4)
                    for x in ([120] if kind=='whole' else [120,250]):
                        y=(54.25 if kind=='whole' else 56.1) if standard else (106 if kind=='whole' else 109.6)
                        page.draw_rect(fitz.Rect(x,y,x+4.8,y+2.4),color=None,fill=(0,0,0))
                    doc.saveIncr()
                result=recognize(pdf);bar=result['systems'][0]['bars'][0]
                self.assertEqual(bar['issues'],[])
                self.assertEqual([b['duration'] for b in bar['beats']],[1] if kind=='whole' else [2,2])
                self.assertEqual(bar['meter'],list(meter))
                data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
                run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],capture_output=True,text=True)
                self.assertEqual(run.returncode,0,run.stderr)

    def test_ambiguous_rest_position_or_missing_meter_stays_blocked(self):
        for y,meter in [(115,(4,4)),(148,(4,4)),(106,None)]:
            with self.subTest(y=y,meter=meter),tempfile.TemporaryDirectory() as folder:
                pdf=Path(folder)/'ambiguous.pdf';fixture(pdf,empty=True,meter=False)
                with fitz.open(pdf) as doc:
                    if meter:outlined_meter(doc[0],meter)
                    doc[0].draw_rect(fitz.Rect(120,y,124.8,y+2.4),color=None,fill=(0,0,0));doc.saveIncr()
                bar=recognize(pdf)['systems'][0]['bars'][0]
                self.assertTrue(bar['issues'])
                if meter:self.assertEqual(bar['beats'],[])

    def test_detached_half_stem_is_not_a_quarter(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'halves.pdf';fixture(pdf,empty=True)
            with fitz.open(pdf) as doc:
                page=doc[0]
                for x,length in [(100,6),(200,10.5),(280,10.5)]:
                    token='(7)';w=fitz.get_text_length(token,fontname='helv',fontsize=7)
                    page.insert_text((x-w/2,114.4),token,fontname='helv',fontsize=7)
                    page.draw_line((x,145-length),(x,145),width=.4)
                doc.saveIncr()
            result=recognize(pdf);bar=result['systems'][0]['bars'][0]
            self.assertEqual([b['duration'] for b in bar['beats']],[2,4,4])
            self.assertEqual(bar['issues'],[])
            data=Path(folder)/'recognized.json';data.write_text(json.dumps(result),encoding='utf-8')
            run=subprocess.run(['node',str(HERE/'gp-export.cjs'),str(data),str(Path(folder)/'out.gp')],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)

    def test_short_line_at_other_height_is_not_a_half_stem(self):
        with tempfile.TemporaryDirectory() as folder:
            pdf=Path(folder)/'short-line.pdf';fixture(pdf,empty=True)
            with fitz.open(pdf) as doc:
                page=doc[0];page.insert_text((97,114.4),'(7)',fontname='helv',fontsize=7)
                page.draw_line((100,132),(100,138),width=.4);doc.saveIncr()
            bar=recognize(pdf)['systems'][0]['bars'][0]
            self.assertNotEqual(bar['beats'][0]['duration'],2)
            self.assertTrue(bar['issues'])

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
