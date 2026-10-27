"""Image entry point: local digit evidence only, never placeholder GP export."""
import html
import json
import os
from pathlib import Path
import subprocess

from raster_tab import deskew, locate_systems, raster_pages

ROOT = Path(__file__).resolve().parent
BASE = Path('D:/RiffLoop-model-tests/raster-tab-20261027')
FORMAT = 'raster-digit-review-v1'


def recognize_image_review(source, folder):
    result = {'format': FORMAT, 'systems': [], 'errors': []}
    # Avoid starting the OCR runtime for blank/unsupported pages. Do not silently
    # skip a page in a mixed document and present the remaining pages as complete.
    for page, gray in enumerate(raster_pages(source), 1):
        try:
            gray, _ = deskew(gray)
            if not locate_systems(gray):
                result['errors'].append(f'第 {page} 页没有可靠定位到六条谱线')
        except ValueError as error:
            result['errors'].append(f'第 {page} 页：{error}')
    if result['errors']:
        return result
    runtime = Path(os.environ.get('RIFFLOOP_DIGIT_PYTHON', str(BASE / 'digit-ocr-env/Scripts/python.exe')))
    models = Path(os.environ.get('RIFFLOOP_DIGIT_MODELS', str(BASE / 'digit-ocr-probe/models')))
    if not runtime.is_file() or any(not (models / name).is_file() for name in
                                   ('PP-OCRv6_det_small.onnx', 'PP-OCRv6_rec_small.onnx')):
        raise ValueError('本地数字识别环境或模型缺失；未回退到旧模型，未生成 GP。请配置 RIFFLOOP_DIGIT_PYTHON / RIFFLOOP_DIGIT_MODELS。')
    output = folder / 'digit-ocr'
    run = subprocess.run([str(runtime), str(ROOT / 'raster_digit_probe.py'), str(source),
                          '--output', str(output), '--model-root', str(models)],
                         capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=600,
                         env=dict(os.environ, PYTHONUTF8='1', PYTHONDONTWRITEBYTECODE='1'),
                         creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    (folder / 'image-digits.log').write_text(run.stdout + '\n' + run.stderr, encoding='utf-8')
    if run.returncode:
        raise ValueError('数字识别未完成；请查看 image-digits.log。未回退到旧模型，未生成 GP。')
    result.update(json.loads((output / 'prediction.json').read_text(encoding='utf-8')))
    return result


def write_image_review(source, folder, outcome, data):
    esc = lambda value: html.escape(str(value), quote=True)
    sections = []
    for system in data.get('systems', []):
        rows = []
        for bar in range(1, system['region']['expected_bars'] + 1):
            notes = [n for n in system['notes'] if n['bar'] == bar]
            text = ' → '.join(f'{n["string"]}弦/{n["fret"]}品' + ('（低分待核对）' if n['review'] else '') for n in notes)
            rows.append(f'<tr><td>{bar}</td><td>{len(notes)}</td><td>{esc(text)}</td></tr>')
        sections.append(f'<h2>第 {system["page"]} 页 · {esc(system["id"])}</h2>'
                        f'<img src="digit-ocr/{esc(system["id"])}-boxes.png" alt="数字定位对照">'
                        '<table><tr><th>小节位置</th><th>数字提案数</th><th>弦号 / 品位（从左到右）</th></tr>'
                        + ''.join(rows) + '</table><ul>'
                        + ''.join(f'<li>{esc(v["text"])}：{esc(v["reason"])}</li>' for v in system['unresolved']) + '</ul>')
    (folder / 'review.html').write_text(
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>图片音符对照 · 未生成 GP</title><style>body{font:16px system-ui;max-width:1400px;margin:30px auto;padding:20px;line-height:1.7}'
        'img{max-width:100%}td,th{padding:10px;border-bottom:1px solid #ddd;text-align:left}aside{background:#fff2d6;padding:15px}a{margin-right:20px}</style>'
        f'<h1>{esc(source.name)}</h1><h2>{esc(outcome["status"])}</h2><p>{esc(outcome["message"])}</p>'
        '<aside>当前是数字与弦线识别对照，节奏尚未识别，因此不生成 GP，也不填四分音符占位。'
        '蓝框为数字提案，红框为低 OCR 分数；所有数字仍需核对。小节位置来自检测到的竖线，不能证明完整性。'
        '和弦同时起音、技巧、X 闷音尚未支持；没有报错也不代表没有漏音。</aside>'
        f'<p><a href="{esc(source.as_uri())}">查看原图 / 原文件</a><a href="recognized.json">识别数据</a>'
        + ('<a href="digit-ocr/review.html">详细数字识别报告</a>' if (folder / 'digit-ocr/review.html').exists() else '')
        + ('<a href="image-digits.log">处理日志</a>' if (folder / 'image-digits.log').exists() else '') + '</p>'
        + ''.join(f'<p>{esc(e)}</p>' for e in data.get('errors', [])) + ''.join(sections) + '</html>', encoding='utf-8')
    (folder / 'result.json').write_text(json.dumps(outcome, ensure_ascii=False, indent=2), encoding='utf-8')
