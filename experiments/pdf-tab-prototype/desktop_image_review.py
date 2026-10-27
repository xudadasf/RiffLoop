"""Image entry point and review: retain digit and rhythm evidence plus defaults."""
import html
import json
import os
from pathlib import Path
import subprocess

from raster_tab import DEFAULT_SETTINGS, deskew, locate_systems, raster_pages, validate_settings

from raster_image_quality import condition_page

ROOT = Path(__file__).resolve().parent
BASE = Path('D:/RiffLoop-model-tests/raster-tab-20261027')
FORMAT = 'raster-digit-review-v1'


def recognize_image_review(source, folder, settings=None):
    manual = validate_settings({**DEFAULT_SETTINGS, **(settings or {})})
    result = {'format': FORMAT, 'systems': [], 'errors': [], 'manual_settings': manual,
              'settings_source': 'manual/default; not recognized from image'}
    # Avoid starting the OCR runtime for blank/unsupported pages. Do not silently
    # skip a page in a mixed document and present the remaining pages as complete.
    for page, gray in enumerate(raster_pages(source), 1):
        try:
            gray, _ = condition_page(gray)
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
    settings = data['manual_settings']
    setting_text = f'BPM {settings["tempo"]} · 拍号 {settings["meter"][0]}/{settings["meter"][1]}'
    sections = []
    for system in data.get('systems', []):
        rows = []
        for bar in range(1, system['region']['expected_bars'] + 1):
            notes = [n for n in system['notes'] if n['bar'] == bar]
            text = ' → '.join(f'{n["string"]}弦/{n["fret"]}品' + ('（待核对）' if n['review'] else '') for n in notes)
            rhythm = next((b for b in system.get('rhythm_bars', []) if b['source_bar'] == bar), None)
            timing = ' → '.join(('休止 ' if not b['notes'] else '') + f'1/{b["duration"]}'
                                + '.'*b['dots'] + (' ?' if b['placeholder'] else '') for b in rhythm['beats']) if rhythm else '未得到可用时值'
            issues = '<br>'.join(esc(i) for i in rhythm['issues']) if rhythm else ''
            rows.append(f'<tr><td>{bar}</td><td>{len(notes)}</td><td>{esc(text)}</td><td>{esc(timing)}<br>{issues}</td></tr>')
        preview = (f'<img src="digit-ocr/{esc(system["id"])}-boxes.png" alt="数字定位对照">'
                   if (folder/'digit-ocr'/f'{system["id"]}-boxes.png').exists() else '<p>中间图片已清理；音符记录和 GP 保留，可打开原图核对。</p>')
        sections.append(f'<h2>第 {system["page"]} 页 · {esc(system["id"])}</h2>' + preview +
                        '<table><tr><th>小节位置</th><th>数字提案数</th><th>弦号 / 品位（从左到右）</th><th>时值 / 待修改</th></tr>'
                        + ''.join(rows) + '</table><ul>'
                        + ''.join(f'<li>{esc(v["text"])}：{esc(v["reason"])}</li>' for v in system['unresolved']) + '</ul>'
                        + f'<details><summary>未采用的弱证据弦带：{len(system.get("discarded_bands", []))} 条（需检查是否漏音）</summary><ul>'
                        + ''.join(f'<li>{esc(v["row"])}：{esc(v["text"])}；{esc(v["reason"])}</li>' for v in system.get('discarded_bands', [])) + '</ul></details>')
    (folder / 'review.html').write_text(
        '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>图片 GP 草稿与识别对照</title><style>body{font:16px system-ui;max-width:1400px;margin:30px auto;padding:20px;line-height:1.7}'
        'img{max-width:100%}td,th{padding:10px;border-bottom:1px solid #ddd;text-align:left}aside{background:#fff2d6;padding:15px}a{margin-right:20px}</style>'
        f'<h1>{esc(source.name)}</h1><h2>{esc(outcome["status"])}</h2><p>{esc(outcome["message"])}</p>'
        f'<p><strong>{esc(setting_text)}</strong>（人工设置；不是图片识别值）。'
        'BPM 决定播放速度，拍号决定小节拍数；两者不能替代每个音符的时值。</p>'
        '<aside>明确连接的横梁用于识别时值；不确定处使用默认占位，谱中标 ?，请人工修改。'
        '默认四分音符；空间不足时统一缩短，剩余时值用休止占位。不会将占位说成已识别。'
        '蓝框为数字提案，红框为低分或裁剪位置重试的提案；所有数字仍需核对。小节位置来自检测到的竖线，不能证明完整性。'
        '和弦同时起音、技巧、X 闷音尚未支持；没有报错也不代表没有漏音。</aside>'
        f'<p><a href="{esc(source.as_uri())}">查看原图 / 原文件</a><a href="recognized.json">识别数据</a>'
        + ('<a href="score.draft.gp">打开 / 下载 GP 草稿</a><a href="score.draft.gp.review.md">待修改清单</a>' if outcome.get('draft') else '')
        + ('<a href="worker.log">GP 导出日志</a>' if (folder / 'worker.log').exists() else '')
        + ('<a href="note-verification.json">本次另行完成的音符核对记录</a>' if (folder / 'note-verification.json').exists() else '')
        + ('<a href="digit-ocr/review.html">详细数字识别报告</a>' if (folder / 'digit-ocr/review.html').exists() else '')
        + ('<a href="image-digits.log">处理日志</a>' if (folder / 'image-digits.log').exists() else '') + '</p>'
        + ''.join(f'<p>{esc(e)}</p>' for e in data.get('errors', [])) + ''.join(sections) + '</html>', encoding='utf-8')
    (folder / 'result.json').write_text(json.dumps(outcome, ensure_ascii=False, indent=2), encoding='utf-8')
