"""EXPERIMENT: vector PDF tablature recognition. Never reads a reference GP."""
import argparse
import collections
import json
import re
from pathlib import Path

import fitz
from symbols import outline_spans


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
    return [{'text': ''.join(chr(c[0]) for c in s['chars']),
             'origin':s['chars'][0][2],'bbox':s['bbox'], 'font':s['font'],'size':s['size']}
            for s in page.get_texttrace() if s['chars'] and s['opacity']>0 and s['dir'][0]>.9]


def recognize(pdf):
    document = fitz.open(pdf)
    result = {'input':str(Path(pdf).resolve()), 'format':'vector-pdf-experiment-v1',
              'tempo':None,'tuning':None,'pages':len(document),'systems':[],
              'warnings':['演奏技巧、延音、反复结构和速度变化尚未完整识别，所有导出均为实验稿。',
                          '初始 BPM 暂按四分音符计拍，须人工核对速度标记。']}
    previous_meter = [4, 4]
    meter_source = 'assumed-4/4'
    previous_number = 0
    previous_shapes = []
    for pi, page in enumerate(document):
        lines, shapes = lines_and_shapes(page)
        spans = text_spans(page)
        if not any('bravura' in s['font'].lower() for s in spans):
            spans += outline_spans(shapes)
        text = page.get_text()
        if 'Standard tuning' in text:
            result['tuning'] = [64,59,55,50,45,40]
        if result['tempo'] is None:
            tempo = re.search(r'=\s*(\d{2,3})', text)
            if tempo:
                result['tempo'] = int(tempo[1])
        groups = staves(lines, page.rect.width)
        for gi, staff in enumerate(groups):
            if staff['count'] != 6:
                continue
            ys = staff['ys']; gap = (ys[-1]-ys[0])/5
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
                if not re.fullmatch(r'\(?\d{1,2}\)?|[xX]',token):
                    continue
                if not any(font in span['font'].lower() for font in ('arial','helvetica')):
                    continue
                x0,y0,x1,y1=span['bbox']; x=(x0+x1)/2; y=(y0+y1)/2
                si=min(range(6),key=lambda i:abs(ys[i]-y))
                if abs(ys[si]-y)>gap*.36 or not staff['left']+5<x<staff['right']+1:
                    continue
                notes.append({'x':x,'y':ys[si],'string':si+1,
                              'fret':None if token.upper()=='X' else int(token.strip('()')),
                              'dead':token.upper()=='X','parenthesized':token.startswith('('),
                              'tie':False,
                              'size':span['size'],'bbox':list(span['bbox'])})
            normal_size = collections.Counter(round(n['size'],1) for n in notes).most_common(1)
            normal_size = normal_size[0][0] if normal_size else 7
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
            read_hidden_standard_ties(system,spans,lines,shapes)
            read_ties(system,spans,lines,shapes)
            if result['systems']:
                read_boundary_ties(result['systems'][-1],system,previous_shapes,shapes)
            for bar in system['bars']:
                # New hidden tie destinations must participate in tuplet grouping.
                for beat in bar['beats']:
                    beat['notes'].sort(key=lambda n:n['string'])
                    beat['tuplet']=[1,1]
                read_tuplets(bar,staff,standard,spans)
                validate_bar(bar)
            result['systems'].append(system)
            previous_shapes = shapes
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


def read_hidden_standard_ties(system,spans,lines,shapes):
    """Recover a suppressed TAB chord only from a complete matching staff chord."""
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
          and sh['rect'].height<12 and upper<sh['rect'].y0<top-5]
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
        if len(before)!=len(after) or len(after)!=len(source['notes']): continue
        if any(abs(center(h)-source['x'])>=4.5 for h in before): continue
        pairs=list(zip(sorted(before,key=lambda s:s['origin'][1]),sorted(after,key=lambda s:s['origin'][1])))
        if any(abs(a['origin'][1]-z['origin'][1])>.25 for a,z in pairs): continue
        # Every tone needs its own horizontal arc, terminating at the two
        # notehead edges. One chord-level slur cannot imply several tied notes.
        connections=[]
        for a,z in pairs:
            matches=[i for i,(p,q) in enumerate(arcs) if abs(p.x-a['bbox'][2])<2
                     and abs(q.x-z['bbox'][0])<2 and abs(p.y-q.y)<.5
                     and abs(p.y-a['origin'][1])<1.5 and abs(q.y-z['origin'][1])<1.5]
            connections.append(matches)
        if any(len(m)!=1 for m in connections): continue
        if len({m[0] for m in connections})!=len(pairs): continue
        if not any(abs(x0-x1)<.2 and min(h['bbox'][0] for h in after)-1<x0<max(h['bbox'][2] for h in after)+1
                   and abs(y1-y0)>9 and upper-15<min(y0,y1)<max(y0,y1)<top-4
                   for x0,y0,x1,y1 in lines): continue
        notes=[{**n,'x':x,'bbox':[x-1,n['y']-2,x+1,n['y']+2],'parenthesized':False,
                'tie':True,'tie_source_bar':sb['number'],'inferred_from':'standard-heads-and-tie-curves'}
               for n in source['notes']]
        beat={'x':x,'notes':notes,'grace':False,'duration':None,'dots':0,'tuplet':[1,1]}
        read_rhythm(beat,system,standard,spans,lines,shapes,tb['left'],tb['right'])
        if beat['duration'] is None: continue
        tb['beats'].append(beat);tb['beats'].sort(key=lambda v:v['x'])
        tb['issues']=[issue for issue in tb['issues'] if issue!='空小节或休止符尚未识别']


def read_ties(system,spans,lines,shapes):
    """Use an actual connecting curve and equal pitch; never parentheses alone."""
    top,bottom=system['ys'][0],system['ys'][-1]; gap=(bottom-top)/5
    staff={'ys':system['ys']}; standard=system['standard']
    arcs=[sh['items'][0] for sh in shapes if sh['type']=='f' and len(sh['items'])==2
          and all(i[0]=='c' for i in sh['items']) and sh['rect'].width>4
          and sh['rect'].height<gap*2]
    def notes():
        return [(b,v,n) for b in system['bars'] for v in b['beats'] for n in v['notes']]
    for arc in sorted(arcs,key=lambda a:min(a[1].x,a[4].x)):
        start,end=sorted((arc[1],arc[4]),key=lambda p:p.x)
        if not top-5<start.y<bottom+7 or not top-5<end.y<bottom+7: continue
        sources=[(b,v,n) for b,v,n in notes() if (abs(n['x']-start.x)<7
                 or n['parenthesized'] and abs(n['bbox'][2]-start.x)<2)
                 and abs(n['y']-start.y)<gap*.8 and n['x']<end.x-3 and not n['dead']]
        if not sources: continue
        sb,sv,sn=min(sources,key=lambda t:abs(t[2]['x']-start.x)+abs(t[2]['y']-start.y))
        # An existing different fret is a slur/hammer-on, not a tie.
        targets=[(b,v,n) for b,v,n in notes() if (abs(n['x']-end.x)<7
                 or n['parenthesized'] and abs(n['bbox'][0]-end.x)<2)
                 and n['string']==sn['string'] and n['x']>sn['x']+3]
        if targets:
            tb,tv,tn=min(targets,key=lambda t:abs(t[2]['x']-end.x))
            if tn['fret']!=sn['fret']: continue
            if not tn['parenthesized'] and not tn.get('inferred_from'): continue
            # Parenthesized two-digit frets are wider than the old centre
            # tolerance. Use their printed edge, but require adjacent beats:
            # an arc over a rest or another attack is not a single-voice tie.
            if sv['grace'] or tv['grace'] or tb['number'] not in (sb['number'],sb['number']+1): continue
            if any(sv['x']<v['x']<tv['x'] for b in system['bars'] for v in b['beats']): continue
        else:
            # GP often suppresses a tied fret number but retains its rhythm stem.
            stems=clusters([x for x,y,x1,y1 in lines if abs(x-x1)<.2 and abs(x-end.x)<7
                            and bottom+gap*.8<max(y,y1)<bottom+gap*5
                            and top-2<min(y,y1)<bottom+gap*3],.5)
            if len(stems)!=1: continue
            x=stems[0]
            if any(not n.get('inferred_from') and n['bbox'][0]-1<x<n['bbox'][2]+1
                   for b,v,n in notes()): continue
            tb=next((b for b in system['bars'] if b['left']<x<b['right']),None)
            if not tb or x<=sn['x']+3: continue
            tn={**sn,'x':x,'bbox':[x-1,sn['y']-2,x+1,sn['y']+2],
                'parenthesized':False,'inferred_from':'tie-curve-and-stem'}
            tv=next((v for v in tb['beats'] if abs(v['x']-x)<1.5),None)
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
        if n['parenthesized'] and prior and n['fret']==prior[2]['fret']:
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
    key=lambda n:(n['string'],n['fret'])
    if any(n['dead'] for n in source['notes']+target['notes']): return
    if not all(n['parenthesized'] for n in target['notes']): return
    if sorted(map(key,source['notes']))!=sorted(map(key,target['notes'])): return

    def boundary_arcs(system,shapes,beat,outgoing):
        gap=(system['ys'][-1]-system['ys'][0])/5
        arcs=[]
        for sh in shapes:
            if sh['type']!='f' or len(sh['items'])!=2 or sh['rect'].width<=4: continue
            if sh['rect'].height>=gap*2 or not all(i[0]=='c' for i in sh['items']): continue
            a,z=sorted((sh['items'][0][1],sh['items'][0][4]),key=lambda p:p.x)
            if outgoing:
                if abs(z.x-system['right'])>2 or abs(a.x-beat['x'])>12: continue
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
    if previous['standard'] and current['standard']:
        def standard_count(system,arcs):
            return len(clusters([p.y for p in arcs
                       if system['standard']['ys'][0]-35<p.y<system['ys'][0]-5],1))
        standard_match=(standard_count(previous,outgoing)==len(source['notes'])
                        and standard_count(current,incoming)==len(target['notes']))
    def tab_offsets(arcs,notes,note):
        return [p.y-note['y'] for p in arcs if abs(p.y-note['y'])<4.5
                and sum(abs(p.y-n['y'])<4.5 for n in notes)==1]
    for note in target['notes']:
        origin=next(n for n in source['notes'] if key(n)==key(note))
        # TAB curves must belong to the same string, at the same vertical
        # offset on each side. Do not attach a neighbouring string's curve.
        offsets_out=tab_offsets(outgoing,source['notes'],origin)
        offsets_in=tab_offsets(incoming,target['notes'],note)
        tab_match=any(abs(a-b)<.6 for a in offsets_out for b in offsets_in)
        if standard_match or tab_match:
            note['tie']=True
            note['tie_source_bar']=source_bar['number']
            note['tie_evidence']='paired-system-boundary-curves'


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
        dots=[s for s in spans if '\ue1e7' in s['text'] and x<s['bbox'][0]<x+12
              and bottom<s['origin'][1]<bottom+gap*4]
        beat['dots']=len(dots)
    # Guitar Pro prints a closed ellipse around half/whole TAB notes, and uses
    # a short detached stem for half notes. Parentheses are separate open paths.
    rings=[sh for sh in shapes if sh['type']=='s' and len(sh['items'])==4
           and all(i[0]=='c' for i in sh['items'])
           and abs((sh['rect'].x0+sh['rect'].x1)/2-x)<1
           and 5<sh['rect'].width<16
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


def read_tuplets(bar,staff,standard,spans):
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


def visually_empty(bar,staff,standard,spans,shapes):
    """Only infer a silent bar when its notation area contains no unknown marks."""
    left,right=bar['left']+2,bar['right']-2
    top=(standard['ys'][0]-12 if standard else staff['ys'][0]-4)
    bottom=staff['ys'][-1]+20
    ignored=[s for s in spans if any(c in s['text'] for c in ('\ue050','\ue06d','\ue08a','\ue08b'))
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
        if r.height<.8 and r.width>20: continue  # staff/ledger lines
        if r.width<1.5 and r.height>=staff['ys'][-1]-staff['ys'][0]-.5: continue
        if sh['type']=='s' and all(i[0]=='l' for i in sh['items']):
            relevant=[fitz.Rect(i[1],i[2]).normalize() for i in sh['items']]
            relevant=[p for p in relevant if p.x1>left and p.x0<right and p.y1>top and p.y0<bottom]
            if all(p.height<.8 and p.width>20 for p in relevant): continue
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
