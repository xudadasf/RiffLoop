"""Feasibility probe: OCR digits + TAB geometry. No GP or rhythm output.

Run with the separate digit-ocr-env interpreter. The desktop worker uses this
numeric front end; rhythm analysis and draft export happen downstream.
"""
import argparse
import hashlib
import html
import importlib.metadata
import json
from pathlib import Path
import re
import time

import cv2
import numpy as np
from PIL import Image

from raster_tab import deskew, locate_systems, raster_pages, runs


def digest(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def group_glyphs(characters, spans):
    """Use actual ink widths, not OCR's often touching character boxes.

    The narrow numeral 1 is excluded from font-width estimation. Ambiguous
    segmentation stays a failure; never split an invalid fret to make it fit.
    """
    if len(characters) != len(spans) or not characters:
        raise ValueError('OCR 字符数与像素字形数不一致')
    widths = [b - a + 1 for c, (a, b) in zip(characters, spans) if c != '1']
    if not widths:
        raise ValueError('全部为窄数字 1，无法确定单双位品位边界')
    advance_limit = float(np.median(widths)) * 1.2
    groups = []
    for index, (char, span) in enumerate(zip(characters, spans)):
        center = sum(span) / 2
        if groups and center - groups[-1]['last_center'] <= advance_limit:
            group = groups[-1]
            group['text'] += char
            group['right'] = span[1]
            group['indices'].append(index)
            group['last_center'] = center
        else:
            groups.append({'text': char, 'left': span[0], 'right': span[1],
                           'last_center': center, 'indices': [index]})
    for group in groups:
        text = group['text']
        if len(text) > 2 or (len(text) > 1 and text.startswith('0')) or int(text) > 36:
            raise ValueError(f'品位分组存在歧义：{text}；保留原 OCR，不自动拆分猜测')
        group['fret'] = int(text)
    return groups


def read_row(gray, text, box, word_result):
    if not re.fullmatch(r'[0-9\s]+', text):
        raise ValueError('非纯数字行；旁注、技巧与 X 闷音尚未处理')
    chars = re.sub(r'\s', '', text)
    points = np.asarray(box, np.float32)
    width = max(1, round(np.linalg.norm(points[1] - points[0])))
    height = max(1, round(np.linalg.norm(points[3] - points[0])))
    target = np.float32([[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]])
    matrix = cv2.getPerspectiveTransform(points, target)
    crop = cv2.warpPerspective(gray, matrix, (width, height), borderValue=255)
    ink = cv2.adaptiveThreshold(crop, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 31, 10)
    horizontal = cv2.morphologyEx(ink, cv2.MORPH_OPEN,
                                  cv2.getStructuringElement(cv2.MORPH_RECT, (max(20, width // 5), 1)))
    cleaned = cv2.subtract(ink, horizontal)
    components = runs(np.flatnonzero((cleaned > 0).sum(axis=0) >= max(3, height * .2)))
    spans = [(g[0], g[-1]) for g in components]
    groups = group_glyphs(chars, spans)
    scores = [(c[0], float(c[1])) for c in word_result if re.fullmatch(r'\d', c[0])]
    if ''.join(c for c, _ in scores) != chars:
        raise ValueError('字符定位结果与整行文字不一致')
    inverse = np.linalg.inv(matrix)
    for group in groups:
        rect = np.float32([[[group['left'], 0], [group['right'], 0],
                           [group['right'], height - 1], [group['left'], height - 1]]])
        group['box'] = cv2.perspectiveTransform(rect, inverse)[0].tolist()
        group['ocr_score'] = min(scores[i][1] for i in group['indices'])
    return groups


def json_value(value):
    if hasattr(value, 'tolist'):
        return value.tolist()
    if isinstance(value, (list, tuple)):
        return [json_value(x) for x in value]
    return value


def run_probe(source, output, model_root):
    from rapidocr import RapidOCR
    output.mkdir(parents=True, exist_ok=False)
    engine = RapidOCR(params={'Global.model_root_dir': str(model_root), 'Global.log_level': 'warning',
                             'EngineConfig.onnxruntime.intra_op_num_threads': 4,
                             'EngineConfig.onnxruntime.inter_op_num_threads': 1})
    result = {'source': str(source.resolve()), 'source_sha256': digest(source),
              'method': 'OCR numeric rows, pixel glyph spacing, nearest TAB string and measure geometry',
              'scope': 'Experimental notes-only; no timing, techniques, GP export or accuracy claim',
              'versions': {name: importlib.metadata.version(name) for name in ('rapidocr', 'onnxruntime')},
              'systems': [], 'errors': [], 'pages': []}
    started = time.monotonic()
    for page_number, gray in enumerate(raster_pages(source), 1):
        gray, angle = deskew(gray)
        page_path = output / f'page-{page_number}.png'
        Image.fromarray(gray).save(page_path)
        result['pages'].append({'page': page_number, 'path': page_path.name, 'deskew': angle})
        try:
            regions = locate_systems(gray)
        except ValueError as error:
            result['errors'].append(f'page {page_number}: {error}')
            continue
        if not regions:
            result['errors'].append(f'page {page_number}: no six-string system detected')
        for index, region in enumerate(regions, 1):
            x0, y0, x1, y1 = region['crop']
            crop = gray[y0:y1, x0:x1]
            clip_id = f'p{page_number}-s{index}'
            Image.fromarray(crop).save(output / f'{clip_id}.png')
            raw = engine(crop, use_cls=False, return_word_box=True, return_single_char_box=True)
            raw_data = {name: json_value(getattr(raw, name)) for name in ('txts', 'scores', 'boxes', 'word_results')}
            (output / f'{clip_id}-ocr.json').write_text(json.dumps(raw_data, ensure_ascii=False, indent=2), encoding='utf-8')
            system = {'id': clip_id, 'page': page_number, 'region': region, 'notes': [], 'unresolved': [], 'ignored': []}
            annotated = cv2.cvtColor(crop, cv2.COLOR_GRAY2RGB)
            for row_index, (text, box, words) in enumerate(zip(raw.txts or [], raw.boxes if raw.boxes is not None else [], raw.word_results or [])):
                if not any(c.isdigit() for c in text):
                    system['ignored'].append({'row': row_index, 'text': text, 'reason': 'non-numeric; not interpreted'})
                    continue
                try:
                    groups = read_row(crop, text, box, words)
                    for group in groups:
                        points = np.array(group['box'])
                        x, y = points.mean(axis=0) + [x0, y0]
                        gap = float(np.median(np.diff(region['ys'])))
                        distances = [abs(y - line) for line in region['ys']]
                        string = int(np.argmin(distances)) + 1
                        if min(distances) > gap * .4:
                            raise ValueError('数字距弦线过远，无法确定弦号')
                        bars = [(a, b) for a, b in zip(region['bar_boundaries'], region['bar_boundaries'][1:]) if a <= x < b]
                        if len(bars) != 1:
                            raise ValueError('数字无法归入唯一小节')
                        bar = next(i + 1 for i, (a, b) in enumerate(zip(region['bar_boundaries'], region['bar_boundaries'][1:])) if a <= x < b)
                        note = {'bar': bar, 'string': string, 'fret': group['fret'], 'x': round(float(x), 2),
                                'y': round(float(y), 2), 'ocr_score': group['ocr_score'],
                                'review': group['ocr_score'] < .8, 'row': row_index, 'box': group['box']}
                        system['notes'].append(note)
                        color = (200, 60, 30) if note['review'] else (35, 110, 210)
                        cv2.polylines(annotated, [points.round().astype(np.int32)], True, color, 1)
                except ValueError as error:
                    system['unresolved'].append({'row': row_index, 'text': text, 'reason': str(error)})
            system['notes'].sort(key=lambda n: (n['bar'], n['x'], n['string']))
            Image.fromarray(annotated).save(output / f'{clip_id}-boxes.png')
            result['systems'].append(system)
    result['seconds'] = round(time.monotonic() - started, 3)
    result['model_sha256'] = {p.name: digest(p) for p in sorted(model_root.glob('*.onnx'))}
    (output / 'prediction.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    esc = lambda text: html.escape(str(text))
    sections = []
    for system in result['systems']:
        rows = []
        for bar in range(1, system['region']['expected_bars'] + 1):
            notes = [n for n in system['notes'] if n['bar'] == bar]
            content = ' → '.join(f'{n["string"]}弦/{n["fret"]}品' + (' (?)' if n['review'] else '') for n in notes)
            rows.append(f'<tr><td>{bar}</td><td>{len(notes)}</td><td>{esc(content)}</td></tr>')
        sections.append(f'<h2>第 {system["page"]} 页 · {system["id"]}</h2><img src="{system["id"]}-boxes.png">'
                        + '<ul>' + ''.join(f'<li>{esc(v)}</li>' for v in system['unresolved']) + '</ul>'
                        + '<table><tr><th>辅助小节号</th><th>提案音符数</th><th>弦号与品位（从左到右）</th></tr>' + ''.join(rows) + '</table>')
    (output / 'review.html').write_text('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>数字识别可行性对照</title>'
        '<style>body{font:16px system-ui;max-width:1400px;margin:30px auto;padding:20px;line-height:1.7}img{max-width:100%}td,th{padding:10px;border-bottom:1px solid #ddd;text-align:left}aside{background:#fff2d6;padding:15px}</style>'
        '<h1>数字识别可行性对照</h1><aside>仅识别品位与弦号，不生成 GP，不推断节奏。蓝框为数字提案，红框及 (?) 为低 OCR 分数提案；分数不是正确概率，全部仍需核对。'
        '该探针尚未验证和弦同时分组、X 闷音与复杂布局。</aside><p>' + esc(source.name) + '</p>'
        + ''.join(f'<p>{esc(e)}</p>' for e in result['errors']) + ''.join(sections) + '</html>', encoding='utf-8')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--model-root', type=Path, required=True)
    args = parser.parse_args()
    result = run_probe(args.image, args.output, args.model_root)
    print(json.dumps({'systems': len(result['systems']), 'notes': sum(len(s['notes']) for s in result['systems']),
                      'unresolved_rows': sum(len(s['unresolved']) for s in result['systems']), 'seconds': result['seconds']}))
