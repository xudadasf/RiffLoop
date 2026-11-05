"""Read simple beamed TAB rhythms; retain evidence and mark every fallback.

Only the image and manual meter are inputs. Manual meter validates durations;
it is never used as evidence that a duration was recognized from the image.
"""
from fractions import Fraction

import cv2
import numpy as np

from raster_tab import CUT_OFF_WARNING


def read_beamed_notes(gray, notes, region):
    gap = float(np.median(np.diff(region['ys'])))
    ink = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                               cv2.THRESH_BINARY_INV, 31, 10)
    horizontal = cv2.morphologyEx(ink, cv2.MORPH_OPEN,
                                 cv2.getStructuringElement(cv2.MORPH_RECT, (max(8, round(gap*1.1)), 1)))
    beams = cv2.morphologyEx(horizontal, cv2.MORPH_OPEN,
                           cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(3, round(gap*.4)))))
    _, _, stats, _ = cv2.connectedComponentsWithStats(beams)
    segments = [dict(x=int(x), y=int(y), w=int(w), h=int(h)) for x, y, w, h, _ in stats[1:]
                if w >= gap*1.1 and gap*.3 <= h <= gap*.85]
    result = []
    for note in notes:
        x = note['x'] - region['crop'][0]
        box = np.asarray(note['box'])
        top, bottom = float(box[:, 1].min()), float(box[:, 1].max())
        matches = []
        for direction in ('up', 'down'):
            eligible = [s for s in segments if s['x']-gap*.4 <= x <= s['x']+s['w']-1+gap*.4
                        and ((top-gap*4 <= s['y'] and s['y']+s['h'] <= top+gap*.15) if direction == 'up'
                             else (s['y'] >= bottom-gap*.15 and s['y']+s['h'] <= bottom+gap*4))]
            eligible.sort(key=lambda s: s['y'], reverse=direction == 'up')
            if not eligible:
                continue
            group = [eligible[0]]
            for segment in eligible[1:]:
                separation = abs((segment['y']+segment['h']/2) - (group[-1]['y']+group[-1]['h']/2))
                if not gap*.55 <= separation <= gap*1.4:
                    break
                group.append(segment)
            if len(group) > 3:
                continue
            far = group[-1]['y'] + group[-1]['h']/2
            near = top if direction == 'up' else bottom
            y0, y1 = sorted((round(far), round(near)))
            if y1-y0 < gap*.7:
                continue
            best = (0, None)
            for stem_x in range(max(0, round(x-gap*.3)), min(gray.shape[1], round(x+gap*.3)+1)):
                column = ink[max(0, y0):min(gray.shape[0], y1+1), stem_x] > 0
                coverage = float(column.mean()) if len(column) else 0
                if coverage > best[0]:
                    best = coverage, stem_x
            if best[0] >= .68 and all(s['x']-gap*.2 <= best[1] <= s['x']+s['w']-1+gap*.2 for s in group):
                matches.append({'duration': 4 * 2**len(group),
                                'evidence': {'beam_count': len(group), 'direction': direction,
                                             'beam_boxes': group, 'stem_x': best[1], 'stem_coverage': round(best[0], 6)}})
        result.append(matches[0] if len(matches) == 1 else
                      {'duration': None, 'reason': '符干/横梁证据不足或方向存在歧义'})
    # A partly broken stem is accepted only if another distinct note in the
    # same bar has a strong stem connected to precisely the same beam group.
    for index, reading in enumerate(result):
        evidence = reading.get('evidence')
        if not evidence or evidence['stem_coverage'] >= .72:
            continue
        supported = any(
            other != index and notes[other]['bar'] == notes[index]['bar']
            and abs(notes[other]['x']-notes[index]['x']) >= gap*.7
            and candidate.get('duration') == reading['duration']
            and candidate.get('evidence', {}).get('stem_coverage', 0) >= .72
            and candidate['evidence']['direction'] == evidence['direction']
            and candidate['evidence']['beam_boxes'] == evidence['beam_boxes']
            for other, candidate in enumerate(result))
        if supported:
            reading['review_reason'] = '符干较弱，依据同组横梁辅助识别，需对照原谱'
        else:
            result[index] = {'duration': None, 'reason': '符干较弱且缺少同组横梁的可靠佐证'}
    return result


def read_plain_stems(gray, notes, region, readings):
    """Offer reviewable quarter notes only for isolated, unmarked stems."""
    if 'bar_boundaries' not in region:
        return readings
    gap = float(np.median(np.diff(region['ys'])))
    ink = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                               cv2.THRESH_BINARY_INV, 31, 10)
    vertical = cv2.morphologyEx(ink, cv2.MORPH_OPEN,
        cv2.getStructuringElement(cv2.MORPH_RECT, (1, round(gap*1.4))))
    _, _, stats, _ = cv2.connectedComponentsWithStats(vertical)
    result = list(readings)
    for index, (note, reading) in enumerate(zip(notes, readings)):
        if reading['duration'] is not None:
            continue
        x = note['x']-region['crop'][0]
        bottom = float(np.asarray(note['box'])[:,1].max())
        matches = []
        for xx, yy, width, height, _ in stats[1:]:
            mid, end = xx+(width-1)/2, yy+height-1
            if width > gap*.4 or abs(mid-x) > gap*.35 or height < gap*1.8:
                continue
            if not (bottom-gap*.55 <= yy <= bottom+gap*.7 and end > bottom+gap*1.5
                    and end > region['ys'][-1]-region['crop'][1]+gap*.4):
                continue
            y0, y1 = max(0,round(end-gap*1.1)), min(gray.shape[0],round(end+gap*.4))
            x0, x1 = max(0,round(mid-gap*1.1)), min(gray.shape[1],round(mid+gap*1.1))
            left = ink[y0:y1,x0:max(x0,round(mid-gap*.25))]
            right = ink[y0:y1,min(x1,round(mid+gap*.25)):x1]
            if not left.size or not right.size or (left>0).mean() >= .01 or (right>0).mean() >= .01:
                continue
            bar = note['bar']
            bar_left = max(0,round(region['bar_boundaries'][bar-1]-region['crop'][0]))
            bar_right = min(gray.shape[1],round(region['bar_boundaries'][bar]-region['crop'][0]))
            under = ink[min(gray.shape[0],round(end+gap*.35)):min(gray.shape[0],round(end+gap*2)),bar_left:bar_right]
            if under.size:
                horizontal = cv2.morphologyEx(under, cv2.MORPH_OPEN,
                    cv2.getStructuringElement(cv2.MORPH_RECT, (max(8,round(gap*1.5)),1)))
                if np.any(horizontal):
                    continue
            matches.append({'stem_box':[int(xx),int(yy),int(width),int(height)], 'direction':'down'})
        if len(matches) == 1:
            result[index] = {'duration':4, 'source':'image-stem', 'evidence':matches[0],
                             'review_reason':'仅检测到独立符干，需核对四分时值、附点和连音'}
    return result


def validate_bar_timing(durations, meter):
    if not durations or any(d not in (1, 2, 4, 8, 16, 32, 64) for d in durations):
        return '存在未确定的音符时值'
    actual = sum((Fraction(4, d) for d in durations), Fraction())
    expected = Fraction(meter[0]*4, meter[1])
    return None if actual == expected else f'时值合计 {actual} 拍，与拍号要求 {expected} 拍不符'


def fill_bar(notes, readings, meter):
    """Preserve supported readings; use explicit defaults without overflowing.

    Unknowns default to a quarter note, shortened uniformly if necessary to fit
    the remaining measure. Any remaining time becomes marked rest placeholders.
    Conflicting total duration resets this bar's timing to marked defaults.
    """
    expected = Fraction(meter[0]*4, meter[1])
    values = [r['duration'] for r in readings]
    known = sum((Fraction(4, d) for d in values if d), Fraction())
    missing = values.count(None)
    issues = []
    if known > expected or (missing and known >= expected):
        issues.append('已识别时值与拍号冲突；整小节改用默认时值占位，需人工修改')
        values = [None]*len(notes)
        known, missing = Fraction(), len(notes)
    default = None
    if missing:
        available = (expected-known)/missing
        default = next((d for d in (4, 8, 16, 32, 64) if Fraction(4, d) <= available), None)
        if default is None:
            raise ValueError('音符过密，64 分音符占位仍无法放入该拍号，请检查小节边界或拍号')
        issues.append(f'{missing} 个音符使用 1/{default} 默认时值占位（并非从图片识别）')
    beats = []
    for note, reading, value in zip(notes, readings, values):
        beats.append({'duration': value or default, 'dots': 0, 'tuplet': [1, 1], 'grace': False,
                      'notes': [{'string': note['string'], 'fret': note['fret'], 'dead': False}],
                      'rhythm_source': reading.get('source', 'image-beams') if value else 'manual-default',
                      'placeholder': not bool(value), 'note_review': bool(note.get('review')),
                      'rhythm_review': bool(value and reading.get('review_reason')),
                      'rhythm_reason': reading.get('review_reason') if value else reading.get('reason', '未知时值或小节时值冲突'),
                      'rhythm_evidence': reading.get('evidence') if value else None})
    for i, beat in enumerate(beats, 1):
        if beat['rhythm_review']:
            issues.append(f'第 {i} 项时值证据不完整：{beat["rhythm_reason"]}；? 表示待核对，不是默认占位')
    remaining = expected - sum((Fraction(4, b['duration']) for b in beats), Fraction())
    if remaining:
        issues.append(f'余下 {remaining} 拍使用休止占位并放在小节末尾；需核对是否漏音以及原谱的休止位置')
    options = sorted(((Fraction(4, d)*sum((Fraction(1, 2**i) for i in range(dots+1)), Fraction()), d, dots)
                      for d in (1, 2, 4, 8, 16, 32, 64) for dots in (0, 1, 2)), reverse=True)
    while remaining:
        choice = next((item for item in options if item[0] <= remaining), None)
        if choice is None:
            raise ValueError('剩余时值无法表示为普通休止占位')
        amount, duration, dots = choice
        beats.append({'duration': duration, 'dots': dots, 'tuplet': [1, 1], 'grace': False, 'notes': [],
                      'rhythm_source': 'manual-rest-default', 'placeholder': True, 'note_review': False})
        remaining -= amount
    return beats, issues


def prepare_image_score(data, image_folder):
    settings = data['manual_settings']
    score = {'format': 'raster-tab-beamed-v1', 'tempo': settings['tempo'], 'meter': settings['meter'],
             'tuning': settings['tuning'], 'systems': [], 'structure_issues': [],
             'warnings': ['BPM、拍号及定弦为人工设置；音符需核对，演奏技巧、反复与和弦同时分组未验证。'],
             'source_sha256': data.get('source_sha256'), 'model_sha256': data.get('model_sha256')}
    data['rhythm_errors'] = []
    number = 0
    for system in data['systems']:
        region = system['region']
        image_path = image_folder / f'{system["id"]}.png'
        # cv2.imread on Windows can fail for Chinese directory names. Read bytes
        # via pathlib and decode, rather than silently losing all beam evidence.
        gray = cv2.imdecode(np.frombuffer(image_path.read_bytes(), np.uint8), cv2.IMREAD_GRAYSCALE) if image_path.exists() else None
        if gray is None or not all('x' in n and 'box' in n for n in system['notes']):
            baseline = [{'duration': None, 'reason': '没有可用的符干/横梁图像证据'} for n in system['notes']]
            readings = baseline
        else:
            baseline = read_beamed_notes(gray, system['notes'], region)
            readings = read_plain_stems(gray, system['notes'], region, baseline)
        output_system = {'page': system['page'], 'bars': []}
        system['rhythm_bars'] = []
        for local_bar in range(1, region['expected_bars']+1):
            number += 1
            pairs = [(note, reading, previous) for note, reading, previous in zip(system['notes'], readings, baseline)
                     if note['bar'] == local_bar]
            notes = [p[0] for p in pairs]
            timing = [p[1] for p in pairs]
            previous_timing = [p[2] for p in pairs]
            try:
                # Simultaneous/multi-voice notes are retained sequentially for
                # manual editing, with the entire bar explicitly marked.
                gap = float(np.median(np.diff(region['ys']))) if 'ys' in region else 14
                simultaneous = any(abs(a.get('x', -1)-b.get('x', -100)) < gap*.7 for a, b in zip(notes, notes[1:]))
                if simultaneous:
                    timing = [{'duration': None, 'reason': '可能同时起音，需人工分组'} for _ in notes]
                beats, issues = fill_bar(notes, timing, settings['meter'])
                if not simultaneous and any(r.get('source') == 'image-stem' for r in timing):
                    previous_beats, previous_issues = fill_bar(notes, previous_timing, settings['meter'])
                    changed_others = any(
                        (old['placeholder'] and current['placeholder'] and old['duration'] != current['duration'])
                        or (not old['placeholder'] and (current['placeholder'] or old['duration'] != current['duration']))
                        for old,current in zip(previous_beats[:len(notes)], beats[:len(notes)]))
                    if changed_others:
                        beats, issues, timing = previous_beats, previous_issues, previous_timing
                if simultaneous:
                    issues.append('存在可能的和弦或多声部；音符暂按顺序保留，须人工合并分组')
                if system['unresolved']:
                    issues.append('本行有未解决 OCR 区域，须核对是否漏音')
                if local_bar == region['expected_bars'] and region.get('right_may_be_cut'):
                    issues.append(CUT_OFF_WARNING)
                bar = {'number': number, 'source_bar': local_bar, 'meter': settings['meter'],
                       'beats': beats, 'issues': issues,
                       'recognition_timing_issue': validate_bar_timing([r['duration'] for r in timing], settings['meter'])}
                output_system['bars'].append(bar)
                system['rhythm_bars'].append(bar)
            except ValueError as error:
                data['rhythm_errors'].append(f'第 {system["page"]} 页第 {local_bar} 小节：{error}')
        score['systems'].append(output_system)
    score['structure_issues'] = list(data['rhythm_errors'])
    return score
