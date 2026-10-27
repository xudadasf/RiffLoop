"""Split frozen system crops using PDF vector barlines only, never GP events."""
import argparse
import json
from pathlib import Path

import fitz
from local_model_probe import sha256
from recognize import clusters, lines_and_shapes, staves


def bar_intervals(staff, lines):
    ys = staff['ys']
    vertical = [min(x0, x1) for x0, y0, x1, y1 in lines
                if abs(x1-x0) < 1 and min(y0, y1) < ys[0]+.8 and max(y0, y1) > ys[-1]-.8]
    boundaries = clusters([staff['left'], staff['right']]+vertical, 1.8)
    boundaries = [x for x in boundaries if staff['left']-1 <= x <= staff['right']+1]
    return [(a, b) for a, b in zip(boundaries, boundaries[1:]) if b-a >= 12]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--geometry', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    parents = json.loads(args.manifest.read_text(encoding='utf-8'))
    geometries = {g['id']: g for g in json.loads(args.geometry.read_text(encoding='utf-8'))}
    args.output_dir.mkdir(parents=True, exist_ok=False)
    manifest, result = [], []
    for parent in parents:
        geo = geometries[parent['id']]
        if sha256(parent['image']) != geo['image_sha256'] or sha256(geo['pdf']) != geo['pdf_sha256']:
            raise ValueError('Frozen source changed')
        with fitz.open(geo['pdf']) as doc:
            page = doc[geo['page']-1]
            lines, _ = lines_and_shapes(page)
            matches = [s for s in staves(lines, page.rect.width) if s['ys'] == geo['ys'] and s['count'] == 6]
            if len(matches) != 1:
                raise ValueError('Staff geometry changed')
            intervals = bar_intervals(matches[0], lines)
            if not intervals:
                raise ValueError('No vector bar boundaries')
            for index, (left, right) in enumerate(intervals):
                # Preserve the system's vertical context; horizontal padding contains
                # the boundary stroke without including neighboring note centers.
                rect = fitz.Rect(left-2, geo['rect'][1], right+2, geo['rect'][3]) & page.rect
                clip_id = f'{parent["id"]}-bar-{index:03d}'
                image = args.output_dir/f'{clip_id}.png'
                page.get_pixmap(matrix=fitz.Matrix(2.5, 2.5), clip=rect, alpha=False).save(image)
                manifest.append({'id': clip_id, 'image': str(image.resolve())})
                result.append({**geo, 'id': clip_id, 'parent_id': parent['id'], 'bar_index': index,
                               'parent_bar_count': len(intervals), 'rect': list(rect),
                               'left': left, 'right': right, 'image_sha256': sha256(image)})
    (args.output_dir/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    (args.output_dir/'geometry.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'systems': len(parents), 'bars': len(manifest)}))


if __name__ == '__main__':
    main()
