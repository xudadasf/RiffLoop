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
NOTICE = '待人工校正的实验草稿；节奏可能错误，未知时值使用四分音符占位。延音线、演奏技巧及反复结构未导出。不能直接作为准确伴奏。'


def default_output():
    return (Path('D:/RiffLoop-model-tests/pdf-tab-desktop') if Path('D:/').exists()
            else Path.home() / 'Documents/RiffLoop-PDF-results')


def create_output(root, source):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    stem = re.sub(r'[^\w\-一-龥]', '_', Path(source).stem)[:55] or 'score'
    return Path(tempfile.mkdtemp(prefix=stem + '-', dir=root))


def write_report(source, folder, outcome, data):
    esc = lambda value: html.escape(str(value), quote=True)
    links = [('查看原文件', source.as_uri())]
    for filename, label in [('overlay.pdf', '查看原谱识别标记'), ('score.draft.gp', '打开 / 下载 GP 草稿'),
                            ('score.draft.gp.review.md', '待修改清单'), ('recognized.json', '识别数据'),
                            ('worker.log', '处理日志'), ('image-model.log', '图片模型日志')]:
        if (folder / filename).exists():
            links.append((label, filename))
    raster = data.get('format') == 'raster-tab-draft-v1'
    rows = []
    for system in data.get('systems', []):
        for bar in system['bars']:
            notes = sum(len(b['notes']) for b in bar['beats'])
            issues = '；'.join(bar.get('issues', [])) or '未报告拍数问题；音符、节奏与技巧仍需人工核对'
            groups = ' → '.join(' + '.join(f'{n["string"]}弦/{"X" if n.get("dead") else n["fret"]}品'
                                          for n in beat['notes']) or '休止'
                                for beat in bar['beats'])
            detail = f'<details><summary>查看音符分组提案</summary><p>{esc(groups)}</p></details>' if raster else ''
            rows.append(f'<tr><td>{system["page"]}</td><td>{bar["number"]}</td><td>{notes}</td><td>{esc(issues)}{detail}</td></tr>')
    warnings = data.get('warnings', []) + data.get('structure_issues', [])
    previews = ''
    for page in data.get('page_previews', []):
        previews += (f'<details><summary>第 {page["page"]} 页 · 校正图（倾斜 {page["deskew_degrees"]}°）</summary>'
                     f'<img loading="lazy" src="{esc(page["image"])}" alt="第 {page["page"]} 页校正图"></details>')
    for region in data.get('raster_regions', []):
        state = '音符提案已生成；请对照下方分组提案逐一检查' if region.get('proposal_ready') else '仅定位到谱行，尚无有效音符提案'
        previews += (f'<section><h3>第 {region["page"]} 页 · {esc(region["id"])} · 小节线估计 {region["expected_bars"]} 小节</h3>'
                     f'<p>{esc(region.get("error", state))}</p>'
                     f'<img loading="lazy" src="{esc(region["image"])}" alt="检测到的六线谱行"></section>')
    content = ('<!doctype html><html lang="zh-CN"><meta charset="utf-8">'
               '<meta name="viewport" content="width=device-width,initial-scale=1"><title>六线谱试用结果</title>'
               '<style>body{font:16px "Microsoft YaHei",sans-serif;max-width:1100px;margin:40px auto;padding:0 24px;color:#243247;line-height:1.7}'
               'h1{font-size:28px}aside{background:#fff3db;padding:18px;border-radius:10px}nav{display:flex;flex-wrap:wrap;gap:16px;margin:24px 0}'
               'a{color:#175db7}img{max-width:100%;height:auto;border:1px solid #ddd}section,details{margin:16px 0}table{width:100%;border-collapse:collapse}td,th{padding:10px;border-bottom:1px solid #ddd;text-align:left}pre{white-space:pre-wrap}</style>'
               f'<h1>{esc(source.name)}</h1><h2>{esc(outcome["status"])}</h2><p>{esc(outcome["message"])}</p><aside>{esc(NOTICE)}</aside>'
               '<nav>' + ''.join(f'<a href="{esc(url)}">{esc(label)}</a>' for label, url in links) + '</nav>'
               + ('<p>图片草稿：弦号从最上方 1 弦到最下方 6 弦。箭头为先后分组，加号为同组音符。小节号是本次提案的顺序号。请先检查裁剪谱区有无遗漏；检测到定位失败或小节数量不一致时，不导出整份 GP。</p>' if raster else '<p>蓝框：识别到的音符；红框：待核对小节。绿色仅代表拍数合计通过。</p>') + '<ul>'
               + ''.join(f'<li>{esc(w)}</li>' for w in warnings) + '</ul>'
               + previews + '<table><tr><th>页</th><th>小节</th><th>音符数</th><th>待核对内容</th></tr>' + ''.join(rows) + '</table></html>')
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
            from raster_tab import recognize_raster
            data = recognize_raster(source, folder, image_settings)
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
                from raster_tab import recognize_raster
                data = recognize_raster(source, folder, image_settings)
            else:
                from recognize import recognize, overlay
                data = recognize(source)
                overlay(source, data, folder / 'overlay.pdf')
        (folder / 'recognized.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
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
    return outcome


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--image-settings', help='JSON: tempo, meter, tuning; explicit draft settings, not inferred')
    args = parser.parse_args()
    process_file(args.source, args.out, json.loads(args.image_settings) if args.image_settings else None)
