"""EXPERIMENT: vector PDF tablature recognition. Never reads a reference GP."""
import argparse
import collections
import json
import re
from pathlib import Path

import fitz


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
    return groups


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
    for pi, page in enumerate(document):
        lines, shapes = lines_and_shapes(page)
        spans = text_spans(page)
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
                bar={'number':number,'left':left,'right':right,'meter':previous_meter[:],
                     'meter_source':meter_source,'beats':[], 'issues':[]}
                bar_notes=[n for n in notes if left<=n['x']<right]
                for x in clusters([n['x'] for n in bar_notes],1.6):
                    chord=sorted([n for n in bar_notes if abs(n['x']-x)<1.6],key=lambda n:n['string'])
                    grace=all(n['size']<normal_size*.82 for n in chord)
                    beat={'x':x,'notes':chord,'grace':grace,'duration':None,'dots':0,'tuplet':[1,1]}
                    read_rhythm(beat,staff,standard,spans,lines,shapes,left,right)
                    bar['beats'].append(beat)
                add_rests(bar,staff,standard,spans,shapes)
                bar['beats'].sort(key=lambda b:b['x'])
                read_tuplets(bar,staff,standard,spans)
                for beat in bar['beats']:
                    if beat['duration'] is None:
                        bar['issues'].append('存在未识别时值')
                if not bar['issues']:
                    total=sum(4/b['duration']*(2-2**(-b['dots']))*b['tuplet'][1]/b['tuplet'][0]
                              for b in bar['beats'] if not b['grace'])
                    expected=bar['meter'][0]*4/bar['meter'][1]
                    if abs(total-expected)>.005:
                        bar['issues'].append(f'时值合计 {total:g} 拍，拍号需要 {expected:g} 拍')
                bar['issues']=list(dict.fromkeys(bar['issues']))
                system['bars'].append(bar)
            result['systems'].append(system)
    if not result['systems']:
        result['warnings'].append('未找到可提取的六线谱；当前不支持扫描图片或四弦贝斯谱。')
    if not result['tuning']:
        result['warnings'].append('未确认标准定弦，导出前须人工确认定弦。')
    if not result['tempo']:
        result['warnings'].append('未识别 BPM，导出前须人工确认。')
    if any(b['meter_source']=='assumed-4/4' for s in result['systems'] for b in s['bars']):
        result['warnings'].append('部分小节未识别到拍号，使用了 4/4 假设，须人工核对。')
    document.close()
    return result


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
        dots=[s for s in spans if '\ue1e7' in s['text'] and x<s['bbox'][0]<x+12
              and bottom<s['origin'][1]<bottom+gap*4]
        beat['dots']=len(dots)
    # When present, use the standard staff's noteheads to disambiguate whole/half.
    if standard:
        upper=standard['ys'][0]-30
        heads=[s for s in spans if upper<s['origin'][1]<top-4 and abs((s['bbox'][0]+s['bbox'][2])/2-x)<4.5
               and any(c in s['text'] for c in ('\ue0a2','\ue0a3','\ue0a4'))
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
                    beams=[]
                    if standard_stems:
                        stem=min(standard_stems,key=lambda line:abs((line[1]+line[2])/2-head['origin'][1]))
                        for sh in shapes:
                            cross=beam_cross_section(sh,stem[0])
                            if cross and stem[1]-1<cross<stem[2]+1: beams.append(cross)
                    beat['duration']=4*2**len(clusters(beams,.5))
                    flags=[s for s in spans if abs(s['bbox'][0]-sx)<7 and upper<s['origin'][1]<top-4
                           and any(0xe240<=ord(c)<=0xe247 for c in s['text'])]
                    if flags:
                        c=next(c for c in flags[0]['text'] if 0xe240<=ord(c)<=0xe247)
                        beat['duration']=8*2**((ord(c)-0xe240)//2)
            beat['dots']=head['text'].count('\ue1e7')+sum(s['text'].count('\ue1e7') for s in spans
                         if s is not head and head['bbox'][2]-1<s['bbox'][0]<head['bbox'][2]+6
                         and abs(s['origin'][1]-head['origin'][1])<5)


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
    labels=[s for s in spans if s['text'] in ('3','6') and s['size']<=10
            and 'arial' not in s['font'].lower() and low<s['origin'][1]<high
            and bar['left']<s['origin'][0]<bar['right']]
    used=set()
    for label in labels:
        count=int(label['text']); x=(label['bbox'][0]+label['bbox'][2])/2
        nearest=sorted(((abs(b['x']-x),i) for i,b in enumerate(bar['beats']) if not b['grace']),key=lambda a:a[0])[:count]
        ids=[i for _,i in nearest]
        if len(ids)==count and not used.intersection(ids):
            for i in ids: bar['beats'][i]['tuplet']=[count,2 if count==3 else 4]
            used.update(ids)


def add_rests(bar,staff,standard,spans,shapes):
    top,bottom=staff['ys'][0],staff['ys'][-1]
    low=standard['ys'][0]-15 if standard else top-2
    for s in spans:
        for c in s['text']:
            if 0xe4e3<=ord(c)<=0xe4e9 and bar['left']<s['bbox'][0]<bar['right'] and low<s['origin'][1]<bottom+5:
                duration=2**(ord(c)-0xe4e3)
                x=(s['bbox'][0]+s['bbox'][2])/2
                if any(abs(b['x']-x)<5 and not b['notes'] for b in bar['beats']): continue
                bar['beats'].append({'x':x,'notes':[],'grace':False,'duration':duration,'dots':s['text'].count('\ue1e7'),'tuplet':[1,1]})
    # Older PDFs draw rest glyphs as paths. Leave unidentified rests unresolved.
    if not bar['beats']:
        bar['issues'].append('空小节或休止符尚未识别')


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
