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
    return groups


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
            out = engine(gray[y0:y1, x0:x1], use_det=False, use_cls=False,
                         return_word_box=True, return_single_char_box=True)
            text = out.txts[0] if out.txts else ''
            score = float(out.scores[0]) if out.scores else 0
            record = {'row': row, 'bar': bar, 'string': string, 'box': [x0,y0,x1,y1],
                      'text': text, 'score': score, 'characters': []}
            raw_rows.append(record)
            if not re.search('[0-9]', text):
                continue
            if score < .8:
                discarded.append({'row': row, 'text': text, 'reason': '窄弦带 OCR 分数不足；可能是邻弦字形边缘或漏识别，未采用'})
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
                              'review': confidence < .8, 'row': row, 'method': 'string-band-ctc',
                              'box': [[a-crop_x,y0-crop_y],[b-crop_x,y0-crop_y],
                                      [b-crop_x,y1-crop_y],[a-crop_x,y1-crop_y]]})
    notes.sort(key=lambda n: (n['bar'], n['x'], n['string']))
    return notes, unresolved, discarded, raw_rows
