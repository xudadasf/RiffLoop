"""Prepare PDF-only system crops for a fixed, exploratory model probe.

Uses existing vector staff geometry, not GP or recognized note content. Does
not claim support for scanned textbooks, image-only PDFs or multi-column pages.
"""
import argparse
import json
from pathlib import Path

import fitz
from recognize import lines_and_shapes, staves
from local_model_probe import sha256

CASES = ('case-002', 'case-004', 'case-009', 'case-011', 'case-019', 'case-026',
         'case-038', 'case-045', 'case-063', 'case-071', 'case-077', 'case-081')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pairing', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    pairing = json.loads(args.pairing.read_text(encoding='utf-8'))
    pdfs = {p['case']: p['pdf'] for p in pairing}
    manifest, geometry = [], []
    for case in CASES:
        pdf = Path(pdfs[case])
        with fitz.open(pdf) as document:
            systems = []
            for page_index, page in enumerate(document):
                lines, _ = lines_and_shapes(page)
                staffs = staves(lines, page.rect.width)
                for index, staff in enumerate(staffs):
                    if staff['count'] != 6:
                        continue
                    top = staff['ys'][0]
                    if index and staffs[index-1]['count'] == 5 and top-staffs[index-1]['ys'][-1] < 90:
                        top = staffs[index-1]['ys'][0]
                    bottom = staff['ys'][-1] + 48
                    if index+1 < len(staffs):
                        bottom = min(bottom, staffs[index+1]['ys'][0]-25)
                    rect = fitz.Rect(staff['left']-8, top-25, staff['right']+8, bottom) & page.rect
                    systems.append((page_index, staff, rect))
            if not systems:
                raise ValueError(f'No vector TAB systems: {case}')
            for system_index in sorted({0, len(systems)//2}):
                page_index, staff, rect = systems[system_index]
                clip_id = f'{case}-system-{system_index:03d}'
                image = args.output_dir / f'{clip_id}.png'
                document[page_index].get_pixmap(matrix=fitz.Matrix(2.5, 2.5), clip=rect, alpha=False).save(image)
                manifest.append({'id': clip_id, 'image': str(image.resolve())})
                geometry.append({'id': clip_id, 'case': case, 'system_index': system_index,
                                 'page': page_index+1, 'ys': staff['ys'], 'rect': list(rect),
                                 'pdf': str(pdf.resolve()), 'pdf_sha256': sha256(pdf),
                                 'image_sha256': sha256(image)})
    (args.output_dir/'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    (args.output_dir/'geometry.json').write_text(json.dumps(geometry, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'cases': len(CASES), 'clips': len(manifest)}))


if __name__ == '__main__':
    main()
