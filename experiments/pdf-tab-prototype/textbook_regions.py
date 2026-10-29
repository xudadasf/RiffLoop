"""Locate paired notation/TAB regions before textbook recognition."""
import json
import uuid
from pathlib import Path

import cv2
import numpy as np

from raster_tab import deskew, gray_image, ink_mask, locate_systems, runs


def locate_regions(gray):
    height, width = gray.shape
    ink = ink_mask(gray)
    horizontal = cv2.morphologyEx(ink, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (max(35, width // 12), 1)))
    _, _, stats, _ = cv2.connectedComponentsWithStats(horizontal)
    columns = [(0, width)]
    long_lines = [s for s in stats[1:] if s[2] > width*.25 and s[3] <= max(5,height*.008)]
    if long_lines:
        columns.append((max(0, int(np.percentile([s[0] for s in long_lines], 10))-10),
                        min(width, int(np.percentile([s[0]+s[2] for s in long_lines], 90))+10)))
    staff_ink = cv2.morphologyEx(ink, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (max(20,width//40),1)))
    for x, y, w, h, area in stats[1:]:
        if w < width * .25 or h > max(5, height * .008):
            continue
        if any(abs(x-a) < width*.025 and abs(x+w-b) < width*.025 for a,b in columns):
            continue
        columns.append((max(0, int(x)-10), min(width, int(x+w)+10)))
    candidates, errors = [], []
    for left, right in columns:
        try:
            systems = locate_systems(gray[:, left:right])
        except ValueError as error:
            errors.append(str(error))
            continue
        for system in systems:
            ys = system['ys']
            gap = float(np.median(np.diff(ys)))
            x0, x1 = left + system['left'], left + system['right']
            if any(abs(ys[0]-r['ys'][0]) < gap and min(x1,r['staff_right'])-max(x0,r['staff_left']) > min(x1-x0,r['staff_right']-r['staff_left'])*.8 for r in candidates):
                continue
            coverage = (staff_ink[:, x0:x1] > 0).sum(axis=1)
            maxima = cv2.dilate(coverage.astype(np.float32).reshape(-1,1), np.ones((5,1),np.uint8)).ravel()
            line_rows = [int(round(np.mean(g))) for g in runs(np.flatnonzero(
                (coverage == maxima) & (coverage > (x1-x0)*.25)))]
            paired, best_support = None, 0
            for first in line_rows:
                if not gap*4 < ys[0]-first < gap*26:
                    continue
                for spacing in np.arange(gap*.65, gap*1.6, .25):
                    five = []
                    for k in range(5):
                        target = round(first+k*spacing)
                        a,b = max(0,target-1),min(height,target+2)
                        five.append(a+int(np.argmax(coverage[a:b])))
                    if min(coverage[y] for y in five) <= (x1-x0)*.25:
                        continue
                    if not gap*1.2 < ys[0]-five[-1] < gap*20:
                        continue
                    # Other TAB rows are not the matching five-line notation.
                    if any(sum(min(abs(y-t) for t in other['ys']) <= 2 for y in five) >= 4 for other in systems):
                        continue
                    # A second six-string diagram is not a five-line staff.
                    fitted_spacing = (five[-1]-five[0])/4
                    extras = [round(five[0]-fitted_spacing), round(five[-1]+fitted_spacing)]
                    if any(2 < y < height-3 and coverage[y-2:y+3].max() > (x1-x0)*.6 for y in extras):
                        continue
                    support = sum(coverage[y] for y in five)
                    if support > best_support:
                        paired, best_support = five, support
            top = max(0, round((paired[0] if paired else ys[0])-gap*8))
            bottom = min(height, round(ys[-1]+gap*5.5))
            accepted = paired is not None
            reason = '六线谱与五线谱配对' if accepted else '未找到配对五线谱，可能是指板图或纯六线谱，未自动采用'
            if np.median(gray[ys[0]:ys[-1]+1,x0:x1]) < 160:
                accepted, reason = False, '局部为深色图文块，未自动采用'
            row_support = sum((staff_ink[max(0,y-2):y+3] > 0).any(axis=0).astype(int) for y in ys)
            sides = [row_support[max(0,round(x0-gap*8)):max(0,round(x0-gap*3))],
                     row_support[min(width,round(x1+gap*3)):min(width,round(x1+gap*8))]]
            if any(np.count_nonzero(side >= 4) > gap*3 for side in sides):
                accepted, reason = False, '谱线可能延伸到框外，存在截断风险，未自动采用'
            candidates.append({'ys': ys, 'staff_left': x0, 'staff_right': x1, 'gap': gap,
                'box': [max(0,round(x0-gap*2)), top, min(width,round(x1+gap*2)), bottom],
                'accepted': accepted, 'systems': 1, 'paired_ys': paired, 'reason': reason})
    candidates.sort(key=lambda r: (r['box'][1],r['box'][0]))
    regions = []
    for region in candidates:
        previous = regions[-1] if regions else None
        if previous and previous['accepted'] and region['accepted']:
            a,b = previous['box'],region['box']
            overlap = min(a[2],b[2])-max(a[0],b[0])
            space = ink[a[3]:b[1],max(a[0],b[0]):min(a[2],b[2])]
            separator = space.size and (space>0).mean(axis=1).max() > .16
            if overlap > min(a[2]-a[0],b[2]-b[0])*.85 and b[1]-a[3] <= 8*region['gap'] and not separator:
                previous['box'] = [min(a[0],b[0]),a[1],max(a[2],b[2]),max(a[3],b[3])]
                previous['systems'] += 1
                continue
        regions.append(region)
    regions = [r for r in regions if not any(
        a is not r and a['accepted'] and a['box'][0] <= r['box'][0] and a['box'][1] <= r['box'][1]
        and a['box'][2] >= r['box'][2] and a['box'][3] >= r['box'][3] for a in regions)]
    return {'regions': regions, 'column_errors': sorted(set(errors))}


def extract_regions(source, folder, stop=None, progress=None):
    """Render every page and retain broad candidates for human confirmation."""
    import fitz
    from PIL import Image, ImageDraw

    source, folder = Path(source).resolve(), Path(folder).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    if any(folder.iterdir()):
        raise ValueError('分区结果目录必须为空，避免覆盖已有文件')
    pages, crops, candidates, error = [], [], 0, ''
    total = 0
    try:
        with fitz.open(source) as document:
            total = len(document)
            for number, page in enumerate(document, 1):
                if stop and stop.is_set():
                    raise InterruptedError('分区已停止；未自动加入识别队列，可查看已完成页面。')
                if progress:
                    progress(f'定位乐谱区域 {number}/{total} 页')
                scale = min(2.5, 2800/page.rect.width, 4000/page.rect.height)
                pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), colorspace=fitz.csGRAY, alpha=False)
                gray, angle = deskew(gray_image(Image.frombytes('L', (pix.width, pix.height), pix.samples)))
                data = locate_regions(gray)
                from textbook_recall import add_recall_candidates
                data['regions'] = add_recall_candidates(gray, data['regions'])
                original = Image.fromarray(gray)
                original_name = f'page-{number:03d}-source.png'
                original.save(folder/original_name)
                preview = original.convert('RGB')
                draw = ImageDraw.Draw(preview)
                for index, region in enumerate(data['regions'], 1):
                    name = f'page-{number:03d}-region-{index:02d}.png'
                    original.crop(region['box']).save(folder/name)
                    region.update(image=name, page=number, index=index)
                    if region['accepted']:
                        crops.append(str(folder/name))
                    else:
                        candidates += 1
                    color = '#15803d' if region['accepted'] else '#d97706'
                    draw.rectangle(region['box'], outline=color, width=4)
                    draw.text((region['box'][0]+5, region['box'][1]+5), str(index), fill=color,
                              stroke_width=1, stroke_fill='white')
                name = f'page-{number:03d}.jpg'
                preview.save(folder/name, quality=88)
                pages.append(dict(data, page=number, preview=name, original=original_name, deskew_degrees=angle,
                                  width=gray.shape[1], height=gray.shape[0]))
    except Exception as caught:
        error = str(caught)
    complete = not error and len(pages) == total
    manifest = {'document_id': uuid.uuid4().hex, 'source': str(source), 'pages': pages, 'total_pages': total, 'complete': complete,
                'default_gap': 1, 'accepted_count': len(crops), 'candidate_count': candidates,
                'coordinate_space': 'deskewed-page-pixels', 'error': error}
    (folder/'regions.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    message = (f'已检查 {len(pages)}/{total} 页，建议采用 {len(crops)} 个区域，另保留 {candidates} 个候选。'
               '请查看分区，补画或重画漏框，确认后保存并导入方案。区域间默认空 1 小节。')
    if error:
        message += ' ' + error
    outcome = {'source': str(source), 'folder': str(folder), 'draft': None,
               'status': '待人工确定分区' if complete else '分区未完成', 'message': message,
               'region_sources': [], 'is_regions': True}
    (folder/'result.json').write_text(json.dumps(outcome, ensure_ascii=False, indent=2), encoding='utf-8')
    write_region_report(folder, manifest, outcome)
    return outcome


def write_region_report(folder, manifest, outcome):
    from region_review import write_editor
    write_editor(folder, manifest, outcome)
