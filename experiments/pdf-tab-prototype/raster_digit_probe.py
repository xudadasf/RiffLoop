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
import time

import cv2
import numpy as np
from PIL import Image

from raster_tab import deskew, locate_systems, raster_pages
from raster_string_digits import read_string_bands
from raster_image_quality import condition_page


def digest(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run_probe(source, output, model_root):
    from rapidocr import RapidOCR
    output.mkdir(parents=True, exist_ok=False)
    engine = RapidOCR(params={'Global.model_root_dir': str(model_root), 'Global.log_level': 'warning',
                             'EngineConfig.onnxruntime.intra_op_num_threads': 4,
                             'EngineConfig.onnxruntime.inter_op_num_threads': 1})
    result = {'source': str(source.resolve()), 'source_sha256': digest(source),
              'method': 'Direct narrow-string OCR; CTC character spacing; measured string and bar geometry',
              'scope': 'Experimental notes-only; no timing, techniques, GP export or accuracy claim',
              'versions': {name: importlib.metadata.version(name) for name in ('rapidocr', 'onnxruntime')},
              'systems': [], 'errors': [], 'pages': []}
    started = time.monotonic()
    for page_number, gray in enumerate(raster_pages(source), 1):
        gray, quality = condition_page(gray)
        gray, angle = deskew(gray)
        page_path = output / f'page-{page_number}.png'
        Image.fromarray(gray).save(page_path)
        result['pages'].append({'page': page_number, 'path': page_path.name, 'deskew': angle, 'quality': quality})
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
            notes, unresolved, discarded, raw_rows = read_string_bands(gray, region, engine)
            (output / f'{clip_id}-bands.json').write_text(json.dumps(raw_rows, ensure_ascii=False, indent=2), encoding='utf-8')
            system = {'id': clip_id, 'page': page_number, 'region': region, 'notes': notes,
                      'unresolved': unresolved, 'discarded_bands': discarded, 'ignored': []}
            annotated = cv2.cvtColor(crop, cv2.COLOR_GRAY2RGB)
            for note in notes:
                color = (200, 60, 30) if note['review'] else (35, 110, 210)
                cv2.polylines(annotated, [np.asarray(note['box']).round().astype(np.int32)], True, color, 1)
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
                        + f'<p>另有 {len(system["discarded_bands"])} 条弱证据弦带未采用，可能是邻弦字形干扰，也可能包含漏识别；见 bands.json 原始记录。</p>'
                        + '<table><tr><th>辅助小节号</th><th>提案音符数</th><th>弦号与品位（从左到右）</th></tr>' + ''.join(rows) + '</table>')
    (output / 'review.html').write_text('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>数字识别可行性对照</title>'
        '<style>body{font:16px system-ui;max-width:1400px;margin:30px auto;padding:20px;line-height:1.7}img{max-width:100%}td,th{padding:10px;border-bottom:1px solid #ddd;text-align:left}aside{background:#fff2d6;padding:15px}</style>'
        '<h1>数字识别可行性对照</h1><aside>仅识别品位与弦号，不生成 GP，不推断节奏。蓝框为数字提案，红框及 (?) 为低分或裁剪位置重试的提案；分数不是正确概率，全部仍需核对。'
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
