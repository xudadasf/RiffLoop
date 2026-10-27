"""Image-only six-string TAB draft pipeline; no PDF text or reference GP inputs.

The pinned local OMR model is a proposal generator, not an accuracy check.
Every duration is explicitly replaced by an unknown-rhythm placeholder.
"""
import copy
import json
import math
import os
from pathlib import Path
import subprocess

import cv2
import numpy as np
from PIL import Image, ImageOps, ImageSequence

from evaluate_model_probe import parse_tokens

ROOT = Path(__file__).resolve().parent
DEFAULT_MODEL = Path('D:/RiffLoop-model-tests/pdf-tab-prototype/local-model-20261026')
DEFAULT_SETTINGS = {'tempo': 100, 'meter': [4, 4], 'tuning': [64, 59, 55, 50, 45, 40]}


def validate_settings(settings):
    settings = copy.deepcopy(DEFAULT_SETTINGS if settings is None else settings)
    tempo, meter, tuning = (settings.get(k) for k in ('tempo', 'meter', 'tuning'))
    if type(tempo) is not int or not 20 <= tempo <= 400:
        raise ValueError('图片草稿 BPM 必须为 20–400 的整数')
    if not isinstance(meter, list) or len(meter) != 2 or any(type(n) is not int for n in meter) or not 1 <= meter[0] <= 32 or meter[1] not in (1, 2, 4, 8, 16, 32):
        raise ValueError('图片草稿拍号无效，例如 4/4 或 6/8')
    if not isinstance(tuning, list) or len(tuning) != 6 or any(type(n) is not int or not 0 <= n <= 127 for n in tuning):
        raise ValueError('图片草稿定弦需六个 MIDI 音高，按最高弦到最低弦排列')
    return settings


def gray_image(image):
    image = ImageOps.exif_transpose(image)
    if image.mode in ('RGBA', 'LA') or 'transparency' in image.info:
        rgba = image.convert('RGBA')
        base = Image.new('RGBA', rgba.size, 'white')
        image = Image.alpha_composite(base, rgba)
    image = image.convert('L')
    image.thumbnail((2800, 4000), Image.Resampling.LANCZOS)
    array = np.asarray(image)
    if min(array.shape) < 60:
        raise ValueError('图片过小，请使用清晰原图')
    if max(array.shape) < 1500:
        scale = min(2.0, 1500 / max(array.shape))
        array = cv2.resize(array, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
    # Screenshots with a dark background are normalized only when most pixels
    # are dark, not based on the color of an individual note.
    if np.median(array) < 100:
        array = 255 - array
    return array


def ink_mask(gray):
    return cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                 cv2.THRESH_BINARY_INV, 41, 12)


def deskew(gray):
    edges = cv2.Canny(gray, 50, 150)
    width = gray.shape[1]
    lines = cv2.HoughLinesP(edges, 1, np.pi / 720, threshold=max(40, width // 12),
                            minLineLength=max(60, width // 6), maxLineGap=width // 60)
    angles = []
    if lines is not None:
        for x0, y0, x1, y1 in lines[:, 0]:
            angle = math.degrees(math.atan2(y1 - y0, x1 - x0))
            if abs(angle) <= 12:
                angles.append(angle)
    angle = float(np.median(angles)) if angles else 0.0
    if abs(angle) < .12:
        return gray, 0.0
    h, w = gray.shape
    matrix = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1)
    c, s = abs(matrix[0, 0]), abs(matrix[0, 1])
    new_w, new_h = math.ceil(h * s + w * c), math.ceil(h * c + w * s)
    matrix[0, 2] += (new_w - w) / 2
    matrix[1, 2] += (new_h - h) / 2
    return cv2.warpAffine(gray, matrix, (new_w, new_h), flags=cv2.INTER_CUBIC, borderValue=255), round(angle, 3)


def runs(indices):
    groups = []
    for index in indices:
        index = int(index)
        if groups and index <= groups[-1][-1] + 1:
            groups[-1].append(index)
        else:
            groups.append([index])
    return groups


def locate_systems(gray):
    """Find six evenly spaced long lines in pixels, excluding five-line staves."""
    ink = ink_mask(gray)
    h, w = ink.shape
    horizontal = cv2.morphologyEx(ink, cv2.MORPH_OPEN,
                                  cv2.getStructuringElement(cv2.MORPH_RECT, (max(20, w // 40), 1)))
    row_coverage = (horizontal > 0).sum(axis=1)
    row_groups = runs(np.flatnonzero(row_coverage > max(65, w * .20)))
    # A thick beam may touch a string and make its row band asymmetric. The
    # longest horizontal row locates the string; a band average drifts toward
    # the shorter beam and can reject a perfectly ordinary six-line staff.
    rows = [int(round(np.mean([y for y in g if row_coverage[y] == max(row_coverage[g])]))) for g in row_groups]
    found = []
    used = set()
    for start in range(len(rows) - 5):
        ys = rows[start:start + 6]
        gaps = np.diff(ys)
        gap = float(np.median(gaps))
        if gap < 5 or gap > 65 or np.max(np.abs(gaps - gap)) > max(2, gap * .18):
            continue
        if any(y in used for y in ys):
            continue
        # A seven-line table or larger grid must not become six-string TAB.
        if start > 0 and abs(ys[0] - rows[start - 1] - gap) < gap * .18:
            continue
        if start + 6 < len(rows) and abs(rows[start + 6] - ys[-1] - gap) < gap * .18:
            continue
        coverage = np.zeros(w, dtype=np.int32)
        for y in ys:
            coverage += (horizontal[max(0, y - 2):y + 3].max(axis=0) > 0)
        xs = np.flatnonzero(coverage >= 4)
        if not len(xs):
            continue
        left, right = int(xs[0]), int(xs[-1])
        if right - left < max(100, gap * 12):
            continue
        # Five-line notation with scattered ledger lines must not become TAB.
        # Every one of the six strings needs substantial horizontal support.
        supports = [(horizontal[max(0,y-2):y+3,left:right+1].max(axis=0)>0).mean() for y in ys]
        if min(supports) < .5:
            continue
        # Do not silently join side-by-side columns into one musical system.
        missing = runs(np.flatnonzero(coverage[left:right + 1] < 2))
        if any(len(g) > gap * 6 for g in missing):
            raise ValueError('检测到并排谱区或较大断裂，请按一列/一行裁剪后分别加入')
        top, bottom = max(0, round(ys[0] - gap * 4)), min(h, round(ys[-1] + gap * 5.5))
        # Clip off a neighboring standard staff without using its contents.
        earlier = [y for y in rows[:start] if top < y < ys[0] - gap]
        if earlier:
            top = max(top, round(earlier[-1] + gap * .65))
        crop = [max(0, left - 8), top, min(w, right + 9), bottom]
        # Bar boundaries require an almost continuous full-height ink stroke.
        span = ink[ys[0]:ys[-1] + 1, left:right + 1] > 0
        vertical = np.flatnonzero(span.mean(axis=0) > .88) + left
        bounds = [float(np.mean(g)) for g in runs(vertical)]
        # The right edge is itself a boundary: use the same double-line
        # tolerance as internal boundaries, or an end double bar adds a sliver.
        bounds = [x for x in bounds if left + gap * 1.5 < x < right - gap * .8]
        straight = []
        for x in bounds:
            center = round(x)
            radius = max(2, round(gap * .25))
            # Note stems extend below the TAB; a measure line stops at its
            # bottom string. Do not count those stems as extra measures.
            below = ink[ys[-1] + round(gap * .3):min(h, ys[-1] + round(gap * 1.7)),
                        center - 1:center + 2]
            if below.size and (below.max(axis=1) > 0).mean() > .45:
                continue
            centers = []
            for a, b in zip(ys, ys[1:]):
                y = round((a + b) / 2)
                occupied = np.flatnonzero(ink[y, center - radius:center + radius + 1])
                if not len(occupied):
                    break
                centers.append(float(np.mean(occupied)))
            # Arpeggio waves can have high vertical coverage too; require a
            # straight center across all five inter-string spaces.
            if len(centers) == 5 and max(centers) - min(centers) <= max(1.2, gap * .08):
                straight.append(x)
        bounds = straight
        # Double/repeat bars are one boundary, not a narrow extra measure.
        merged = []
        for x in bounds:
            if merged and x - merged[-1] < gap * .8:
                merged[-1] = (merged[-1] + x) / 2
            else:
                merged.append(x)
        found.append({'ys': ys, 'left': left, 'right': right, 'crop': crop,
                      'bar_boundaries': [left] + merged + [right], 'expected_bars': len(merged) + 1})
        used.update(ys)
    return found


def raster_pages(source):
    """PDF path uses rendered pixels only, including for mixed documents."""
    if source.suffix.lower() == '.pdf':
        import fitz
        with fitz.open(source) as doc:
            if doc.needs_pass:
                raise ValueError('PDF 已加密')
            if len(doc) > 40:
                raise ValueError('图片识别每次最多 40 页，请拆分后处理')
            for page in doc:
                scale = min(2.5, 2800 / page.rect.width, 4000 / page.rect.height)
                pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), colorspace=fitz.csGRAY, alpha=False)
                yield gray_image(Image.frombytes('L', (pix.width, pix.height), pix.samples))
    else:
        with Image.open(source) as image:
            if getattr(image, 'n_frames', 1) > 40:
                raise ValueError('图片识别每次最多 40 页，请拆分后处理')
            for frame in ImageSequence.Iterator(image):
                yield gray_image(frame.copy())


def decode_proposal(prediction):
    if not prediction.get('eos') or not prediction.get('upstream_structure_valid'):
        raise ValueError('模型输出未完整结束或结构无效，请裁成较短的谱行后重试')
    bars = parse_tokens(prediction['tokens'])
    for beats in bars:
        for beat in beats:
            if any(n['fret'] is not None and not 0 <= n['fret'] <= 36 for n in beat['notes']):
                raise ValueError('模型输出了超出范围的品位')
            # Timing is not accepted from the model. Existing exporter marks
            # every None duration as a quarter placeholder, including rests.
            beat.update(duration=None, dots=0, tuplet=[1, 1], grace=False)
            for note in beat['notes']:
                note['tie'] = False
    return bars


def recognize_raster(source, folder, settings=None):
    settings = validate_settings(settings)
    folder = Path(folder)
    assets = folder / 'images'
    assets.mkdir()
    data = {'input': str(source), 'format': 'raster-tab-draft-v1', **settings,
            'settings_source': 'manual-draft-settings', 'systems': [], 'structure_issues': [],
            'warnings': ['图片模型仅提供待校正提案，可能漏音、错弦、错品或错分组；所有音符须对照原图。',
                         '所有时值均标为未知并用四分音符占位；未识别休止时长、延音、技巧、反复结构与变速。',
                         f'BPM {settings["tempo"]}、拍号 {settings["meter"][0]}/{settings["meter"][1]}、定弦 {settings["tuning"]} 来自窗口草稿设置，非图片识别。',
                         '小节按检测到的谱行从上到下顺序编号，非原谱印刷编号；请检查谱区遗漏及阅读顺序。'],
            'page_previews': [], 'raster_regions': []}
    manifest, regions = [], []
    for page, gray in enumerate(raster_pages(Path(source)), 1):
        corrected, angle = deskew(gray)
        page_path = assets / f'page-{page:03d}.png'
        Image.fromarray(corrected).save(page_path)
        preview = {'page': page, 'image': page_path.relative_to(folder).as_posix(), 'deskew_degrees': angle}
        data['page_previews'].append(preview)
        try:
            systems = locate_systems(corrected)
        except ValueError as error:
            systems = []
            data['structure_issues'].append(f'第 {page} 页：{error}')
        if not systems:
            data['structure_issues'].append(f'第 {page} 页没有可靠定位到六条谱线；请裁剪谱区、转正并使用清晰图片后重试')
        for index, system in enumerate(systems, 1):
            clip_id = f'page-{page:03d}-system-{index:03d}'
            path = assets / f'{clip_id}.png'
            x0, y0, x1, y1 = system['crop']
            Image.fromarray(corrected[y0:y1, x0:x1]).save(path)
            manifest.append({'id': clip_id, 'image': str(path.resolve())})
            region = {**system, 'id': clip_id, 'page': page, 'image': path.relative_to(folder).as_posix()}
            regions.append(region)
    data['pages'] = len(data['page_previews'])
    data['raster_regions'] = regions
    manifest_path = folder / 'image-manifest.json'
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    (folder / 'image-regions.json').write_text(json.dumps(regions, ensure_ascii=False, indent=2), encoding='utf-8')
    if not manifest:
        return data
    model_dir = Path(os.environ.get('RIFFLOOP_OMR_MODEL_DIR', str(DEFAULT_MODEL)))
    runtime = model_dir / '.venv/Scripts/python.exe'
    if not runtime.is_file() or not (model_dir / 'best.pt').is_file():
        data['structure_issues'].append('未找到本地图片识谱模型及运行环境；可通过 RIFFLOOP_OMR_MODEL_DIR 指定已安装模型目录')
        return data
    predictions_path = folder / 'image-predictions.json'
    # Existing runner verifies pinned weights/source hashes and loads weights
    # safely. It has no GP reference input and disables extra model downloads.
    with (folder / 'image-model.log').open('w', encoding='utf-8') as log:
        try:
            run = subprocess.run([str(runtime), str(ROOT / 'local_model_probe.py'), '--model-dir', str(model_dir),
                                  '--manifest', str(manifest_path), '--output', str(predictions_path), '--constrained'],
                                 stdout=log, stderr=log, timeout=600,
                                 creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            if run.returncode:
                raise ValueError('图片模型运行失败，请查看 image-model.log')
        except (subprocess.TimeoutExpired, ValueError) as error:
            data['structure_issues'].append(str(error))
            return data
    predictions = json.loads(predictions_path.read_text(encoding='utf-8'))
    data['model_revision'] = predictions['model_revision']
    data['model_checkpoint_sha256'] = predictions['checkpoint_sha256']
    by_id = {p['id']: p for p in predictions['predictions']}
    number = 0
    for region in regions:
        try:
            proposal = decode_proposal(by_id[region['id']])
        except (ValueError, KeyError) as error:
            region['error'] = str(error)
            data['structure_issues'].append(f'{region["id"]}：{error}')
            number += region['expected_bars']
            continue
        region['recognized_bars'] = len(proposal)
        count_issues = []
        if len(proposal) != region['expected_bars']:
            warning = (f'小节数量待核对：模型识别 {len(proposal)} 小节，谱线辅助估计 {region["expected_bars"]} 小节。'
                       '已按模型内容保留草稿，没有补造或删除小节；请检查漏识别、合并或误分。')
            region['count_warning'] = warning
            data['warnings'].append(f'{region["id"]}：{warning}')
            count_issues.append(warning)
        bars = []
        for beats in proposal:
            number += 1
            bars.append({'number': number, 'meter': settings['meter'], 'meter_source': 'manual-draft-settings',
                         'tempo': settings['tempo'], 'beats': beats,
                         'issues': ['图片模型提案：须核对音符、弦号、品位与分组；全部时值为四分音符占位；拍号和速度为人工设置'] + count_issues})
        region['proposal_ready'] = True
        data['systems'].append({**region, 'bars': bars})
    return data
