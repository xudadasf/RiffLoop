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
    from review_page import render_review
    esc = lambda value: html.escape(str(value), quote=True)
    settings = data['manual_settings']
    setting_text = f'BPM {settings["tempo"]} · 拍号 {settings["meter"][0]}/{settings["meter"][1]}（人工设置，不是图片识别值）'
    sections, total_notes, total_bars, issue_bars = [], 0, 0, 0
    page_lines = {}
    for system in data.get('systems', []):
        page = system["page"]
        page_lines[page] = page_lines.get(page, 0) + 1
        line = page_lines[page]
        rows = []
        unresolved = system.get('unresolved', [])
        discarded = system.get('discarded_bands', [])
        for bar in range(1, system['region']['expected_bars'] + 1):
            notes = [n for n in system['notes'] if n['bar'] == bar]
            chips = []
            for n in notes:
                review = bool(n.get('review'))
                chips.append(f'<span class="note-chip{ " needs-review" if review else ""}">{esc(n["string"])}弦 / {esc(n["fret"])}品{ " · 待核对" if review else ""}</span>')
            text = '<span class="sequence-arrow">→</span>'.join(chips) or '<span class="bar-count">未提取到音符，请对照原谱确认休止或漏音</span>'
            rhythm = next((b for b in system.get('rhythm_bars', []) if b['source_bar'] == bar), None)
            timing = []
            for beat in rhythm['beats'] if rhythm else []:
                token = ('休止 ' if not beat['notes'] else '') + f'1/{beat["duration"]}' + '.'*beat['dots']
                if beat.get('tuplet', [1, 1])[0] > 1:
                    token += f'（{beat["tuplet"][0]}连音）'
                token += ' ?' if beat['placeholder'] else ''
                timing.append(esc(token))
            issues = list(rhythm['issues']) if rhythm else ['未得到可用时值']
            placeholders = sum(bool(b.get('placeholder')) for b in rhythm['beats']) if rhythm else 0
            if placeholders and not issues:
                issues.append(f'{placeholders} 处默认占位，需对照原谱修改')
            needs_review = bool(issues or placeholders or any(n.get('review') for n in notes) or unresolved or discarded)
            total_notes += len(notes)
            total_bars += 1
            issue_bars += needs_review
            label = f'第{system["page"]}页 · 第{line}行 · 小节{bar}'
            issue_html = '<ul class="issue-text">'+''.join(f'<li>{esc(i)}</li>' for i in issues)+'</ul>' if issues else ''
            rows.append(f'<tr class="bar-row" tabindex="-1" data-issue="{int(needs_review)}" data-label="{esc(label)}" data-search="{esc(label)}">'
                        f'<td><span class="bar-label">小节 {bar}</span><span class="bar-count">{len(notes)} 个音符</span></td>'
                        f'<td class="notes-cell"><div class="note-sequence">{text}</div></td>'
                        f'<td class="timing-cell"><div class="timing-sequence">{" → ".join(timing) or "未得到可用时值"}</div>{issue_html}</td>'
                        '</tr>')
        preview_path = f'digit-ocr/{system["id"]}-boxes.png'
        preview = (f'<button type="button" class="preview-open" data-preview="{esc(preview_path)}" data-preview-label="第 {system["page"]} 页 · 第 {line} 行谱图" aria-label="放大第 {page} 页第 {line} 行谱图">'
                   f'<img loading="lazy" src="{esc(preview_path)}" alt="数字定位对照"></button><p class="preview-caption">点击谱图放大 · 蓝框为数字提案，红框为待核对提案</p>'
                   if (folder/preview_path).exists() else '<p class="missing-preview">谱图预览不可用，可能已清理；可打开原文件对照音符记录。</p>')
        alerts = ('<div class="system-alert"><strong>本行还有未确认内容，请检查是否漏音</strong><ul>'
                  + ''.join(f'<li>{esc(v["text"])}：{esc(v["reason"])}</li>' for v in unresolved) + '</ul>'
                  + f'<details><summary>未采用的弱证据弦带：{len(discarded)} 条</summary><ul>'
                  + ''.join(f'<li>{esc(v["row"])}：{esc(v["text"])}；{esc(v["reason"])}</li>' for v in discarded)
                  + '</ul></details></div>') if unresolved or discarded else ''
        sections.append(f'<section class="system-card"><div class="system-heading"><h2>第 {system["page"]} 页 · 第 {line} 行</h2>'
                        f'<small>{system["region"]["expected_bars"]} 个小节位置 · 按原图顺序展示</small></div><div class="system-body">'
                        + preview + alerts + '<div class="table-wrap"><table><thead><tr><th class="measure-col">小节</th><th>弦号 / 品位 · 从左到右</th><th class="timing-col">时值 / 待修改</th></tr></thead><tbody>'
                        + ''.join(rows) + '</tbody></table></div></div></section>')
    body = ''.join(f'<p class="error-message">{esc(e)}</p>' for e in data.get('errors', [])) + ''.join(sections)
    if not sections:
        body += '<div class="empty-state">没有可核对的谱行。请先查看上方说明，或换用更清晰、保留六条谱线的图片。</div>'
    guidance = ('<p>先对照谱图检查弦号、品位和顺序，再在 GP 编辑软件中修改时值。小节位置由竖线检测得到，不能证明完整性。</p>'
                '<p>明确连接的横梁用于识别时值；不确定处使用默认占位，谱中标 ?。默认四分音符，空间不足时统一缩短，余量用休止占位。</p>'
                '<p>BPM 决定播放速度，拍号决定小节拍数；两者不能替代每个音符的时值。和弦同时起音、技巧、X 闷音尚未支持；没有报错也不代表没有漏音。</p>'
                '<p>“仅有待修改项”筛选的是程序已标出的疑点；未标出的音符也需要人工核对。</p>')
    content = render_review(source, folder, outcome, body, notes=total_notes, bars=total_bars,
                            issues=issue_bars, settings=setting_text, guidance=guidance)
    (folder/'review.html').write_text(content, encoding='utf-8')
    (folder/'result.json').write_text(json.dumps(outcome, ensure_ascii=False, indent=2), encoding='utf-8')
