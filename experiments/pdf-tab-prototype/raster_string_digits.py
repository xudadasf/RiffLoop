"""Read narrow string bands directly, avoiding generic text-line detection.

CTC character positions separate multi-digit frets from adjacent notes. All
coordinates and discarded bands are retained; scores are not accuracy claims.
"""
import re

import numpy as np


def group_characters(characters, gap):
    groups = []
    join_allowed = False
    for item in characters:
        if not item['char'].isdigit() or not item['char'].isascii():
            join_allowed = False
            continue
        if groups and join_allowed and item['x']-groups[-1][-1]['x'] <= gap*.95:
            groups[-1].append(item)
        else:
            groups.append([item])
        join_allowed = True
    separated = []
    for group in groups:
        # Dense adjacent two-digit frets can fall just inside the global
        # joining radius. Split only when the character geometry itself has
        # a distinct wider gap. Never chunk an ambiguous string into pairs.
        distances = np.diff([item['x'] for item in group])
        cuts = ([i+1 for i,d in enumerate(distances)
                 if d >= max(gap*.7, float(np.median(distances))*1.3)]
                if len(group)>2 else [])
        pieces = [group[a:b] for a,b in zip([0]+cuts, cuts+[len(group)])]
        if cuts and all(len(p)<=2 and (len(p)==1 or p[0]['char']!='0')
                        and int(''.join(c['char'] for c in p))<=36 for p in pieces):
            separated.extend(pieces)
        else:
            separated.append(group)
    return separated


def recognize_band(gray, x0, x1, y0, y1, gap, engine):
    def read(a,b):
        return engine(gray[a:b,x0:x1],use_det=False,use_cls=False,
                      return_word_box=True,return_single_char_box=True)
    first=read(y0,y1)
    candidates=[(first,y0,y1)]
    text=first.txts[0] if first.txts else ''
    score=float(first.scores[0]) if first.scores else 0
    # Weak numeric rows may be cropped a few pixels off-center after deskew.
    # Retry adjacent bands without crossing half a string; do not hallucinate
    # numbers from empty bands or perform generative deblurring.
    if re.search('[0-9]',text) and score<.99:
        shift=max(1,round(gap*.15))
        for offset in (-shift,shift):
            a,b=max(0,y0+offset),min(gray.shape[0],y1+offset)
            candidates.append((read(a,b),a,b))
    ranked=[(float(out.scores[0]) if out.scores and re.search('[0-9]',out.txts[0]) else 0,-index,index)
            for index,(out,_,_) in enumerate(candidates)]
    selected=max(ranked)[2]
    selected_score=ranked[selected][0]
    # A tiny confidence gain is not evidence that a different digit is better.
    # Weak neighboring-string fragments also must not be promoted just because
    # moving the crop caught more of the adjacent string.
    # Agreement at all three nearby positions can rescue a moderately weak
    # isolated digit without accepting a different neighboring-string reading.
    # Such notes still carry the recentered/review flag; confidence is not truth.
    stable = (len(candidates) == 3 and .7 <= score < .8 and selected_score >= .85
              and re.fullmatch(r'[0-9 ]+', text) is not None
              and all(out.txts and out.txts[0] == text for out,_,_ in candidates))
    if selected and (selected_score < score+.02 or (score<.8 and selected_score<.9 and not stable)):
        selected=0
    if selected and score >= .8:
        original_digits = re.sub('[^0-9]', '', text)
        selected_digits = re.sub('[^0-9]', '', candidates[selected][0].txts[0])
        collapsed_repeat = any(original_digits[i] == original_digits[i-1]
                               and original_digits[:i]+original_digits[i+1:] == selected_digits
                               for i in range(1,len(original_digits)))
        if collapsed_repeat and selected_score < .95:
            # Average confidence can increase merely by losing a difficult
            # repeated character (e.g. 6,11 -> 6,1). A still-uncertain
            # replacement is insufficient evidence for collapsing that pair.
            selected=0
    attempts=[{'text':out.txts[0] if out.txts else '', 'score':float(out.scores[0]) if out.scores else 0,
               'y0':a,'y1':b} for out,a,b in candidates]
    return (*candidates[selected],attempts,selected!=0)


def read_string_bands(gray, region, engine):
    gap = float(np.median(np.diff(region['ys'])))
    notes, unresolved, discarded, raw_rows = [], [], [], []
    crop_x, crop_y = region['crop'][:2]
    for bar, (left, right) in enumerate(zip(region['bar_boundaries'], region['bar_boundaries'][1:]), 1):
        x0 = crop_x if bar == 1 else round(left+gap*.4)
        x1 = min(gray.shape[1], round(right-gap*.4))
        for string, y in enumerate(region['ys'], 1):
            y0, y1 = max(0, round(y-gap*.65)), min(gray.shape[0], round(y+gap*.65))
            row = f'bar{bar}-string{string}'
            out,y0,y1,attempts,recentered = recognize_band(gray,x0,x1,y0,y1,gap,engine)
            text = out.txts[0] if out.txts else ''
            score = float(out.scores[0]) if out.scores else 0
            record = {'row': row, 'bar': bar, 'string': string, 'box': [x0,y0,x1,y1],
                      'text': text, 'score': score, 'characters': [],'attempts':attempts,'recentered':recentered}
            raw_rows.append(record)
            if not re.search('[0-9]', text):
                continue
            if score < .8:
                discarded.append({'row': row, 'bar': bar, 'string': string, 'text': text,
                                  'score': score, 'box': [x0,y0,x1,y1], 'attempts': attempts,
                                  'reason': '低分数字候选保留供核对，尚未写入 GP；可能是邻弦字形边缘，请对照原图确认'})
                continue
            if not out.word_results:
                unresolved.append({'row': row, 'text': text, 'reason': '没有字符定位结果'})
                continue
            info = out.word_results[0]
            compact = ''.join(text.split())
            confidences = ([float(c) for char, c in zip(text, info.confs) if not char.isspace()]
                           if len(info.confs) == len(text) else [score]*len(compact))
            positioned = []
            for words, columns in zip(info.words, info.word_cols):
                if len(words) != len(columns):
                    positioned = []
                    break
                positioned.extend(zip(words, columns))
            if ''.join(char for char, _ in positioned) != compact or not info.line_txt_len:
                unresolved.append({'row': row, 'text': text, 'reason': '字符定位与文字不一致'})
                continue
            for i, (char, column) in enumerate(positioned):
                record['characters'].append({'char': char, 'x': x0+float(column)*(x1-x0)/info.line_txt_len,
                                             'score': confidences[i]})
            for group in group_characters(record['characters'], gap):
                digits = ''.join(item['char'] for item in group)
                if len(digits)>2 or (len(digits)>1 and digits.startswith('0')) or int(digits)>36:
                    unresolved.append({'row': row, 'text': digits, 'reason': '品位分组存在歧义，未自动拆分或改写数字'})
                    continue
                a, b = group[0]['x']-gap*.3, group[-1]['x']+gap*.3
                confidence = min(item['score'] for item in group)
                notes.append({'bar': bar, 'string': string, 'fret': int(digits),
                              'x': round((a+b)/2, 2), 'y': y, 'ocr_score': confidence,
                              'review': confidence < .8 or score < .95 or recentered, 'row': row, 'method': 'string-band-ctc',
                              'review_reason': '裁剪位置重试后选取，需核对数字与弦位' if recentered else ('OCR 分数偏低，需核对数字与弦位' if confidence < .8 or score < .95 else None),
                              'box': [[a-crop_x,y0-crop_y],[b-crop_x,y0-crop_y],
                                      [b-crop_x,y1-crop_y],[a-crop_x,y1-crop_y]]})
    notes.sort(key=lambda n: (n['bar'], n['x'], n['string']))
    return notes, unresolved, discarded, raw_rows
