"""Local desktop worker. Keep recognition and strict export unchanged."""
import argparse
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import traceback

ROOT = Path(__file__).resolve().parent
IMAGES = {'.png', '.jpg', '.jpeg', '.webp', '.bmp', '.tif', '.tiff'}
NOTICE = '实验草稿需人工校正。图片优先读取数字与横梁；未知时值使用默认占位并标 ?，修改清单单独保存。技巧、反复与和弦分组仍需核对。'


def default_output():
    return (Path('D:/RiffLoop-model-tests/pdf-tab-desktop') if Path('D:/').exists()
            else Path.home() / 'Documents/RiffLoop-PDF-results')


def create_output(root, source):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    stem = re.sub(r'[^\w\-一-龥]', '_', Path(source).stem)[:55] or 'score'
    return Path(tempfile.mkdtemp(prefix=stem + '-', dir=root))


def write_report(source, folder, outcome, data):
    from desktop_image_review import FORMAT, write_image_review
    if data.get('format') == FORMAT:
        return write_image_review(source, folder, outcome, data)
    esc = lambda value: html.escape(str(value), quote=True)
    from review_page import render_review
    raster = data.get('format') == 'raster-tab-draft-v1'
    sections, total_notes, total_bars, issue_bars = [], 0, 0, 0
    page_lines = {}
    for system in data.get('systems', []):
        page = system["page"]
        page_lines[page] = page_lines.get(page, 0) + 1
        line = page_lines[page]
        rows = []
        for bar in system['bars']:
            notes = sum(len(b['notes']) for b in bar['beats'])
            needs_review = bool(bar.get('issues') or raster)
            issues = '；'.join(bar.get('issues', [])) or ('图片时值为占位，需修改' if raster else '未报告拍数问题；仍需对照原谱')
            groups = ' → '.join(' + '.join(f'{n["string"]}弦/{"X" if n.get("dead") else n["fret"]}品'
                                          for n in beat['notes']) or '休止' for beat in bar['beats'])
            timing = ' → '.join(f'1/{beat["duration"]}' + '.' * beat.get('dots', 0)
                                + (f'（{beat["tuplet"][0]}连音）' if beat.get('tuplet', [1, 1])[0] > 1 else '')
                                for beat in bar['beats'])
            label = f'第{system["page"]}页 · 第{line}行 · 小节{bar["number"]}'
            total_notes += notes
            total_bars += 1
            issue_bars += needs_review
            rows.append(f'<tr class="bar-row" tabindex="-1" data-issue="{int(needs_review)}" data-label="{esc(label)}" data-search="{esc(label)}">'
                        f'<td><span class="bar-label">小节 {bar["number"]}</span><span class="bar-count">{notes} 个音符</span></td>'
                        f'<td class="notes-cell"><div class="note-sequence">{esc(groups)}</div></td>'
                        f'<td class="timing-cell"><div class="timing-sequence">{esc(timing)}</div><p class="issue-text">{esc(issues)}</p></td>'
                        '</tr>')
        sections.append(f'<section class="system-card"><div class="system-heading"><h2>第 {system["page"]} 页 · 第 {line} 行</h2></div>'
                        '<div class="system-body"><div class="table-wrap"><table><thead><tr><th class="measure-col">小节</th><th>音符分组提案</th>'
                        '<th class="timing-col">时值 / 疑点位置</th></tr></thead><tbody>'
                        + ''.join(rows) + '</tbody></table></div></div></section>')
    warnings = data.get('warnings', []) + data.get('structure_issues', [])
    previews = ''
    for page in data.get('page_previews', []):
        if not (folder / page['image']).exists():
            continue
        previews += (f'<details><summary>第 {page["page"]} 页 · 校正图（倾斜 {page["deskew_degrees"]}°）</summary>'
                     f'<img loading="lazy" src="{esc(page["image"])}" alt="第 {page["page"]} 页校正图"></details>')
    for region in data.get('raster_regions', []):
        if not (folder / region['image']).exists():
            continue
        state = '音符提案已生成；请对照下方分组提案逐一检查' if region.get('proposal_ready') else '仅定位到谱行，尚无有效音符提案'
        count = f'模型识别 {region["recognized_bars"]} 小节' if 'recognized_bars' in region else '尚无有效小节提案'
        previews += (f'<section><h3>第 {region["page"]} 页 · {esc(region["id"])} · {count}</h3>'
                     f'<p>{esc(region.get("error", state))}</p>'
                     + (f'<aside>{esc(region["count_warning"])}</aside>' if region.get('count_warning') else '')
                     + f'<details><summary>谱线辅助估计（仅供核对）</summary><p>{region["expected_bars"]} 小节；由竖线检测得到，可能误检或漏检，不作为导出数量要求。</p></details>'
                     f'<img loading="lazy" src="{esc(region["image"])}" alt="检测到的六线谱行"></section>')
    guidance = ('<p>图片草稿按实际输出的小节数保留，不补造小节。小节编号不是完整性证明。箭头为先后分组，加号为同组音符。图片时值为占位，需人工校正。</p>'
                if raster else '<p>打开“原谱识别标记”对照：蓝框是识别到的音符，红框是待核对小节；绿色仅代表拍数合计通过。箭头为先后分组，加号为同组音符。</p>')
    guidance += f'<p>{esc(NOTICE)}</p><p>筛选只包含程序标出的疑点，没有标记的小节也需要人工核对。</p>'
    body = ''.join(f'<p class="error-message">{esc(w)}</p>' for w in warnings) + previews + ''.join(sections)
    if not sections:
        body += '<div class="empty-state">没有可核对的小节。请查看上方处理说明。</div>'
    content = render_review(source, folder, outcome, body, notes=total_notes, bars=total_bars,
                            issues=issue_bars, guidance=guidance)
    (folder / 'review.html').write_text(content, encoding='utf-8')
    (folder / 'result.json').write_text(json.dumps(outcome, ensure_ascii=False, indent=2), encoding='utf-8')


def process_file(source, folder, image_settings=None):
    source, folder = Path(source).resolve(), Path(folder).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    if any(folder.iterdir()):
        raise ValueError('结果目录必须为空，防止覆盖或混入上次结果')
    outcome = {'source': str(source), 'folder': str(folder), 'status': '未生成草稿', 'message': '', 'draft': None}
    data = {}
    try:
        if not source.is_file():
            raise ValueError('原文件不存在或无法读取')
        if source.suffix.lower() in IMAGES:
            from desktop_image_review import recognize_image_review
            data = recognize_image_review(source, folder, image_settings)
        elif source.suffix.lower() != '.pdf':
            raise ValueError('请选择 PDF 或常见图片文件')
        else:
            import fitz
            with fitz.open(source) as doc:
                if doc.needs_pass:
                    raise ValueError('PDF 已加密，请先提供可正常读取的副本')
                from recognize import lines_and_shapes, staves
                raster_pages = [i + 1 for i, page in enumerate(doc) if page.get_images()
                                and not any(s['count'] == 6 for s in staves(lines_and_shapes(page)[0], page.rect.width))]
            if raster_pages:
                from desktop_image_review import recognize_image_review
                data = recognize_image_review(source, folder, image_settings)
            else:
                from recognize import recognize, overlay
                data = recognize(source)
                overlay(source, data, folder / 'overlay.pdf')
        (folder / 'recognized.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
        if data.get('format') == 'raster-digit-review-v1':
            from raster_beam_rhythm import prepare_image_score
            score = prepare_image_score(data, folder / 'digit-ocr')
            (folder / 'recognized.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
            notes = sum(len(s['notes']) for s in data['systems'])
            unresolved = sum(len(s['unresolved']) for s in data['systems'])
            discarded = sum(len(s.get('discarded_bands', [])) for s in data['systems'])
            bars = [b for s in score['systems'] for b in s['bars']]
            if bars and not score['structure_issues']:
                input_path = folder / 'image-score.json'
                input_path.write_text(json.dumps(score, ensure_ascii=False, indent=2), encoding='utf-8')
                node = shutil.which('node')
                if not node:
                    raise ValueError('未找到 Node.js，无法导出 GP；图片识别结果已保留')
                run = subprocess.run([node, str(ROOT / 'gp-draft-export.cjs'), str(input_path),
                                      str(folder / 'score.draft.gp')], capture_output=True, text=True,
                                     encoding='utf-8', errors='replace', timeout=120,
                                     creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
                (folder / 'worker.log').write_text(run.stdout + '\n' + run.stderr, encoding='utf-8')
                if run.returncode:
                    raise ValueError('图片草稿导出失败；识别结果已保留，请查看 worker.log')
                review = json.loads((folder / 'score.draft.gp.review.json').read_text(encoding='utf-8'))
                placeholders = sum(len(b['placeholder_beats']) for b in review['bars'])
                outcome.update(status='图片草稿已生成 · 含占位' if placeholders else '图片草稿已生成 · 待核对',
                               draft=str(folder / 'score.draft.gp'),
                               message=f'{len(bars)} 小节，{notes} 个音符，{placeholders} 处时值/休止占位，{unresolved} 条 OCR 行待核对。'
                                       f'{discarded} 条低分弦带未采用，需检查是否漏音。'
                                       'GP 文件读回与拍数检查通过，不代表音符识别准确；占位标 ?，请对照原图核对。')
            else:
                outcome['message'] = '；'.join(data['errors'] + score['structure_issues']) or '没有定位到可用小节；请查看识别报告。'
            write_report(source, folder, outcome, data)
            from desktop_cleanup import register_intermediates
            register_intermediates(folder)
            return outcome
        bars = [b for s in data['systems'] for b in s['bars']]
        blockers = list(data.get('structure_issues', []))
        if not bars:
            blockers.append('没有识别到可转换的六线谱小节')
        if not data.get('tuning'):
            blockers.append('没有识别到定弦信息（当前需要 Standard tuning）')
        if not data.get('tempo'):
            blockers.append('没有识别到初始速度 BPM')
        if blockers:
            outcome['message'] = '；'.join(blockers) + '。可先查看谱区与问题清单。'
        else:
            node = shutil.which('node')
            if not node:
                raise ValueError('未找到 Node.js，无法导出 GP；识别数据已保留')
            run = subprocess.run([node, str(ROOT / 'gp-draft-export.cjs'), str(folder / 'recognized.json'),
                                  str(folder / 'score.draft.gp')], capture_output=True, text=True,
                                 encoding='utf-8', errors='replace', timeout=120,
                                 creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            (folder / 'worker.log').write_text(run.stdout + '\n' + run.stderr, encoding='utf-8')
            if run.returncode:
                outcome['message'] = '识别已完成，但未满足草稿导出条件。请查看处理日志和谱区。'
            else:
                review = json.loads((folder / 'score.draft.gp.review.json').read_text(encoding='utf-8'))
                raster = data.get('format') == 'raster-tab-draft-v1'
                outcome.update(status='图片草稿 · 全部待校正' if raster else '草稿已生成 · 待校正',
                               draft=str(folder / 'score.draft.gp'),
                               message=f'{len(bars)} 小节，{review["note_count"]} 个音符。已通过保存后读回检查，尚未验证识别准确性。'
                               + ('图片音符可能有误，全部时值为占位；请对照谱区检查。' if raster else ''))
    except Exception as error:
        outcome.update(status='处理失败', message=str(error))
        (folder / 'worker.log').write_text(traceback.format_exc(), encoding='utf-8')
    write_report(source, folder, outcome, data)
    from desktop_cleanup import register_intermediates
    register_intermediates(folder)
    return outcome


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--image-settings', help='JSON: tempo, meter, tuning; optional manual settings, defaults 100 BPM and 4/4, not inferred')
    args = parser.parse_args()
    process_file(args.source, args.out, json.loads(args.image_settings) if args.image_settings else None)
