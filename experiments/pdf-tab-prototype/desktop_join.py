"""Join source-file recognition into a new draft, with explicit rest separators."""
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from desktop_batch import ROOT, process_file, write_report
from raster_beam_rhythm import fill_bar


def validate_join(sources, gaps, title):
    if len(sources) < 2 or len(gaps) != len(sources) - 1:
        raise ValueError('至少选择两份文件，并为每个连接处设置空白小节数')
    if any(type(g) is not int or not 0 <= g <= 99 for g in gaps):
        raise ValueError('空白小节数应为 0–99 的整数；0 表示直接连接')
    if not title.strip() or len(title) > 80 or re.search(r'[<>:"/\\|?*\x00-\x1f]', title):
        raise ValueError('请输入不超过 80 字的谱名，不含文件路径或特殊符号')


def combine_scores(parts, gaps, title):
    validate_join(parts, gaps, title)
    first = parts[0]['score']
    merged = {'format': 'joined-tab-draft-v1', 'title': title, 'tempo': first['tempo'],
              'tuning': copy.deepcopy(first['tuning']), 'systems': [], 'structure_issues': [],
              'join_parts': [], 'warnings': ['按文件顺序拼接；重叠小节不会自动去重，跨截图的半小节不会自动补接。']}
    number, page_offset = 0, 0
    for index, part in enumerate(parts):
        score = part['score']
        if score.get('structure_issues') or not any(s['bars'] for s in score['systems']):
            raise ValueError(f'{part["name"]} 缺少可用小节，未输出不完整拼接')
        if score['tuning'] != merged['tuning']:
            raise ValueError('片段定弦不同，请统一定弦后再拼接')
        entry = {k: part[k] for k in ('name', 'source', 'report')}
        entry.update(start_bar=number + 1, gap_after=gaps[index] if index < len(gaps) else 0)
        for original in score['systems']:
            if not original['bars']:
                continue
            system = copy.deepcopy(original)
            system['source_name'] = part['name']
            system['source_page'] = original['page']
            system['page'] += page_offset
            for bar in system['bars']:
                number += 1
                bar['original_bar'] = bar['number']
                bar['number'] = number
                bar['tempo'] = bar.get('tempo', score['tempo'])
                bar['image_source'] = score.get('format') == 'raster-tab-beamed-v1'
                if number == entry['start_bar']:
                    bar['segment_label'] = f'片段 {index + 1}：{part["name"]}'
                for flag, label in [('note_review', '音符的数字或弦位待确认'), ('placeholder', '时值为占位（?）')]:
                    positions = '、'.join(str(i) for i, b in enumerate(bar['beats'], 1) if b.get(flag))
                    if positions:
                        bar.setdefault('issues', []).append(f'第 {positions} 项{label}')
            merged['systems'].append(system)
        entry['end_bar'] = number
        merged['join_parts'].append(entry)
        merged['warnings'].extend(f'{part["name"]}：{w}' for w in score.get('warnings', []))
        page_offset += max(s['page'] for s in score['systems'])
        previous = merged['systems'][-1]['bars'][-1]
        for _ in range(entry['gap_after']):
            number += 1
            beats, _ = fill_bar([], [], previous['meter'])
            for beat in beats:
                beat.update(placeholder=False, rhythm_source='user-separator')
            merged['systems'].append({'page': page_offset, 'source_name': '手动插入的空白分隔',
                'bars': [{'number': number, 'meter': copy.deepcopy(previous['meter']),
                          'tempo': previous['tempo'], 'beats': beats, 'issues': [], 'separator': True}]})
    return merged


def process_join(sources, gaps, title, folder, settings, stop=None, progress=None):
    sources, folder = [Path(s).resolve() for s in sources], Path(folder).resolve()
    validate_join(sources, gaps, title)
    folder.mkdir(parents=True, exist_ok=True)
    if any(folder.iterdir()):
        raise ValueError('拼接结果目录必须为空，避免覆盖已有文件')
    display_source = folder / (title + '.gp')
    outcome = {'source': str(display_source), 'folder': str(folder), 'status': '拼接未完成',
               'message': '', 'draft': None}
    data = {'systems': [], 'join_parts': [], 'warnings': []}
    manifest = {'title': title, 'sources': [str(s) for s in sources], 'gaps': gaps, 'image_settings': settings}
    (folder / 'join-plan.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    parts = []
    try:
        for index, source in enumerate(sources, 1):
            if stop and stop.is_set():
                raise InterruptedError('已停止；已完成的单份结果已保留，未导出不完整的拼接 GP')
            if progress:
                progress(f'拼接识别 {index}/{len(sources)}：{source.name}')
            part_folder = folder / f'part-{index:03d}'
            result = process_file(source, part_folder, settings)
            entry = {'name': source.name, 'source': str(source), 'report': f'part-{index:03d}/review.html'}
            data['join_parts'].append(entry)
            if not result.get('draft'):
                raise ValueError(f'{source.name} 未生成草稿：{result["message"]}。请打开该片段结果检查。')
            score_path = part_folder / 'image-score.json'
            if not score_path.is_file():
                score_path = part_folder / 'recognized.json'
            score = json.loads(score_path.read_text(encoding='utf-8'))
            if score.get('format') == 'raster-tab-beamed-v1':
                raw = json.loads((part_folder / 'recognized.json').read_text(encoding='utf-8'))
                for system, evidence in zip(score['systems'], raw['systems']):
                    for item in evidence.get('discarded_bands', []):
                        match = re.fullmatch(r'bar(\d+)-string(\d+)', str(item.get('row', '')))
                        for bar in system['bars']:
                            if match and int(match[1]) != bar['source_bar']:
                                continue
                            location = f'第 {match[2]} 弦' if match else '本行'
                            bar.setdefault('issues', []).append(location + '有未采用的弱证据，请检查是否漏音；详见片段原谱')
            parts.append({**entry, 'score': score})
        if stop and stop.is_set():
            raise InterruptedError('已停止；单份结果已保留，未生成拼接 GP')
        data = combine_scores(parts, gaps, title)
        input_path = folder / 'recognized.json'
        input_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
        node = shutil.which('node')
        if not node:
            raise ValueError('未找到 Node.js；单份结果已保留')
        run = subprocess.run([node, str(ROOT / 'gp-draft-export.cjs'), str(input_path), str(folder / 'score.draft.gp')],
                             capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120,
                             creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        (folder / 'worker.log').write_text(run.stdout + '\n' + run.stderr, encoding='utf-8')
        if run.returncode:
            raise ValueError('拼接 GP 导出或读回验证失败；单份结果已保留，请查看处理日志')
        count = sum(len(s['bars']) for s in data['systems'])
        outcome.update(status='拼接草稿已生成', draft=str(folder / 'score.draft.gp'),
                       message=f'{len(sources)} 份文件，合计 {count} 小节，其中 {sum(gaps)} 个手动空白小节。'
                               '疑点按合并后的小节号显示；请在 Guitar Pro 中修改。')
    except Exception as error:
        outcome['message'] = str(error)
    (folder / 'recognized.json').write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    write_report(display_source, folder, outcome, data)
    return outcome
