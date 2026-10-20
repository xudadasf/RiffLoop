"""EXPERIMENT: vector PDF tablature recognition. Never reads a reference GP."""
import argparse
import collections
import json
import re
from pathlib import Path

import fitz
from symbols import outline_spans

ORNAMENTS={'\ue567':'turn','\ue568':'inverted-turn','\ue56c':'upper-mordent','\ue56d':'lower-mordent'}


def lines_and_shapes(page):
    lines, shapes = [], []
    for drawing in page.get_drawings():
        if drawing.get('fill') == (1, 1, 1):
            continue
        shapes.append(drawing)
        for item in drawing['items']:
            if item[0] == 'l':
                lines.append((*item[1], *item[2]))
            elif item[0] == 're':
                x0, y0, x1, y1 = item[1]
                if x1 - x0 < 1.5:
                    lines.append(((x0+x1)/2, y0, (x0+x1)/2, y1))
                elif y1 - y0 < 0.8:
                    lines.append((x0, (y0+y1)/2, x1, (y0+y1)/2))
    return lines, shapes


def staves(lines, width):
    horizontal = collections.defaultdict(list)
    for x0, y0, x1, y1 in lines:
        if abs(y1-y0) < .1 and abs(x1-x0) > 8:
            horizontal[round(y0, 1)].append((min(x0,x1), max(x0,x1)))
    rows = sorted(y for y, intervals in horizontal.items()
                  if sum(b-a for a,b in intervals) > 70)
    groups, i = [], 0
    while i < len(rows):
        candidates = []
        for count in (6, 5):
            ys = rows[i:i+count]
            if len(ys) != count:
                continue
            gaps = [b-a for a,b in zip(ys,ys[1:])]
            if 3 < min(gaps) < 15 and max(gaps)-min(gaps) < .3:
                candidates.append(ys)
        if candidates:
            ys = candidates[0]
            intervals = [v for y in ys for v in horizontal[y]]
            groups.append({'ys':ys,'left':min(a for a,b in intervals),
                           'right':max(b for a,b in intervals),'count':len(ys)})
            i += len(ys)
        else:
            i += 1
    # Sparse ledger lines can interrupt the five-line sequence. Recover only
    # standard staves here: TAB lines themselves may have large digit cutouts.
    dense=[y for y in rows if any(g['count']==6 and 0<g['ys'][0]-y<90
           and sum(b-a for a,b in horizontal[y])>(g['right']-g['left'])*.65 for g in groups)]
    for i in range(len(dense)-4):
        ys=dense[i:i+5]; gaps=[b-a for a,b in zip(ys,ys[1:])]
        if not (3<min(gaps)<15 and max(gaps)-min(gaps)<.3): continue
        if any(g['ys'][0]-.2<=ys[-1] and ys[0]<=g['ys'][-1]+.2 for g in groups): continue
        if not any(g['count']==6 and 0<g['ys'][0]-ys[-1]<90 for g in groups): continue
        intervals=[v for y in ys for v in horizontal[y]]
        groups.append({'ys':ys,'left':min(a for a,b in intervals),
                       'right':max(b for a,b in intervals),'count':5})
    return sorted(groups,key=lambda g:g['ys'][0])


def clusters(values, tolerance=1):
    groups = []
    for value in sorted(values):
        if groups and value-groups[-1][-1] < tolerance:
            groups[-1].append(value)
        else:
            groups.append([value])
    return [sum(group)/len(group) for group in groups]


def text_spans(page):
    # Layout text extraction merges tightly spaced separate frets (14,15,14)
    # into "141514". Drawing operations retain their original glyph boundaries.
    spans=[]
    for s in page.get_texttrace():
        if not s['chars'] or s['opacity']<=0 or s['dir'][0]<=.9:continue
        token=''.join(chr(c[0]) for c in s['chars'])
        span={'text':token,'origin':s['chars'][0][2],'bbox':s['bbox'],'font':s['font'],'size':s['size']}
        if re.fullmatch(r'\(\d{1,2}\)',token):
            span['fret_width']=s['chars'][-2][3][2]-s['chars'][1][3][0]
        spans.append(span)
    return spans


def font_resources(page):
    """Names alone cannot identify a font shared by two PDF pages."""
    resources=collections.defaultdict(set)
    for xref,extension,kind,name,*rest in page.get_fonts():
        resources[re.sub(r'^[A-Z]{6}\+','',name)].add(xref)
    return {name:next(iter(ids)) for name,ids in resources.items() if len(ids)==1 and 0 not in ids}


def document_tie_padding(document):
    """Measure printed TAB parentheses, retaining font identity and staff scale."""
    samples=[]
    for pi,page in enumerate(document):
        spans=[s for s in text_spans(page) if s.get('fret_width') is not None]
        if not spans:continue
        fonts=font_resources(page);lines,shapes=lines_and_shapes(page)
        staffs=[s for s in staves(lines,page.rect.width) if s['count']==6]
        for span in spans:
            font=fonts.get(span['font'])
            if font is None:continue
            x0,y0,x1,y1=span['bbox'];x=(x0+x1)/2;y=(y0+y1)/2
            matches=[s for s in staffs if s['left']<x<s['right']
                     and min(abs(yy-y) for yy in s['ys'])<(s['ys'][-1]-s['ys'][0])/5*.36]
            if len(matches)!=1:continue
            gap=(matches[0]['ys'][-1]-matches[0]['ys'][0])/5;ends=[]
            for sh in shapes:
                if sh['type']!='f' or len(sh['items'])!=2 or not all(i[0]=='c' for i in sh['items']):continue
                if sh['rect'].width<=4 or sh['rect'].height>=gap*2:continue
                a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
                if 0<x0-z.x<2 and abs(z.y-y)<gap*.5 and abs(a.y-z.y)<gap*.25:
                    ends.append(x-z.x-span['fret_width']/2)
            if len(ends)==1:
                samples.append({'font':font,'size':span['size'],'gap':gap,'page':pi+1,
                                'x':x,'y':y,'padding':ends[0]})
    return samples


def recognize(pdf):
    document = fitz.open(pdf)
    padding_samples=document_tie_padding(document)
    result = {'input':str(Path(pdf).resolve()), 'format':'vector-pdf-experiment-v1',
              'tempo':None,'tuning':None,'pages':len(document),'systems':[],'slide_marks':[],'staccato_marks':[],'palm_mute_marks':[],'ornament_marks':[],'tremolo_marks':[],
              'warnings':['演奏技巧、延音、反复结构和速度变化尚未完整识别，所有导出均为实验稿。',
                          '初始 BPM 暂按四分音符计拍，须人工核对速度标记。']}
    previous_meter = [4, 4]
    meter_source = 'assumed-4/4'
    previous_number = 0
    previous_shapes = []
    previous_lines = []
    tempo_marks=[]
    for pi, page in enumerate(document):
        lines, shapes = lines_and_shapes(page)
        spans = text_spans(page)
        outlined=outline_spans(shapes)
        if not any('bravura' in s['font'].lower() for s in spans):
            spans += outlined
        else:
            # Some PDFs keep rests as font text but print ornaments as paths.
            spans += [s for s in outlined if s['text'] in ORNAMENTS or s['text'] in ('\ue222','\ue06d')]
        # Tempo symbols can be paths even when the staff uses font text.
        # Include outlined dots here to reject dotted units, without changing
        # the staff's rhythm-dot reader on mixed text/path pages.
        tempo_spans=spans+[s for s in outlined if s['text'] in ('\ue1d5','\ue1e7') and s not in spans]
        for span in spans:
            if not re.search(r'=\s*\d',span['text']):continue
            match=re.search(r'=\s*(\d{2,3})\s*$',span['text'])
            units=[s for s in tempo_spans if 'bravura' in s['font'].lower()
                   and 0<=span['bbox'][0]-s['bbox'][2]<12 and abs(s['origin'][1]-span['origin'][1])<3]
            unit='quarter' if len(units)==1 and units[0]['text']=='\ue1d5' else 'unsupported' if units else None
            tempo_marks.append({'page':pi+1,'x':units[0]['origin'][0] if unit=='quarter' else span['bbox'][0],
                                'y':span['origin'][1],'bpm':int(match[1]) if match else None,'unit':unit})
        text = page.get_text()
        if 'Standard tuning' in text:
            result['tuning'] = [64,59,55,50,45,40]
        if result['tempo'] is None:
            tempo = re.search(r'=\s*(\d{2,3})', text)
            if tempo:
                result['tempo'] = int(tempo[1])
        groups = staves(lines, page.rect.width)
        if groups:
            last=groups[-1];space=last['ys'][1]-last['ys'][0]
            # A page fraction is layout text only when its value and placement agree.
            footers=[s for s in spans if s['text'].strip()==f'{pi+1}/{len(document)}'
                     and 'bravura' not in s['font'].lower() and s['size']<=9
                     and s['origin'][1]>page.rect.y1-page.rect.height*.05
                     and s['bbox'][1]>last['ys'][-1]+space
                     and abs(s['bbox'][2]-last['right'])<space*.5]
            if len(footers)==1:footers[0]['page_footer']=True
        for gi, staff in enumerate(groups):
            if staff['count'] != 6:
                continue
            ys = staff['ys']; gap = (ys[-1]-ys[0])/5
            # Keep the next system's high notes and bends out of this system's
            # otherwise empty rhythm area.
            staff['notation_bottom']=min(ys[-1]+gap*5,
                (ys[-1]+groups[gi+1]['ys'][0])/2 if gi+1<len(groups) else page.rect.height)
            standard = groups[gi-1] if gi and groups[gi-1]['count'] == 5 and ys[0]-groups[gi-1]['ys'][-1] < 90 else None
            system = {'page':pi+1,'ys':ys,'left':staff['left'],'right':staff['right'],
                      'standard':standard,'bars':[]}
            vertical = [min(x0,x1) for x0,y0,x1,y1 in lines
                        if abs(x1-x0)<1 and min(y0,y1)<ys[0]+.8 and max(y0,y1)>ys[-1]-.8]
            boundaries = clusters([staff['left'], staff['right']]+vertical,1.8)
            boundaries = [x for x in boundaries if staff['left']-1<=x<=staff['right']+1]
            # Printable digits centered on a string line; serif bar numbers stay outside.
            notes=[]
            for span in spans:
                token=span['text'].strip()
                harmonic=re.fullmatch(r'<\d{1,2}>|\(<\d{1,2}>\)',token)
                if not harmonic and not re.fullmatch(r'\(?\d{1,2}\)?|[xX]',token):
                    continue
                if not any(font in span['font'].lower() for font in ('arial','helvetica')):
                    continue
                x0,y0,x1,y1=span['bbox']; x=(x0+x1)/2; y=(y0+y1)/2
                si=min(range(6),key=lambda i:abs(ys[i]-y))
                if abs(ys[si]-y)>gap*.36 or not staff['left']+5<x<staff['right']+1:
                    continue
                notes.append({'x':x,'y':ys[si],'string':si+1,
                              'fret':None if token.upper()=='X' else int(token.strip('()<>')),
                              'dead':token.upper()=='X','parenthesized':token.startswith('('),
                              'tie':False,
                              'size':span['size'],'bbox':list(span['bbox']),
                              **({'harmonic':'natural'} if harmonic else {})})
            # Small <...> labels beside ordinary frets are artificial-harmonic
            # annotations, not independent natural-harmonic notes or grace notes.
            ordinary=[n for n in notes if not n.get('harmonic')]
            normal_size = collections.Counter(round(n['size'],1) for n in (ordinary or notes)).most_common(1)
            normal_size = normal_size[0][0] if normal_size else 7
            notes=[n for n in notes if not n.get('harmonic') or n['size']>=normal_size*.82]
            number_y=(standard['ys'][0] if standard else ys[0])-2
            numbers=[(s['bbox'][0],int(s['text'])) for s in spans
                     if s['text'].isdigit() and 'times' in s['font'].lower()
                     and abs(s['origin'][1]-number_y)<4 and s['size']<8]
            for bi,(left,right) in enumerate(zip(boundaries,boundaries[1:])):
                if right-left<12:
                    continue
                number_candidates=[(abs(x-left),n) for x,n in numbers if left-4<x<left+38]
                number=min(number_candidates)[1] if number_candidates else previous_number+1
                previous_number=number
                meter_symbols=[s for s in spans if left<s['bbox'][0]<left+50
                               and (standard['ys'][0]-10 if standard else ys[0]-10)<s['bbox'][1]<ys[-1]
                               and any('\ue080'<=c<='\ue089' for c in s['text'])]
                if len(meter_symbols)>=2:
                    digits=[]
                    for s in sorted(meter_symbols,key=lambda s:s['origin'][1]):
                        digits.append(''.join(str(ord(c)-0xe080) for c in s['text'] if '\ue080'<=c<='\ue089'))
                    previous_meter=[int(digits[0]),int(digits[1])]
                    meter_source='pdf'
                common=[s for s in spans if left<s['bbox'][0]<left+50 and s['size']>=12
                        and (standard['ys'][0]-10 if standard else ys[0]-10)<s['origin'][1]<ys[-1]
                        and s['text'] in ('\ue08a','\ue08b')]
                if common:
                    previous_meter=[4,4] if common[0]['text']=='\ue08a' else [2,2]
                    meter_source='pdf'
                bar={'number':number,'left':left,'right':right,'meter':previous_meter[:],
                     'meter_source':meter_source,'beats':[], 'issues':[]}
                bar_notes=[n for n in notes if left<=n['x']<right]
                for x in clusters([n['x'] for n in bar_notes],1.6):
                    chord=sorted([n for n in bar_notes if abs(n['x']-x)<1.6],key=lambda n:n['string'])
                    grace=all(n['size']<normal_size*.82 for n in chord)
                    beat={'x':x,'notes':chord,'grace':grace,'duration':None,'dots':0,'tuplet':[1,1]}
                    read_rhythm(beat,staff,standard,spans,lines,shapes,left,right)
                    bar['beats'].append(beat)
                add_rests(bar,staff,standard,spans,lines,shapes)
                bar['beats'].sort(key=lambda b:b['x'])
                system['bars'].append(bar)
            read_hidden_standard_ties(system,spans,lines,shapes,result['tuning'])
            read_ties(system,spans,lines,shapes,padding_samples,font_resources(page))
            if result['systems']:
                read_boundary_ties(result['systems'][-1],system,previous_shapes,shapes)
            read_mixed_half_chords(system,lines,shapes)
            previous_bar=result['systems'][-1]['bars'][-1] if result['systems'] else None
            for bar in system['bars']:
                # New hidden tie destinations must participate in tuplet grouping.
                for beat in bar['beats']:
                    beat['notes'].sort(key=lambda n:n['string'])
                    beat['tuplet']=[1,1]
                read_tuplets(bar,staff,standard,spans,lines)
                read_stemless_whole_tie(bar,previous_bar,staff,standard,spans,shapes)
                validate_bar(bar)
                previous_bar=bar
            outline_upper=ys[0]-30
            if gi:
                prev=groups[gi-1]['ys']
                outline_upper=max(outline_upper,prev[-1]+5*(prev[1]-prev[0]))
            result['staccato_marks'].extend(read_staccatos(system,spans,staff['notation_bottom'],outlined,shapes,outline_upper))
            result['palm_mute_marks'].extend(read_palm_mutes(system,spans,lines,shapes))
            result['ornament_marks'].extend(read_ornaments(system,spans))
            result['tremolo_marks'].extend(read_tremolos(system,spans,lines))
            result['slide_marks'].extend(read_slides(system,spans,lines,shapes))
            if result['systems']:
                read_boundary_slides(result['systems'][-1],system,previous_lines,previous_shapes,shapes,result['slide_marks'])
            result['systems'].append(system)
            previous_shapes = shapes
            previous_lines = lines
    read_tempos(result,tempo_marks)
    if any(m['status']=='unsupported' for m in result['tremolo_marks']):
        result['warnings'].append('部分重复拨弦标记的节拍或符干未确认，尚未还原；详见 tremolo_marks。')
    if any(m['status']=='unsupported' for m in result['slide_marks']):
        result['warnings'].append('部分 sl. 滑音标记的连线或音符对应关系未确认，尚未还原；详见 slide_marks。')
    if any(m['status']=='unsupported' for m in result['staccato_marks']):
        result['warnings'].append('部分顿音标记无法确定对应音符，尚未还原；详见 staccato_marks。')
    if any(m['status']!='recognized' for m in result['palm_mute_marks']):
        result['warnings'].append('部分 P.M. 标记的范围或逐弦归属未确认，尚未完整还原；详见 palm_mute_marks。')
    if any(m['status']!='recognized' for m in result['ornament_marks']):
        result['warnings'].append('部分装饰音符号的音符归属未确认，尚未还原；详见 ornament_marks。')
    if not result['systems']:
        result['warnings'].append('未找到可提取的六线谱；当前不支持扫描图片或四弦贝斯谱。')
    numbers=[b['number'] for s in result['systems'] for b in s['bars']]
    result['structure_issues']=[]
    if len(numbers)!=len(set(numbers)): result['structure_issues'].append('重复小节号或多分谱')
    if numbers and numbers!=list(range(1,len(numbers)+1)):
        result['structure_issues'].append('小节号缺失、顺序异常或谱子为节选；禁止作为完整曲目导出')
    if not result['tuning']:
        result['warnings'].append('未确认标准定弦，导出前须人工确认定弦。')
    if not result['tempo']:
        result['warnings'].append('未识别 BPM，导出前须人工确认。')
    if any(b['meter_source']=='assumed-4/4' for s in result['systems'] for b in s['bars']):
        result['warnings'].append('部分小节未识别到拍号，4/4 仅用于诊断，这些小节禁止导出。')
    document.close()
    return result


def read_palm_mutes(system,spans,lines,shapes):
    """Explicit P.M. labels and capped dashed ranges; never infer chord-note scope."""
    top=system['ys'][0];gap=(system['ys'][-1]-top)/5
    labels=[s for s in spans if s['text'].strip()=='P.M.' and top-35<s['origin'][1]<top-2
            and system['left']<s['origin'][0]<system['right']]
    beats=[(b,v) for b in system['bars'] for v in b['beats']];marks=[]
    for label in labels:
        x=(label['bbox'][0]+label['bbox'][2])/2;y=label['origin'][1]
        mark={'page':system['page'],'x':x,'y':y,'status':'unsupported','reason':'ambiguous-range'}
        marks.append(mark)
        starts=[i for i,(b,v) in enumerate(beats) if abs(v['x']-x)<1.5]
        if len(starts)!=1:continue
        start=starts[0];end=start
        candidates=[]
        for sh in shapes:
            if sh['type']!='s' or len(sh['items'])!=1 or sh['items'][0][0]!='l':continue
            a,z=sorted(sh['items'][0][1:],key=lambda p:p.x)
            if (abs(a.y-z.y)<.1 and z.x-a.x>gap and 0<a.x-label['bbox'][2]<4
                    and 0<y-a.y<gap):candidates.append((sh,a,z))
        if candidates:
            if len(candidates)!=1:continue
            sh,a,z=candidates[0]
            if not re.match(r'\[\s*\d',sh['dashes']):continue
            caps=[(min(y0,y1),max(y0,y1)) for x0,y0,x1,y1 in lines
                  if abs(x0-z.x)<.3 and abs(x1-z.x)<.3 and 0<abs(y1-y0)<gap
                  and min(y0,y1)-.1<=z.y<=max(y0,y1)+.1]
            if not caps or min(c[0] for c in caps)>z.y-gap*.15 or max(c[1] for c in caps)<z.y+gap*.15:continue
            ends=[i for i,(b,v) in enumerate(beats)
                  if v['x']-.5<z.x<max([v['x']]+[n['bbox'][2] for n in v['notes']])+1.5]
            if len(ends)!=1 or ends[0]<=start:continue
            end=ends[0]
        selected=beats[start:end+1]
        mark.update(bar=selected[0][0]['number'],end_bar=selected[-1][0]['number'],end_x=selected[-1][1]['x'])
        blocked=[];recognized=0
        for bar,beat in selected:
            if not beat['notes']:continue
            reason='chord-note-scope' if len(beat['notes'])>1 else 'unsupported-note'
            if len(beat['notes'])!=1 or beat['grace'] or beat['notes'][0]['tie'] or beat['notes'][0]['dead']:
                blocked.append({'bar':bar['number'],'x':beat['x'],'reason':reason});continue
            beat['notes'][0]['palm_mute']=True;recognized+=1
        if recognized:
            mark.update(status='partial' if blocked else 'recognized',recognized_notes=recognized)
            mark.pop('reason')
        if blocked:
            mark['blocked_beats']=blocked
            if not recognized:mark['reason']=blocked[0]['reason']
    return marks


def read_ornaments(system,spans):
    """Read explicit turn/mordent glyphs over a unique, ordinary single note."""
    top=(system['standard'] or system)['ys'][0]
    symbols=[s for s in spans if s['text'] in ORNAMENTS and 'bravura' in s['font'].lower()
             and top-25<s['origin'][1]<top-1 and system['left']<s['origin'][0]<system['right']]
    center=lambda s:(s['bbox'][0]+s['bbox'][2])/2
    marks=[]
    for symbol in symbols:
        x=center(symbol);name=ORNAMENTS[symbol['text']]
        mark={'page':system['page'],'x':x,'y':symbol['origin'][1],'ornament':name,
              'status':'unsupported','reason':'ambiguous-beat'}
        matches=[(b,v) for b in system['bars'] for v in b['beats'] if abs(v['x']-x)<1.5]
        if len(matches)==1:
            bar,beat=matches[0];mark['bar']=bar['number']
            if len(beat['notes'])>1:mark['reason']='chord-note-scope'
            elif len(beat['notes'])!=1 or beat['grace'] or beat['notes'][0]['tie'] or beat['notes'][0]['dead']:
                mark['reason']='unsupported-note'
            elif sum(abs(center(s)-beat['x'])<1.5 for s in symbols)!=1:mark['reason']='duplicate-mark'
            else:
                beat['notes'][0]['ornament']=name
                mark.update(status='recognized',string=beat['notes'][0]['string']);mark.pop('reason')
        marks.append(mark)
    return marks


def read_staccatos(system,spans,bottom,outlined=(),shapes=(),outline_upper=None):
    """Resolve explicit glyphs and isolated outline dots above TAB single notes."""
    standard=system['standard'];top=system['ys'][0]
    upper=(standard['ys'][0]-35) if standard else top-30
    lower=top-2 if standard else bottom
    symbols=[s for s in spans if s['text'] in ('\ue4a2','\ue4a3') and 'bravura' in s['font'].lower()
             and upper<s['origin'][1]<lower and system['left']<s['origin'][0]<system['right']
             and (standard or s['text']=='\ue4a2' and s['origin'][1]<top
                  or s['text']=='\ue4a3' and s['origin'][1]>system['ys'][-1])]
    if not standard:
        gap=(system['ys'][-1]-top)/5
        for s in outlined:
            if s['text']!='\ue1e7' or s.get('source')!='font-outline':continue
            if not max(upper,outline_upper if outline_upper is not None else upper)<s['origin'][1]<top-2:continue
            if not system['left']<s['origin'][0]<system['right']:continue
            box=fitz.Rect(s['bbox'])
            if not all(gap*.12<v<gap*.35 for v in (box.width,box.height)):continue
            # Punctuation and dots next to other outlines cannot establish articulation.
            nearby=fitz.Rect(box.x0-gap,box.y0-.2,box.x1+gap,box.y1+.2)
            if any('bravura' not in t['font'].lower() and nearby.intersects(fitz.Rect(t['bbox'])) for t in spans):continue
            if any(sh['type']=='f' and sh['rect']!=box and nearby.intersects(sh['rect']) for sh in shapes):continue
            symbols.append(s)
    center=lambda s:(s['bbox'][0]+s['bbox'][2])/2
    marks=[]
    for symbol in symbols:
        x=center(symbol);mark={'page':system['page'],'x':x,'y':symbol['origin'][1],
                              'status':'unsupported','reason':'ambiguous-beat'}
        matches=[(b,v) for b in system['bars'] for v in b['beats'] if abs(v['x']-x)<1.5]
        if len(matches)==1:
            bar,beat=matches[0];mark['bar']=bar['number']
            if len(beat['notes'])>1:mark['reason']='chord-note-scope'
            elif len(beat['notes'])!=1 or beat['grace'] or beat['notes'][0]['tie'] or beat['notes'][0]['dead']:
                mark['reason']='unsupported-note'
            elif sum(abs(center(s)-beat['x'])<1.5 for s in symbols)!=1:mark['reason']='duplicate-mark'
            else:
                beat['notes'][0]['staccato']=True
                mark.update(status='recognized',string=beat['notes'][0]['string'])
                mark.pop('reason')
        marks.append(mark)
    return marks


def read_boundary_slides(previous,current,lines,previous_shapes,current_shapes,marks):
    """Match an outgoing slide and paired TAB slur continuations at a row break."""
    if not previous['bars'] or not current['bars']:return
    sb,tb=previous['bars'][-1],current['bars'][0]
    if sb['number']+1!=tb['number'] or sb['issues'] or tb['issues']:return
    if not sb['beats'] or not tb['beats']:return
    sv,tv=sb['beats'][-1],tb['beats'][0]
    if sv['grace'] or tv['grace']:return
    source=sorted(sv['notes'],key=lambda n:n['string']);target=sorted(tv['notes'],key=lambda n:n['string'])
    if not source or [n['string'] for n in source]!=[n['string'] for n in target]:return
    if any(n['dead'] for n in source+target) or any(n['tie'] for n in target):return
    shifts={tn['fret']-sn['fret'] for sn,tn in zip(source,target)}
    if len(shifts)!=1 or 0 in shifts:return
    gap=(previous['ys'][-1]-previous['ys'][0])/5
    labels=[m for m in marks if m['page']==previous['page'] and m['status']=='unsupported'
            and sv['x']-3<m['x']<previous['right'] and previous['ys'][0]-25<m['y']<previous['ys'][-1]+2]
    if len(source)==1 and len(labels)!=1:return
    for sn,tn in zip(source,target):
        strokes=0
        for x0,y0,x1,y1 in lines:
            if x0>x1:x0,y0,x1,y1=x1,y1,x0,y0
            if (x1-x0>gap*.3 and 0<x0-sn['bbox'][2]<4 and abs(x1-previous['right'])<gap*.5
                    and abs(y0-sn['y'])<gap*.6 and abs(y1-sn['y'])<gap*.15
                    and gap*.15<abs(y1-y0)<gap*.8 and (y0-y1)*(tn['fret']-sn['fret'])>0):strokes+=1
        if strokes!=1:return

    def boundary_sides(system,shapes,beat,notes,outgoing):
        gap=(system['ys'][-1]-system['ys'][0])/5;sides=[]
        for sh in shapes:
            if sh['type']!='f' or len(sh['items'])!=2 or sh['rect'].height>=gap*2:continue
            if not all(i[0]=='c' for i in sh['items']):continue
            a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
            if outgoing:
                if abs(a.x-beat['x'])>=1 or abs(z.x-system['right'])>=gap*.5:continue
            elif abs(z.x-beat['x'])>=1 or not system['left']<a.x<z.x or not gap*.5<z.x-a.x<gap*2:continue
            if abs(a.y-z.y)>=gap*.25:continue
            if 0<notes[0]['y']-a.y<gap*.8:sides.append('above')
            elif 0<a.y-notes[-1]['y']<gap*.8:sides.append('below')
        return sides

    outgoing=boundary_sides(previous,previous_shapes,sv,source,True)
    incoming=boundary_sides(current,current_shapes,tv,target,False)
    if not outgoing or sorted(outgoing)!=sorted(incoming) or len(outgoing)!=len(set(outgoing)):return
    for sn,tn in zip(source,target):
        sn.update(legato_slide=True,slide_target_bar=tb['number'],slide_target_fret=tn['fret'])
        tn['slide_source_bar']=sb['number']
    for m in labels:m.update(status='recognized',kind='system-boundary',bar=sb['number'],target_bar=tb['number'])
    if not labels:
        marks.append({'page':previous['page'],'x':sv['x'],'y':source[-1]['y'],
                      'status':'recognized','kind':'system-boundary','bar':sb['number'],'target_bar':tb['number']})


def slide_line_count(sn,tn,lines,gap,minimum_width=4):
    count=0
    for x0,y0,x1,y1 in lines:
        if x0>x1:x0,y0,x1,y1=x1,y1,x0,y0
        if minimum_width<4 and not sn['bbox'][2]-.3<x0<x1<tn['bbox'][0]+.3:continue
        if (x1-x0>minimum_width and abs(x0-sn['bbox'][2])<4 and abs(x1-tn['bbox'][0])<4
                and abs(y0-sn['y'])<gap*.6 and abs(y1-tn['y'])<gap*.6
                and gap*.15<abs(y1-y0)<gap*.8 and (y0-y1)*(tn['fret']-sn['fret'])>0):count+=1
    return count


def read_chord_slides(system,beats,lines,arcs,gap):
    """Parallel chords need per-string lines and unique upper/lower slurs."""
    marks=[]
    for (sb,sv),(tb,tv) in zip(beats,beats[1:]):
        if sv['grace'] or tv['grace'] or tb['number'] not in (sb['number'],sb['number']+1):continue
        source=sorted(sv['notes'],key=lambda n:n['string']);target=sorted(tv['notes'],key=lambda n:n['string'])
        if len(source)<2 or [n['string'] for n in source]!=[n['string'] for n in target]:continue
        if any(n['dead'] for n in source+target) or any(n['tie'] for n in target):continue
        pairs=list(zip(source,target));shifts={tn['fret']-sn['fret'] for sn,tn in pairs}
        if len(shifts)!=1 or 0 in shifts:continue
        if any(slide_line_count(sn,tn,lines,gap,minimum_width=gap*.3)!=1 for sn,tn in pairs):continue
        curves=[];sides=[]
        for sh in arcs:
            a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
            if abs(a.x-sv['x'])>=1 or abs(z.x-tv['x'])>=1:continue
            above=0<source[0]['y']-a.y<gap*.8 and 0<target[0]['y']-z.y<gap*.8
            below=0<a.y-source[-1]['y']<gap*.8 and 0<z.y-target[-1]['y']<gap*.8
            if (above or below) and abs(a.y-z.y)<gap*.25:
                curves.append(sh);sides.append('above' if above else 'below')
        if not curves or len(sides)!=len(set(sides)):continue
        for sn,tn in pairs:
            sn.update(legato_slide=True,slide_target_bar=tb['number'],slide_target_fret=tn['fret'])
            tn['slide_source_bar']=sb['number']
        marks.append({'page':system['page'],'x':(sv['x']+tv['x'])/2,'y':curves[0]['rect'].y0,
                      'status':'recognized','kind':'parallel-chord','bar':sb['number'],'target_bar':tb['number'],
                      'strings':[n['string'] for n in source],'start_x':sv['x'],'end_x':tv['x']})
    return marks


def shared_legato_curve(a,z,sn,tn,beats,spans,lines,gap,top,curve_top):
    """Every edge of a shared same-string slur must have its own H/P/sl. evidence."""
    starts=[i for i,(b,v) in enumerate(beats) if abs(v['x']-a.x)<1]
    ends=[i for i,(b,v) in enumerate(beats) if abs(v['x']-z.x)<1]
    if len(starts)!=1 or len(ends)!=1 or ends[0]-starts[0]<2:return False
    chain=beats[starts[0]:ends[0]+1]
    if any(v['grace'] or len(v['notes'])!=1 for b,v in chain):return False
    notes=[v['notes'][0] for b,v in chain]
    if any(n['dead'] or n['string']!=sn['string'] for n in notes):return False
    if not any(s is sn and t is tn for s,t in zip(notes,notes[1:])):return False
    for (sb,sv),(tb,tv) in zip(chain,chain[1:]):
        s,t=sv['notes'][0],tv['notes'][0]
        if t['tie'] or tb['number'] not in (sb['number'],sb['number']+1):return False
        labels=[m['text'].strip().lower() for m in spans if m['text'].strip().lower() in ('h','p','sl.')
                and s['x']<(m['bbox'][0]+m['bbox'][2])/2<t['x']
                and (top-25<m['origin'][1]<top+2 or abs(m['origin'][1]-curve_top)<gap*.5)]
        if len(labels)!=1:return False
        count=slide_line_count(s,t,lines,gap,minimum_width=gap*.15)
        if labels[0]=='sl.':
            if not single_slide_evidence(s,t,lines,gap):return False
        elif count or (t['fret']-s['fret'])*(1 if labels[0]=='h' else -1)<=0:return False
    return True


def single_slide_evidence(sn,tn,lines,gap):
    """Called only with a confirmed sl. label and slur; narrow cutouts can hide the line."""
    if slide_line_count(sn,tn,lines,gap,minimum_width=gap*.15)==1:return True
    left,right=sn['bbox'][2],tn['bbox'][0]
    if not 0<right-left<gap*.6:return False
    # A visible conflicting diagonal is never treated as a missing line.
    return not any(sn['x']<min(x0,x1)<max(x0,x1)<tn['x']
                   and abs(y0-sn['y'])<gap and abs(y1-tn['y'])<gap
                   and abs(y0-y1)>gap*.15 for x0,y0,x1,y1 in lines)


def grouped_slide_pairs(label,beats,arcs,spans,lines,gap,top):
    """A centered sl. covers a contiguous group; other edges need unique H/P evidence."""
    matches=[];x=(label['bbox'][0]+label['bbox'][2])/2;y=label['origin'][1]
    for sh in arcs:
        a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
        if not (top-25<y<top+2 or abs(y-sh['rect'].y0)<gap*.5):continue
        starts=[i for i,(b,v) in enumerate(beats) if abs(v['x']-a.x)<1]
        ends=[i for i,(b,v) in enumerate(beats) if abs(v['x']-z.x)<1]
        if len(starts)!=1 or len(ends)!=1 or ends[0]-starts[0]<2:continue
        chain=beats[starts[0]:ends[0]+1]
        if any(v['grace'] or len(v['notes'])!=1 for b,v in chain):continue
        notes=[v['notes'][0] for b,v in chain]
        if any(n['dead'] or n['string']!=notes[0]['string'] for n in notes):continue
        offset=notes[0]['y']-a.y;end_offset=notes[-1]['y']-z.y
        if not (0<abs(offset)<gap*.8 and 0<abs(end_offset)<gap*.8
                and offset*end_offset>0 and abs(offset-end_offset)<gap*.25):continue
        labels=[m for m in spans if m['text'].strip().lower() in ('h','p','sl.')
                and a.x<(m['bbox'][0]+m['bbox'][2])/2<z.x
                and (top-25<m['origin'][1]<top+2 or abs(m['origin'][1]-sh['rect'].y0)<gap*.5)]
        slide_labels=[m for m in labels if m['text'].strip().lower()=='sl.']
        if len(slide_labels)!=1 or slide_labels[0] is not label:continue
        pairs=[(sb,sv['notes'][0],tb,tv['notes'][0]) for (sb,sv),(tb,tv) in zip(chain,chain[1:])]
        if any(tn['tie'] or sn['fret']==tn['fret'] or tb['number'] not in (sb['number'],sb['number']+1)
               for sb,sn,tb,tn in pairs):continue
        explained=set();valid=True
        for mark in labels:
            if mark is label:continue
            mx=(mark['bbox'][0]+mark['bbox'][2])/2
            edges=[i for i,(_,sn,_,tn) in enumerate(pairs) if sn['x']<mx<tn['x']]
            if len(edges)!=1 or edges[0] in explained:valid=False;break
            i=edges[0];_,sn,_,tn=pairs[i]
            direction=1 if mark['text'].strip().lower()=='h' else -1
            if (tn['fret']-sn['fret'])*direction<=0 or slide_line_count(sn,tn,lines,gap,minimum_width=gap*.15):
                valid=False;break
            explained.add(i)
        remaining=[i for i in range(len(pairs)) if i not in explained]
        if not valid or len(remaining)<2 or remaining!=list(range(remaining[0],remaining[-1]+1)):continue
        group=[pairs[i] for i in remaining]
        if abs(x-(group[0][1]['x']+group[-1][3]['x'])/2)>gap*.5:continue
        if any(not single_slide_evidence(sn,tn,lines,gap) for _,sn,_,tn in group):continue
        matches.append(group)
    return matches


def read_slides(system,spans,lines,shapes):
    """Read single notes and parallel chords from independent slide evidence."""
    top,bottom=system['ys'][0],system['ys'][-1];gap=(bottom-top)/5
    labels=[s for s in spans if s['text'].strip().lower()=='sl.'
            and system['left']<s['origin'][0]<system['right'] and top-25<s['origin'][1]<bottom+2]
    arcs=[sh for sh in shapes if sh['type']=='f' and len(sh['items'])==2
          and all(i[0]=='c' for i in sh['items']) and sh['rect'].height<gap*2]
    beats=[(b,v) for b in system['bars'] for v in b['beats']]
    marks=read_chord_slides(system,beats,lines,arcs,gap)
    for label in labels:
        matches=[];x=(label['bbox'][0]+label['bbox'][2])/2;y=label['origin'][1]
        if any(m.get('kind')=='parallel-chord' and m['start_x']<x<m['end_x'] for m in marks):continue
        matches.extend(grouped_slide_pairs(label,beats,arcs,spans,lines,gap,top))
        for (sb,sv),(tb,tv) in zip(beats,beats[1:]):
            if tv['grace'] or len(sv['notes'])!=1 or len(tv['notes'])!=1:continue
            if tb['number'] not in (sb['number'],sb['number']+1):continue
            sn,tn=sv['notes'][0],tv['notes'][0]
            if sn['dead'] or tn['dead'] or tn['tie'] or sn['string']!=tn['string'] or sn['fret']==tn['fret']:continue
            if not sn['x']<x<tn['x']:continue
            curves=[]
            for sh in arcs:
                a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
                offset=sn['y']-a.y;target_offset=tn['y']-z.y
                label_position=top-25<y<top+2 or abs(y-sh['rect'].y0)<gap*.5
                endpoints=abs(a.x-sn['x'])<1 and abs(z.x-tn['x'])<1
                if not endpoints and a.x<=sn['x']+1 and z.x>=tn['x']-1:
                    endpoints=shared_legato_curve(a,z,sn,tn,beats,spans,lines,gap,top,sh['rect'].y0)
                if (endpoints and label_position
                        and 0<abs(offset)<gap*.8 and 0<abs(target_offset)<gap*.8
                        and offset*target_offset>0 and abs(offset-target_offset)<gap*.25):curves.append(sh)
            if len(curves)==1 and single_slide_evidence(sn,tn,lines,gap):matches.append([(sb,sn,tb,tn)])
        mark={'page':system['page'],'x':x,'y':y,'status':'unsupported'}
        if len(matches)==1:
            for sb,sn,tb,tn in matches[0]:
                sn.update(legato_slide=True,slide_target_bar=tb['number'],slide_target_fret=tn['fret'])
                tn['slide_source_bar']=sb['number']
            mark.update(status='recognized',bar=matches[0][0][0]['number'],target_bar=tb['number'],string=sn['string'])
            if len(matches[0])>1:mark.update(kind='grouped-single-notes',transitions=len(matches[0]))
        else:mark['reason']='requires-unique-adjacent-same-string-notes-line-and-arc'
        marks.append(mark)
    return marks


def read_tremolos(system,spans,lines):
    """Three strokes on a supported TAB stem, or mirrored on its staff stem."""
    top,bottom=system['ys'][0],system['ys'][-1];gap=(bottom-top)/5
    marks=[];claims=[]
    for span in spans:
        x,y=span['origin']
        if span['text']!='\ue222' or not system['left']<x<system['right'] or not top<y<bottom+gap*4:continue
        mark={'page':system['page'],'x':x,'y':y,'status':'unsupported','reason':'requires-supported-single-note-and-stem'}
        marks.append(mark);candidates=[]
        for bar in system['bars']:
            for i,beat in enumerate(bar['beats']):
                if ((beat['duration'],tuple(beat['tuplet'])) not in ((4,(1,1)),(32,(1,1)),(32,(3,2))) or beat['dots'] or beat['grace']
                        or len(beat['notes'])!=1 or abs(beat['x']-x)>=1):continue
                note=beat['notes'][0]
                if note['dead'] or note['tie'] or not gap*.5<y-note['y']<gap*3:continue
                stems=[line for line in lines if abs(line[0]-line[2])<.2 and abs(line[0]-x)<1
                       and min(line[1],line[3])<y-gap*.5 and max(line[1],line[3])>y+gap*.8]
                if not stems and system['standard']:
                    upper=system['standard']['ys'][0]-30
                    heads=[s for s in spans if upper<s['origin'][1]<top-4 and s['size']>=14
                           and any(c in s['text'] for c in ('\ue0a2','\ue0a3','\ue0a4','\ue0a9'))
                           and abs((s['bbox'][0]+s['bbox'][2])/2-x)<1.5]
                    mirrored=[s for s in spans if s['text']=='\ue222' and upper<s['origin'][1]<top-4
                              and abs(s['origin'][0]-x)<4.5]
                    if len(heads)==1 and heads[0]['text']=='\ue0a4':
                        head=heads[0]
                        # Require a real stem attached to the unique notehead,
                        # crossing the matching mark; TAB position alone is insufficient.
                        stems=[l for mx,my in (m['origin'] for m in mirrored) for l in lines
                               if abs(l[0]-l[2])<.2 and abs(l[0]-mx)<1
                               and abs(l[1]-l[3])>9 and upper-25<min(l[1],l[3])<my-gap*.5
                               and my+gap*.8<max(l[1],l[3])<top-4
                               and ((abs(min(l[1],l[3])-head['origin'][1])<1.5 and abs(l[0]-head['bbox'][0])<1)
                                    or (abs(max(l[1],l[3])-head['origin'][1])<1.5 and abs(l[0]-head['bbox'][2])<1))]
                if len(stems)==1:candidates.append((bar,i,beat))
        if len(candidates)==1:claims.append((mark,*candidates[0]))
    counts=collections.Counter(id(beat) for mark,bar,i,beat in claims)
    for mark,bar,i,beat in claims:
        if counts[id(beat)]!=1:
            mark['reason']='duplicate-mark';continue
        beat['tremolo_strokes']=3
        mark.update(status='recognized',bar=bar['number'],beat=i,strokes=3)
        mark.pop('reason')
    return marks


def read_tempos(result,marks):
    events={1:result['tempo']};issues=[]
    for i,mark in enumerate(sorted(marks,key=lambda m:(m['page'],m['y'],m['x']))):
        # Retain the documented legacy initial-BPM fallback, but never apply
        # that assumption to a later tempo change.
        if i==0 and mark['unit'] is None and mark['bpm']==result['tempo']:continue
        if mark['unit']!='quarter' or mark['bpm'] is None:
            issues.append(f"第 {mark['page']} 页速度标记的计拍单位或数值未确认");continue
        candidates=[s for s in result['systems'] if s['page']==mark['page']
                    and 0<(s['standard'] or s)['ys'][0]-mark['y']<80]
        system=min(candidates,key=lambda s:(s['standard'] or s)['ys'][0]) if candidates else None
        bar=next((b for b in system['bars'] if b['left']<=mark['x']<b['right']),None) if system else None
        if i==0 and system and system is result['systems'][0]:bar=system['bars'][0]
        beats=[v for v in bar['beats'] if not v['grace']] if bar else []
        aligned=beats and (abs(beats[0]['x']-mark['x'])<2
                          or len(beats)==1 and not beats[0]['notes'] and mark['x']<bar['left']+60)
        if not bar or not (i==0 and bar['number']==1 or aligned):
            issues.append(f"第 {mark['page']} 页速度标记未能明确对应小节起点");continue
        if bar['number'] in events and events[bar['number']]!=mark['bpm']:
            issues.append(f"第 {bar['number']} 小节速度标记冲突");continue
        events[bar['number']]=mark['bpm']
    result['tempo_events']=[{'bar':n,'bpm':bpm} for n,bpm in sorted(events.items()) if bpm is not None]
    result['tempo_issues']=issues
    result['warnings'].extend(issues)
    active=result['tempo']
    for system in result['systems']:
        for bar in system['bars']:
            active=events.get(bar['number'],active);bar['tempo']=active


def validate_bar(bar):
    if any(b['duration'] is None for b in bar['beats']): bar['issues'].append('存在未识别时值')
    if not bar['issues']:
        expected=bar['meter'][0]*4/bar['meter'][1]
        total=sum(expected if b.get('fullBarRest') else
                  4/b['duration']*(2-2**(-b['dots']))*b['tuplet'][1]/b['tuplet'][0]
                  for b in bar['beats'] if not b['grace'])
        if abs(total-expected)>.005: bar['issues'].append(f'时值合计 {total:g} 拍，拍号需要 {expected:g} 拍')
    if bar['meter_source']!='pdf': bar['issues'].append('拍号未识别，禁止按默认拍号导出')
    bar['issues']=list(dict.fromkeys(bar['issues']))


def read_hidden_standard_ties(system,spans,lines,shapes,tuning=None):
    """Recover suppressed TAB tones from individually matched staff ties."""
    standard=system['standard']
    if not standard: return
    top=system['ys'][0]; upper=standard['ys'][0]-35
    heads=[s for s in spans if s['text'] in ('\ue0a2','\ue0a3','\ue0a4') and s['size']>=14
           and upper<s['origin'][1]<top-5 and system['left']<s['bbox'][0]<system['right']]
    center=lambda s:(s['bbox'][0]+s['bbox'][2])/2
    columns=[[s for s in heads if abs(center(s)-x)<1] for x in clusters([center(s) for s in heads],1)]
    arcs=[sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
          for sh in shapes if sh['type']=='f' and len(sh['items'])==2
          and all(i[0]=='c' for i in sh['items']) and sh['rect'].width>4
          and sh['rect'].height<12 and upper<sh['rect'].y0 and sh['rect'].y1<top]
    for before,after in zip(columns,columns[1:]):
        x=sum(map(center,after))/len(after)
        beats=[(b,v) for b in system['bars'] for v in b['beats']]
        if any(abs(v['x']-x)<4.5 for b,v in beats): continue
        prior=[(b,v) for b,v in beats if v['x']<x]
        if not prior: continue
        sb,source=max(prior,key=lambda t:t[1]['x'])
        tb=next((b for b in system['bars'] if b['left']<x<b['right']),None)
        if not tb or tb['number'] not in (sb['number'],sb['number']+1): continue
        if source['grace'] or source['duration'] is None or not source['notes']: continue
        if any(n['dead'] for n in source['notes']): continue
        if len(before)!=len(source['notes']) or len(after)>len(before): continue
        if any(abs(center(h)-source['x'])>=4.5 for h in before): continue
        ordered=sorted(before,key=lambda s:s['origin'][1]);retained=source['notes']
        if len(after)<len(before):
            # Map a subset only when every source head is present and known
            # tuning gives a unique pitch order. String order alone is unsafe:
            # a high fret on a lower string can sound above an open upper one.
            if not tuning or len(tuning)!=6:continue
            pitch=lambda n:tuning[n['string']-1]+n['fret']
            if len(set(map(pitch,retained)))!=len(retained):continue
            if any(abs(a['origin'][1]-z['origin'][1])<.25 for a,z in zip(ordered,ordered[1:])):continue
            if any(n.get('harmonic') for n in retained):continue  # Diamond-head mapping is not implemented.
            ranked=sorted(retained,key=pitch,reverse=True)
            matches=[[i for i,a in enumerate(ordered) if abs(a['origin'][1]-z['origin'][1])<.25]
                     for z in after]
            if any(len(m)!=1 for m in matches) or len({m[0] for m in matches})!=len(after):continue
            pairs=[(ordered[m[0]],z) for m,z in zip(matches,after)]
            retained=[ranked[m[0]] for m in matches]
        else:
            pairs=list(zip(ordered,sorted(after,key=lambda s:s['origin'][1])))
        if any(abs(a['origin'][1]-z['origin'][1])>.25 for a,z in pairs): continue
        # Every tone needs its own arc, at the head edges or aligned above/below
        # both head centers in compact notation. No arc may serve two tones.
        # One chord-level slur cannot imply several tied notes.
        connections=[]
        for a,z in pairs:
            space=standard['ys'][1]-standard['ys'][0]
            matches=[i for i,(p,q) in enumerate(arcs) if abs(p.y-q.y)<.5 and (
                     (abs(p.x-a['bbox'][2])<2 and abs(q.x-z['bbox'][0])<2
                      and abs(p.y-a['origin'][1])<1.5 and abs(q.y-z['origin'][1])<1.5)
                     or (abs(p.x-center(a))<space*.25 and abs(q.x-center(z))<space*.25
                         and space*.4<abs(p.y-a['origin'][1])<space*.8
                         and space*.4<abs(q.y-z['origin'][1])<space*.8))]
            connections.append(matches)
        if any(len(m)!=1 for m in connections): continue
        if len({m[0] for m in connections})!=len(pairs): continue
        if not any(abs(x0-x1)<.2 and min(h['bbox'][0] for h in after)-1<x0<max(h['bbox'][2] for h in after)+1
                   and abs(y1-y0)>9 and upper-15<min(y0,y1)<max(y0,y1)<top-4
                   for x0,y0,x1,y1 in lines): continue
        notes=[{**n,'x':x,'bbox':[x-1,n['y']-2,x+1,n['y']+2],'parenthesized':False,
                'tie':True,'tie_source_bar':sb['number'],'inferred_from':'standard-heads-and-tie-curves'}
               for n in retained]
        beat={'x':x,'notes':notes,'grace':False,'duration':None,'dots':0,'tuplet':[1,1]}
        read_rhythm(beat,system,standard,spans,lines,shapes,tb['left'],tb['right'])
        if beat['duration'] is None: continue
        tb['beats'].append(beat);tb['beats'].sort(key=lambda v:v['x'])
        tb['issues']=[issue for issue in tb['issues'] if issue!='空小节或休止符尚未识别']


def annotated_tie_start(note,point,gap):
    edge=note.get('tie_annotation_right')
    return edge is not None and abs(edge-point.x)<.6 and abs(note['y']-point.y)<gap*.25


def read_ties(system,spans,lines,shapes,padding_samples=(),fonts=None):
    """Use an actual connecting curve and equal pitch; never parentheses alone."""
    top,bottom=system['ys'][0],system['ys'][-1]; gap=(bottom-top)/5
    staff={'ys':system['ys']}; standard=system['standard']
    arcs=[sh['items'][0] for sh in shapes if sh['type']=='f' and len(sh['items'])==2
          and all(i[0]=='c' for i in sh['items']) and sh['rect'].width>4
          and sh['rect'].height<gap*2]
    def notes():
        return [(b,v,n) for b in system['bars'] for v in b['beats'] for n in v['notes']]
    # GP places the start of a harmonic's TAB tie after its small <...>
    # annotation. Record only a unique adjacent text edge; this does not infer
    # a harmonic's sounding pitch or turn the annotation into another note.
    for b,v,n in notes():
        if n['dead'] or n['parenthesized'] or v['grace']:continue
        origin=next((s for s in spans if list(s['bbox'])==n['bbox']),None)
        if not origin:continue
        labels=[s for s in spans if re.fullmatch(r'<\d{1,2}>',s['text'])
                and s['font']==origin['font'] and n['size']*.5<s['size']<n['size']*.82
                and 0<s['bbox'][0]-n['bbox'][2]<gap*.4
                and abs((s['bbox'][1]+s['bbox'][3])/2-n['y'])<gap*.3]
        if len(labels)==1:n['tie_annotation_right']=labels[0]['bbox'][2]
    def printed_cutout(note):
        if note.get('tie_cutout_half_width') is not None:return note['tie_cutout_half_width']
        source=next((s for s in spans if list(s['bbox'])==note['bbox']),None)
        if not source:return None
        fret_width=source.get('fret_width',source['bbox'][2]-source['bbox'][0])
        anchors={}
        for s in spans:
            if (s.get('fret_width') is None or s['font']!=source['font']
                    or abs(s['size']-note['size'])>.1):continue
            x0,y0,x1,y1=s['bbox'];ends=[]
            for arc in arcs:
                a,z=sorted((arc[1],arc[4]),key=lambda p:p.x)
                if (0<x0-z.x<2 and abs(z.y-(y0+y1)/2)<gap*.5
                        and abs(a.y-z.y)<gap*.25):ends.append((x0+x1)/2-z.x)
            # Separate the measured parentheses/margin from the actual digit
            # width, so narrow and wide frets share only the verified padding.
            if len(ends)==1:anchors[tuple(s['bbox'])]=ends[0]-s['fret_width']/2
        widths=list(anchors.values())
        # Two strings in one printed chord are one layout sample, not two.
        independent=any(abs((a[0]+a[2]-b[0]-b[2])/2)>.3 or abs(a[1]-b[1])>gap*5
                        for a in anchors for b in anchors)
        if independent and max(widths)-min(widths)<.3:
            width=sum(widths)/len(widths)+fret_width/2
            if gap*.5<width<gap*1.5:return width
        # Preserve local behavior; only use other pages when their actual font
        # resource, size, staff spacing and all observed margins agree.
        font=(fonts or {}).get(source['font'])
        pooled=[s for s in padding_samples if font is not None and s['font']==font
                and abs(s['size']-note['size'])<.1 and abs(s['gap']-gap)<.1]
        if not any(s['page']!=system['page'] for s in pooled):return None
        independent=any(a['page']!=b['page'] or abs(a['x']-b['x'])>.3 or abs(a['y']-b['y'])>gap*5
                        for a in pooled for b in pooled)
        measured=[s['padding'] for s in pooled]
        if independent and max(measured+widths)-min(measured+widths)<.3:
            width=sum(measured)/len(measured)+fret_width/2
            if gap*.5<width<gap*1.5:return width
        return None
    for arc in sorted(arcs,key=lambda a:min(a[1].x,a[4].x)):
        start,end=sorted((arc[1],arc[4]),key=lambda p:p.x)
        if not top-5<start.y<bottom+7 or not top-5<end.y<bottom+7: continue
        sources=[(b,v,n) for b,v,n in notes() if (abs(n['x']-start.x)<7
                 or (n['parenthesized'] or n.get('harmonic')=='natural') and abs(n['bbox'][2]-start.x)<2
                 or n.get('tie_outgoing_x') is not None and abs(n['tie_outgoing_x']-start.x)<.6
                    and abs(n['y']-start.y)<gap*.25
                 or n.get('tie_cutout_half_width') is not None
                    and abs(n['x']+n['tie_cutout_half_width']-start.x)<.3 and abs(n['y']-start.y)<gap*.25)
                 and abs(n['y']-start.y)<gap*.8 and n['x']<end.x-3 and not n['dead']]
        annotated=[(b,v,n) for b,v,n in notes() if annotated_tie_start(n,start,gap)]
        if len(annotated)==1:sources=annotated
        if not sources: continue
        sb,sv,sn=min(sources,key=lambda t:abs(t[2]['x']-start.x)+abs(t[2]['y']-start.y))
        # An existing different fret is a slur/hammer-on, not a tie.
        targets=[(b,v,n) for b,v,n in notes() if (abs(n['x']-end.x)<7
                 or n['parenthesized'] and abs(n['bbox'][0]-end.x)<2)
                 and n['string']==sn['string'] and n['x']>sn['x']+3]
        if targets:
            tb,tv,tn=min(targets,key=lambda t:abs(t[2]['x']-end.x))
            if tn['fret']!=sn['fret'] or tn.get('harmonic')!=sn.get('harmonic'): continue
            if not tn['parenthesized'] and not tn.get('inferred_from'): continue
            # Parenthesized two-digit frets are wider than the old centre
            # tolerance. Use their printed edge, but require adjacent beats:
            # an arc over a rest or another attack is not a single-voice tie.
            if sv['grace'] or tv['grace'] or tb['number'] not in (sb['number'],sb['number']+1): continue
            if any(sv['x']<v['x']<tv['x'] for b in system['bars'] for v in b['beats']): continue
        else:
            # This attachment is proven only for a printed same-pitch target.
            # Do not use it to invent a hidden harmonic destination.
            if annotated_tie_start(sn,start,gap):continue
            # GP often suppresses a tied fret number but retains its rhythm stem.
            def plain_other_string(beat):
                return (beat and not beat['grace'] and len(beat['notes'])==1
                        and not beat['notes'][0]['parenthesized'] and not beat['notes'][0]['dead']
                        and beat['notes'][0]['string']!=sn['string'])
            def paired_outgoing(x,incoming=end):
                # A wider invisible fret cutout needs symmetric incoming and
                # outgoing curves. Follow a complete hidden chain to printed
                # equal pitch; every recursive step moves strictly rightward.
                if not 0<x-incoming.x<gap*1.5 or any(abs(p.y-sn['y'])>gap*.25 for p in (start,incoming)):return None
                here=next((b for b in system['bars'] if b['left']<x<b['right']),None)
                if not here:return None
                matches=[]
                for other in arcs:
                    a,z=sorted((other[1],other[4]),key=lambda p:p.x)
                    if not a.x>x or abs(a.x-x-(x-incoming.x))>=.6:continue
                    if any(abs(p.y-sn['y'])>gap*.25 for p in (a,z)):continue
                    if any(n['parenthesized'] and not n['dead'] and not v['grace']
                           and n['string']==sn['string'] and n['fret']==sn['fret'] and n.get('harmonic')==sn.get('harmonic')
                           and b['number'] in (here['number'],here['number']+1)
                           and abs(n['bbox'][0]-z.x)<2 and n['x']>a.x+3
                           and not any(x<w['x']<v['x'] for bar in system['bars'] for w in bar['beats'])
                           for b,v,n in notes()):
                        matches.append(a.x);continue
                    following=clusters([sx for sx,y,sx1,y1 in lines if abs(sx-sx1)<.2 and sx>x+3
                                        and 0<sx-z.x<gap*1.5
                                        and bottom+gap*.8<max(y,y1)<bottom+gap*5
                                        and top-2<min(y,y1)<bottom+gap*3],.5)
                    if len(following)!=1:continue
                    nx=following[0]
                    target=next((b for b in system['bars'] if b['left']<nx<b['right']),None)
                    if not target or target['number'] not in (here['number'],here['number']+1):continue
                    # A two-sided hidden cutout can continue over new attacks
                    # on another string only with independently measured padding
                    # at both hidden destinations and no intervening beat.
                    next_beat=next((v for v in target['beats'] if abs(v['x']-nx)<1.5),None)
                    if (cutout is not None and abs(x-incoming.x-cutout)<.3 and abs(nx-z.x-cutout)<.3
                            and plain_other_string(next_beat)
                            and not any(x<w['x']<nx-1.5 for b in system['bars'] for w in b['beats'])):
                        matches.append(a.x);continue
                    # This extension only crosses wholly hidden beats. A rest,
                    # printed attack or partial chord must not be skipped.
                    if any(x<w['x']<nx+1.5 for b in system['bars'] for w in b['beats']):continue
                    if paired_outgoing(nx,z) is not None:matches.append(a.x)
                return matches[0] if len(matches)==1 else None
            stems=clusters([x for x,y,x1,y1 in lines if abs(x-x1)<.2 and abs(y1-y)>gap*.5
                            and abs(x-end.x)<max(7,gap*1.5)
                            and bottom+gap*.8<max(y,y1)<bottom+gap*5
                            and top-2<min(y,y1)<bottom+gap*3],.5)
            cutout=printed_cutout(sn)
            def matches_cutout(x):
                return (cutout is not None and abs(x-end.x-cutout)<.3
                        and all(abs(p.y-sn['y'])<gap*.25 for p in (start,end)))
            def beamed_hidden(x):
                # A wholly hidden destination can retain a short TAB stem
                # joined directly to the source by a complete filled beam.
                # This supplies independent evidence when no printed fret
                # parentheses exist to calibrate the omitted glyph width.
                if not 0<x-end.x<gap*1.5 or any(abs(p.y-sn['y'])>gap*.25 for p in (start,end)):return False
                if any(abs(v['x']-x)<1.5 for b in system['bars'] for v in b['beats']):return False
                short=[(min(y,y1),max(y,y1)) for sx,y,sx1,y1 in lines if abs(sx-sx1)<.2 and abs(sx-x)<.5
                       and abs(y-y1)>gap and bottom+gap*.5<min(y,y1)<bottom+gap*1.5]
                if len(short)!=1:return False
                beams=[]
                for sh in shapes:
                    if abs(sh['rect'].x0-sv['x'])>.5 or abs(sh['rect'].x1-x)>.5:continue
                    a=beam_cross_section(sh,sv['x']);z=beam_cross_section(sh,x)
                    if a is None or z is None or not bottom+gap*.8<a<bottom+gap*5:continue
                    if not short[0][0]<z<short[0][1]:continue
                    if any(abs(sx-sx1)<.2 and abs(sx-sv['x'])<.5 and min(y,y1)<sn['y']+gap
                           and min(y,y1)<a<max(y,y1) for sx,y,sx1,y1 in lines):beams.append(sh)
                return len(beams)==1
            stems=[x for x in stems if abs(x-end.x)<7 or paired_outgoing(x) is not None or matches_cutout(x) or beamed_hidden(x)]
            if len(stems)!=1: continue
            x=stems[0]
            # Visible notes on other strings may share this stem; only ink on
            # the source string rules out its suppressed continuation.
            if any(n['string']==sn['string'] and not n.get('inferred_from') and n['bbox'][0]-1<x<n['bbox'][2]+1
                   for b,v,n in notes()): continue
            tb=next((b for b in system['bars'] if b['left']<x<b['right']),None)
            if not tb or x<=sn['x']+3 or tb['number'] not in (sb['number'],sb['number']+1): continue
            tv=next((v for v in tb['beats'] if abs(v['x']-x)<1.5),None)
            if sv['grace'] or tv and (tv['grace'] or not tv['notes']): continue
            # A short tie mark can end near the next unrelated single note.
            # A single printed destination needs its own confirmed tie, or a
            # paired hidden chain; both require independently measured padding.
            visible_target=[n for n in tv['notes'] if not n.get('inferred_from')] if tv else []
            if len(visible_target)==1:
                confirmed_chord=(matches_cutout(x) and visible_target[0]['parenthesized']
                    and visible_target[0]['tie'] and any(n['string']==visible_target[0]['string']
                    and n['fret']==visible_target[0]['fret'] for n in sv['notes']))
                measured_chain=(matches_cutout(x) and plain_other_string(tv)
                    and (paired_outgoing(x) is not None or sn.get('tie_outgoing_x') is not None
                         and abs(sn['tie_outgoing_x']-start.x)<.6))
                if not confirmed_chord and not measured_chain:continue
            # With visible notes on another string, a displaced arc may be a
            # cross-string slur. Require both endpoints on the source string.
            if visible_target and (abs(start.y-sn['y'])>gap*.25 or abs(end.y-sn['y'])>gap*.25): continue
            if any(sv['x']<v['x']<x-1.5 for b in system['bars'] for v in b['beats']): continue
            tn={**sn,'x':x,'bbox':[x-1,sn['y']-2,x+1,sn['y']+2],
                'parenthesized':False,'inferred_from':'tie-curve-and-stem'}
            tn.pop('tie_outgoing_x',None)
            tn['tie_outgoing_x']=paired_outgoing(x)
            # Keep an independently measured glyph width even if this incoming
            # arc used a short offset; the following arc may use the full cutout.
            inherited_cutout=printed_cutout(sn)
            if inherited_cutout is not None:tn['tie_cutout_half_width']=inherited_cutout
            if tv: tv['notes'].append(tn)
            else:
                tv={'x':x,'notes':[tn],'grace':False,'duration':None,'dots':0,'tuplet':[1,1]}
                read_rhythm(tv,staff,standard,spans,lines,shapes,tb['left'],tb['right'])
                tb['beats'].append(tv); tb['beats'].sort(key=lambda v:v['x'])
        tn['tie']=True; tn['tie_source_bar']=sb['number']
    if not standard: return
    # Visible parenthesized continuations may have their tie in the standard
    # staff. Restrict to equal frets on the same string and a connecting arc.
    previous={}
    for b,v,n in notes():
        prior=previous.get(n['string'])
        if n['parenthesized'] and prior and n['fret']==prior[2]['fret'] and n.get('harmonic')==prior[2].get('harmonic'):
            for arc in arcs:
                a,z=sorted((arc[1],arc[4]),key=lambda p:p.x)
                if abs(a.x-prior[2]['x'])<12 and abs(z.x-n['x'])<12 and standard['ys'][0]-35<a.y<top-5:
                    n['tie']=True; n['tie_source_bar']=prior[0]['number']; break
        previous[n['string']]=(b,v,n)


def read_boundary_ties(previous,current,previous_shapes,current_shapes):
    """Join visible continuations only when both printed boundary arcs agree."""
    if not previous['bars'] or not current['bars']: return
    source_bar,target_bar=previous['bars'][-1],current['bars'][0]
    if source_bar['number']+1!=target_bar['number'] or source_bar['issues']: return
    if not source_bar['beats'] or not target_bar['beats']: return
    source,target=source_bar['beats'][-1],target_bar['beats'][0]
    if source['grace'] or target['grace'] or not source['notes'] or not target['notes']: return
    key=lambda n:(n['string'],n['fret'],n.get('harmonic',''))
    same_chord=(not any(n['dead'] for n in source['notes']+target['notes'])
                and all(n['parenthesized'] for n in target['notes'])
                and sorted(map(key,source['notes']))==sorted(map(key,target['notes'])))

    def boundary_arcs(system,shapes,beat,outgoing):
        gap=(system['ys'][-1]-system['ys'][0])/5
        # A double bar has an inner printed boundary before the staff ends.
        # Require that actual full-height line instead of widening tolerance.
        inner=[]
        if outgoing:
            for shape in shapes:
                for item in shape['items']:
                    if item[0]=='l':x,y,x1,y1=(*item[1],*item[2])
                    elif item[0]=='re' and item[1].width<1.5:
                        r=item[1];x=x1=(r.x0+r.x1)/2;y,y1=r.y0,r.y1
                    else:continue
                    if (abs(x-x1)<.2 and min(y,y1)<system['ys'][0]+.8
                            and max(y,y1)>system['ys'][-1]-.8
                            and 0<system['right']-x<gap):inner.append(x)
        arcs=[]
        for sh in shapes:
            if sh['type']!='f' or len(sh['items'])!=2 or sh['rect'].width<=4: continue
            if sh['rect'].height>=gap*2 or not all(i[0]=='c' for i in sh['items']): continue
            a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
            if outgoing:
                if abs(z.x-system['right'])>2 and not any(abs(z.x-x)<1 for x in inner):continue
                if abs(a.x-beat['x'])>12 and not any(annotated_tie_start(n,a,gap) for n in beat['notes']):continue
                point=a
            else:
                if not system['left']<a.x<system['left']+32 or abs(z.x-beat['x'])>12: continue
                point=z
            if abs(a.y-z.y)<1: arcs.append(point)
        return arcs

    outgoing=boundary_arcs(previous,previous_shapes,source,True)
    incoming=boundary_arcs(current,current_shapes,target,False)
    # Standard notation does not identify TAB strings by Y. Only accept the
    # entire identical chord, with one distinct boundary arc per chord tone.
    standard_match=False
    if same_chord and previous['standard'] and current['standard']:
        def standard_count(system,arcs):
            return len(clusters([p.y for p in arcs
                       if system['standard']['ys'][0]-35<p.y<system['ys'][0]-5],1))
        standard_match=(standard_count(previous,outgoing)==len(source['notes'])
                        and standard_count(current,incoming)==len(target['notes']))
    def tab_offsets(arcs,notes,note):
        return [p.y-note['y'] for p in arcs if abs(p.y-note['y'])<4.5
                and sum(abs(p.y-n['y'])<4.5 for n in notes)==1]
    for note in target['notes']:
        if not note['parenthesized'] or note['dead']: continue
        origins=[n for n in source['notes'] if not n['dead'] and key(n)==key(note)]
        if len(origins)!=1: continue
        origin=origins[0]
        # TAB curves must belong to the same string, at the same vertical
        # offset on each side. Do not attach a neighbouring string's curve.
        offsets_out=tab_offsets(outgoing,source['notes'],origin)
        offsets_in=tab_offsets(incoming,target['notes'],note)
        tab_match=any(abs(a-b)<.6 for a in offsets_out for b in offsets_in)
        if standard_match or tab_match:
            note['tie']=True
            note['tie_source_bar']=source_bar['number']
            note['tie_evidence']='paired-system-boundary-curves'


def read_mixed_half_chords(system,lines,shapes):
    """A circled attack and confirmed holds can share one detached half stem."""
    if system['standard']:return
    bottom=system['ys'][-1];gap=(bottom-system['ys'][0])/5
    for bar in system['bars']:
        for beat in bar['beats']:
            if beat['grace'] or beat['duration']!=4:continue
            held=[n for n in beat['notes'] if n['parenthesized'] and n['tie'] and not n['dead']]
            fresh=[n for n in beat['notes'] if not n['parenthesized'] and not n['tie'] and not n['dead']
                   and not n.get('harmonic') and not n.get('inferred_from')]
            if not held or not fresh or len(held)+len(fresh)!=len(beat['notes']):continue
            x=beat['x']
            stems=[(min(y,z),max(y,z)) for sx,y,ex,z in lines if abs(sx-ex)<.2 and abs(sx-x)<1.5
                   and bottom<min(y,z)<max(y,z)<bottom+gap*5]
            if len(stems)!=1:continue
            a,z=stems[0]
            if not (1.3<(a-bottom)/gap<1.7 and 2.3<(z-bottom)/gap<2.7 and .8<(z-a)/gap<1.2):continue
            rings=[s for s in shapes if s['type']=='s' and len(s['items'])==4 and all(i[0]=='c' for i in s['items'])
                   and all(abs(a[4]-b[1])<.1 for a,b in zip(s['items'],s['items'][1:]+s['items'][:1]))
                   and abs((s['rect'].x0+s['rect'].x1)/2-x)<1 and 5<s['rect'].width<16
                   and s['rect'].height<max(n['y'] for n in fresh)-min(n['y'] for n in fresh)+gap*2
                   and all(s['rect'].x0<n['bbox'][0]<n['bbox'][2]<s['rect'].x1
                           and s['rect'].y0<n['y']<s['rect'].y1 for n in fresh)
                   and not any(s['rect'].y0<n['y']<s['rect'].y1 for n in held)]
            if len(rings)==1:
                beat['duration']=2
                beat['evidence']='mixed-tab-half-chord'


def read_rhythm(beat,staff,standard,spans,lines,shapes,left,right):
    x=beat['x']; top,bottom=staff['ys'][0],staff['ys'][-1]
    gap=(bottom-top)/5
    if beat['grace']:
        beat['duration']=8
        return
    # TAB stems run downward, straight filled polygons near their ends are beams.
    stems=[(min(y0,y1),max(y0,y1)) for x0,y0,x1,y1 in lines
           if abs(x1-x0)<.2 and abs(x0-x)<1.5 and max(y0,y1)>bottom+gap*.8
           and top-2<min(y0,y1)<bottom+gap*3 and max(y0,y1)<bottom+gap*5]
    if stems:
        end=max(b for a,b in stems)
        beams=[]
        for sh in shapes:
            a,b,c,d=sh['rect']
            if sh['type']=='f' and a-1<=x<=c+1 and c-a>2 and .5<d-b<gap*.7 and bottom<b<end+.2:
                if all(it[0] in ('l','re') for it in sh['items']):
                    beams.append((b+d)/2)
        beam_count=len(clusters(beams,.5))
        if beam_count:
            beat['duration']=4*(2**beam_count)
        else:
            flags=[s for s in spans if abs(s['origin'][0]-x)<3 and bottom<s['origin'][1]<end+3
                   and any(0xe240<=ord(c)<=0xe247 for c in s['text'])]
            if flags:
                c=next(c for c in flags[0]['text'] if 0xe240<=ord(c)<=0xe247)
                beat['duration']=8*2**((ord(c)-0xe240)//2)
            else:
                beat['duration']=4
                # GP shortens a half-note continuation to one staff-space of
                # detached stem; a quarter continuation is about 1.75 spaces.
                if len(stems)==1 and all(n['parenthesized'] or n.get('inferred_from') for n in beat['notes']):
                    start,finish=stems[0]
                    if (1.3<(start-bottom)/gap<1.7 and 2.3<(finish-bottom)/gap<2.7
                            and .8<(finish-start)/gap<1.2): beat['duration']=2
        # A nearby following stem owns dots to its right; dense rhythms can
        # put its dot inside this beat's ordinary 12-point search window.
        next_stem=min((x0 for x0,y0,x1,y1 in lines if x+1.5<x0<right and abs(x1-x0)<.2
                       and bottom+gap*.8<max(y0,y1)<bottom+gap*5
                       and top-2<min(y0,y1)<bottom+gap*3),default=right)
        dots=[s for s in spans if '\ue1e7' in s['text'] and x<s['bbox'][0]<min(x+12,next_stem)
              and bottom<s['origin'][1]<bottom+gap*4]
        beat['dots']=len(dots)
    # Guitar Pro prints a closed ellipse around half/whole TAB notes, and uses
    # a short detached stem for half notes. Parentheses are separate open paths.
    rings=[sh for sh in shapes if sh['type']=='s' and len(sh['items'])==4
           and all(i[0]=='c' for i in sh['items'])
           and abs((sh['rect'].x0+sh['rect'].x1)/2-x)<1
           and (5<sh['rect'].width<16 or
                all(n.get('harmonic')=='natural' and sh['rect'].x0<n['bbox'][0]<n['bbox'][2]<sh['rect'].x1
                    and .5<sh['rect'].width-(n['bbox'][2]-n['bbox'][0])<gap for n in beat['notes']))
           and all(sh['rect'].y0<n['y']<sh['rect'].y1 for n in beat['notes'])]
    if rings: beat['duration']=2 if stems else 1
    # When present, use the standard staff's noteheads to disambiguate whole/half.
    if standard:
        upper=standard['ys'][0]-30
        heads=[s for s in spans if upper<s['origin'][1]<top-4 and abs((s['bbox'][0]+s['bbox'][2])/2-x)<4.5
               and (any(c in s['text'] for c in ('\ue0a2','\ue0a3','\ue0a4'))
                    or '\ue0a9' in s['text'] and all(n['dead'] for n in beat['notes']))
               and s['size']>=14]
        if heads:
            head=min(heads,key=lambda s:abs((s['bbox'][0]+s['bbox'][2])/2-x))
            if '\ue0a2' in head['text']: beat['duration']=1
            elif '\ue0a3' in head['text']: beat['duration']=2
            else:
                # A standard-only rhythm may have no TAB stems; inspect its beams.
                if beat['duration'] is None:
                    sx=head['bbox'][0]
                    standard_stems=[(x0,min(y0,y1),max(y0,y1)) for x0,y0,x1,y1 in lines
                                    if abs(x0-x1)<.2 and sx-1<x0<head['bbox'][2]+1
                                    and abs(y1-y0)>9 and upper-25<min(y0,y1)<top-4
                                    and max(y0,y1)<top-4]
                    if '\ue0a9' in head['text'] and not standard_stems:return
                    beams=[]
                    if standard_stems:
                        stem=min(standard_stems,key=lambda line:abs((line[1]+line[2])/2-head['origin'][1]))
                        for sh in shapes:
                            cross=beam_cross_section(sh,stem[0])
                            if cross and stem[1]-1<cross<stem[2]+1: beams.append(cross)
                    beat['duration']=4*2**len(clusters(beams,.5))
                    flags=[s for s in spans if standard_stems and not beams
                           and abs(s['origin'][0]-stem[0])<1.5 and upper<s['origin'][1]<top-4
                           and any(0xe240<=ord(c)<=0xe247 for c in s['text'])]
                    if flags:
                        c=next(c for c in flags[0]['text'] if 0xe240<=ord(c)<=0xe247)
                        beat['duration']=8*2**((ord(c)-0xe240)//2)
            # Dots on staff-line notes are shifted into the adjacent space.
            # Chord tones can draw several dots vertically at the same X; that
            # is one augmentation dot, not a doubly dotted note.
            dot_columns=[s['bbox'][0] for s in spans if s is not head and '\ue1e7' in s['text']
                         and head['bbox'][2]-1<s['bbox'][0]<head['bbox'][2]+6
                         and abs(s['origin'][1]-head['origin'][1])<5]
            beat['dots']=head['text'].count('\ue1e7')+len(clusters(dot_columns,.8))


def beam_cross_section(shape,x):
    if shape['type']!='f' or shape['rect'].width<3 or not all(i[0]=='l' for i in shape['items']):
        return None
    if not shape['rect'].x0-.3<=x<=shape['rect'].x1+.3: return None
    x=min(max(x,shape['rect'].x0+.01),shape['rect'].x1-.01)
    hits=[]
    for _,p,q in shape['items']:
        if min(p.x,q.x)<=x<=max(p.x,q.x) and abs(q.x-p.x)>.01:
            hits.append(p.y+(q.y-p.y)*(x-p.x)/(q.x-p.x))
    if hits and .5<max(hits)-min(hits)<3.5:
        return (max(hits)+min(hits))/2
    return None


def read_tuplets(bar,staff,standard,spans,lines):
    top,bottom=staff['ys'][0],staff['ys'][-1]
    low=standard['ys'][-1] if standard else bottom
    high=top-4 if standard else bottom+55
    ratios={3:2,5:4,6:4,7:4}
    labels=[s for s in spans if s['text'] in ('3','5','6','7') and 7<=s['size']<=10
            and 'arial' not in s['font'].lower() and low<s['origin'][1]<high
            and bar['left']<s['origin'][0]<bar['right']]
    used=set()
    for label in labels:
        count=int(label['text']); x=(label['bbox'][0]+label['bbox'][2])/2
        nearest=sorted(((abs(b['x']-x),i) for i,b in enumerate(bar['beats']) if not b['grace']),key=lambda a:a[0])[:count]
        ids=[i for _,i in nearest]
        if len(ids)==count and not used.intersection(ids):
            for i in ids: bar['beats'][i]['tuplet']=[count,ratios[count]]
            used.update(ids)
    if not standard:return
    # Upper triplet digits must have their own two-sided bracket. Fingerings
    # and nearby text must not turn the nearest notes into a tuplet.
    space=standard['ys'][1]-standard['ys'][0]
    upper=[s for s in spans if s['text']=='3' and 7<=s['size']<=10 and 'times' in s['font'].lower()
           and standard['ys'][0]-30<s['origin'][1]<standard['ys'][0]
           and bar['left']<s['origin'][0]<bar['right']]
    for label in upper:
        x0,_,x1,_=label['bbox'];y=label['origin'][1]
        horizontal=[(min(a,c),max(a,c),(b+d)/2) for a,b,c,d in lines
                    if abs(b-d)<.2 and abs(a-c)>space*.5 and y-space<(b+d)/2<y]
        left=[l for l in horizontal if 0<x0-l[1]<space]
        right=[l for l in horizontal if 0<l[0]-x1<space]
        if len(left)!=1 or len(right)!=1 or abs(left[0][2]-right[0][2])>.2:continue
        start,end=left[0][0],right[0][1];by=left[0][2]
        if not bar['left']<start<end<bar['right']:continue
        if any(sum(abs(a-c)<.2 and abs(a-x)<.2 and abs(min(b,d)-by)<.2
                   and space*.3<abs(b-d)<space*.8 for a,b,c,d in lines)!=1 for x in (start,end)):continue
        ids=[i for i,b in enumerate(bar['beats']) if start-.5<b['x']<end+.5]
        if len(ids)!=3 or used.intersection(ids):continue
        if any(bar['beats'][i]['grace'] or bar['beats'][i]['duration'] is None for i in ids):continue
        for i in ids:bar['beats'][i]['tuplet']=[3,2]
        used.update(ids)


def add_rests(bar,staff,standard,spans,lines,shapes):
    top,bottom=staff['ys'][0],staff['ys'][-1]
    low=standard['ys'][0]-15 if standard else top-2
    for s in spans:
        if s.get('rest_candidates')==[1,2]:
            # The two silhouettes are nearly identical: a whole rest hangs
            # from the second staff line, a half rest sits on the third.
            ys=(standard or staff)['ys'];space=ys[1]-ys[0]
            x0,y0,x1,y1=s['bbox']
            if not (.6*space<x1-x0<1.4*space and .3*space<y1-y0<.7*space):continue
            whole=abs(y0-ys[1])<space*.08
            half=abs(y1-ys[2])<space*.08
            if whole==half:continue
            # A short beam can have the same silhouette and staff position,
            # but it touches a long vertical stem. Rest rectangles do not.
            if any(abs(a-c)<.5 and x0-.6<a<x1+.6 and abs(d-b)>space*1.5
                   and min(b,d)<y1+.5 and max(b,d)>y0-.5 for a,b,c,d in lines):continue
            s={**s,'text':'\ue4e3' if whole else '\ue4e4','origin':(x0,ys[1] if whole else ys[2])}
        for c in s['text']:
            if 0xe4e3<=ord(c)<=0xe4e9 and bar['left']<s['bbox'][0]<bar['right'] and low<s['origin'][1]<bottom+5:
                duration=2**(ord(c)-0xe4e3)
                x=(s['bbox'][0]+s['bbox'][2])/2
                if any(abs(b['x']-x)<5 and not b['notes'] for b in bar['beats']): continue
                dots=s['text'].count('\ue1e7')+sum(z['text'].count('\ue1e7') for z in spans
                     if z is not s and s['bbox'][2]-1<z['bbox'][0]<s['bbox'][2]+6
                     and abs(z['origin'][1]-s['origin'][1])<(bottom-top)/5*.6)
                bar['beats'].append({'x':x,'notes':[],'grace':False,'duration':duration,'dots':dots,'tuplet':[1,1]})
    if (len(bar['beats'])==1 and not bar['beats'][0]['notes'] and bar['beats'][0]['duration']==1
            and not bar['beats'][0]['dots'] and bar['meter_source']=='pdf'):
        bar['beats'][0]['fullBarRest']=True
    if not bar['beats'] and bar['meter_source']=='pdf' and visually_empty(bar,staff,standard,spans,shapes):
        bar['beats'].append({'x':(bar['left']+bar['right'])/2,'notes':[],'grace':False,
                             'duration':1,'dots':0,'tuplet':[1,1],'fullBarRest':True,
                             'evidence':'empty-staff-region'})
    if not bar['beats']:
        bar['issues'].append('空小节或休止符尚未识别')


def read_stemless_whole_tie(bar,previous,staff,standard,spans,shapes):
    """Read GP's stemless parenthesized whole-note continuation, not a beat deficit."""
    if standard or not previous or previous['issues'] or previous['number']+1!=bar['number']:return
    if bar['meter_source']!='pdf' or len(bar['beats'])!=1 or not previous['beats']:return
    beat=bar['beats'][0];notes=beat['notes']
    if beat['duration'] is not None or beat['grace'] or not notes:return
    source={(n['string'],n['fret']) for n in previous['beats'][-1]['notes']}
    if not all(n['parenthesized'] and n['tie'] and not n['dead']
               and n.get('tie_source_bar')==previous['number']
               and (n['string'],n['fret']) in source for n in notes):return
    gap=(staff['ys'][-1]-staff['ys'][0])/5
    incoming=set()
    for note in notes:
        matches=[]
        for i,sh in enumerate(shapes):
            if sh['type']!='f' or len(sh['items'])!=2 or not all(it[0]=='c' for it in sh['items']):continue
            a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
            if (a.x<bar['left'] or note.get('tie_evidence')=='paired-system-boundary-curves'
                    and a.x<bar['left']+32) and abs(z.x-note['bbox'][0])<2:
                if abs(a.y-note['y'])<gap*.25 and abs(z.y-note['y'])<gap*.25:matches.append(i)
        if len(matches)!=1 or matches[0] in incoming:return
        incoming.add(matches[0])
    # Remove only identified non-rhythmic ink; every other mark still blocks inference.
    outgoing=set()
    for note in notes:
        matches=[]
        for i,sh in enumerate(shapes):
            if sh['type']!='f' or len(sh['items'])!=2 or not all(it[0]=='c' for it in sh['items']):continue
            a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
            if not (0<a.x-note['bbox'][2]<2 and a.x<z.x and sh['rect'].height<gap*2
                    and abs(a.y-note['y'])<gap*.25 and abs(z.y-note['y'])<gap*.25):continue
            boundary=abs(z.x-bar['right'])<1.5 and abs(bar['right']-staff['right'])<1
            label=('<'+str(note['fret'])+'>') if note.get('harmonic')=='natural' else str(note['fret'])
            targets=[s for s in spans if s['text']=='('+label+')'
                     and s['bbox'][0]>bar['right'] and 0<s['bbox'][0]-z.x<2
                     and abs((s['bbox'][1]+s['bbox'][3])/2-note['y'])<gap*.25]
            if boundary or len(targets)==1:matches.append(i)
        if len(matches)==1:outgoing.update(matches)
    wedges=[];bottom=staff['ys'][-1]
    for i,sh in enumerate(shapes):
        if sh['type']!='s' or len(sh['items'])!=1 or sh['items'][0][0]!='l' or sh.get('width',1)>=.8:continue
        a,z=sorted(sh['items'][0][1:],key=lambda p:p.x)
        if (staff['left']<a.x<z.x<staff['right'] and z.x-a.x>gap*3
                and bottom+gap*.4<min(a.y,z.y)<max(a.y,z.y)<bottom+gap*2.5):wedges.append((i,a,z))
    partners={i:[] for i,a,z in wedges}
    for i,a,z in wedges:
        for j,b,w in wedges:
            if i==j or abs(a.x-b.x)>.2 or abs(z.x-w.x)>.2:continue
            if (abs(a.y-b.y)<.2 and gap*.8<abs(z.y-w.y)<gap*2 and abs((z.y+w.y)/2-a.y)<.2
                    or abs(z.y-w.y)<.2 and gap*.8<abs(a.y-b.y)<gap*2 and abs((a.y+b.y)/2-z.y)<.2):partners[i].append(j)
    hairpins={i for i,others in partners.items() if len(others)==1 and len(partners[others[0]])==1}
    remaining_spans=[s for s in spans if not any(list(s['bbox'])==n['bbox'] for n in notes)]
    remaining_shapes=[sh for i,sh in enumerate(shapes) if i not in incoming|outgoing|hairpins]
    if not visually_empty(bar,staff,None,remaining_spans,remaining_shapes,bottom=staff['notation_bottom']):return
    beat['duration']=1
    beat['evidence']='stemless-whole-tab-continuation'


def visually_empty(bar,staff,standard,spans,shapes,bottom=None):
    """Only infer a silent bar when its notation area contains no unknown marks."""
    left,right=bar['left']+2,bar['right']-2
    top=(standard['ys'][0]-12 if standard else staff['ys'][0]-4)
    bottom=min(staff['ys'][-1]+20 if bottom is None else bottom,staff.get('notation_bottom',float('inf')))
    rows=staff['ys']+(standard['ys'] if standard else [])
    # Printed fret cutouts can leave very short pieces of an established line.
    def staff_segment(rect):
        return rect.height<.8 and (rect.width>20 or rect.width>1
                                  and any(abs((rect.y0+rect.y1)/2-y)<.15 for y in rows))
    ignored=[s for s in spans if s.get('page_footer') or any(c in s['text'] for c in ('\ue050','\ue06d','\ue08a','\ue08b'))
             or all('\ue080'<=c<='\ue089' for c in s['text'])]
    for s in spans:
        x,y=s['origin']
        if left<x<right and top<y<bottom and s not in ignored:
            # Bar numbers sit above the top staff, outside its notation region.
            if s['text'].isdigit() and s['size']<7 and y<(standard or staff)['ys'][0]: continue
            if s['text'].strip(): return False
    for sh in shapes:
        r=sh['rect']
        if r.x1<=left or r.x0>=right or r.y1<=top or r.y0>=bottom: continue
        parts=[]
        for item in sh['items']:
            if item[0] in ('l','c'):
                pts=item[1:]; parts.append(fitz.Rect(min(p.x for p in pts),min(p.y for p in pts),
                                                   max(p.x for p in pts),max(p.y for p in pts)))
            elif item[0]=='re': parts.append(item[1])
            else: parts.append(r)
        if not any(p.x1>left and p.x0<right and p.y1>top and p.y0<bottom for p in parts): continue
        if sh['type']=='s' and staff_segment(r): continue
        if r.width<1.5 and r.height>=staff['ys'][-1]-staff['ys'][0]-.5: continue
        if sh['type']=='s' and all(i[0]=='l' for i in sh['items']):
            relevant=[fitz.Rect(i[1],i[2]).normalize() for i in sh['items']]
            relevant=[p for p in relevant if p.x1>left and p.x0<right and p.y1>top and p.y0<bottom]
            if all(staff_segment(p) for p in relevant): continue
        if any(s.get('source')=='font-outline' and s['bbox']==list(r) for s in ignored): continue
        return False
    return True


def overlay(pdf,result,out):
    doc=fitz.open(pdf)
    for system in result['systems']:
        page=doc[system['page']-1]
        for bar in system['bars']:
            color=(.9,.15,.1) if bar['issues'] else (0,.5,.2)
            page.draw_rect(fitz.Rect(bar['left'],system['ys'][0]-2,bar['right'],system['ys'][-1]+2),color=color,width=.6)
            for beat in bar['beats']:
                for note in beat['notes']:
                    page.draw_rect(fitz.Rect(note['bbox']),color=(0,.3,.9),width=.5)
    doc.save(out)
    doc.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdf',type=Path)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args(); args.out.mkdir(parents=True,exist_ok=True)
    result=recognize(args.pdf)
    (args.out/'recognized.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    overlay(args.pdf,result,args.out/'overlay.pdf')
    bars=[b for s in result['systems'] for b in s['bars']]
    print(json.dumps({'bars':len(bars),'notes':sum(len(b['notes']) for bar in bars for b in bar['beats']),
                      'rhythm_checked_bars':sum(not b['issues'] for b in bars)},ensure_ascii=False))


if __name__=='__main__': main()
