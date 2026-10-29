"""Compare full-book region decisions and explicit manually marked staff cores."""
import argparse
import json
from pathlib import Path


def evaluate(before, after, labels):
    assert Path(before['source']).name == Path(after['source']).name == labels['source_name']
    assert before['complete'] and after['complete']
    assert len(before['pages']) == len(after['pages'])
    preserved = 0
    for old, new in zip(before['pages'], after['pages']):
        assert (old['page'],old['width'],old['height']) == (new['page'],new['width'],new['height'])
        old_boxes=[r['box'] for r in old['regions'] if r['accepted']]
        new_boxes=[r['box'] for r in new['regions'] if r['accepted']]
        assert old_boxes == new_boxes, f'第 {old["page"]} 页原建议区域发生变化'
        preserved += len(old_boxes)
    results=[]
    for case in labels['cases']:
        core=case['staff_core']
        def contains(manifest):
            page=next(p for p in manifest['pages'] if p['page']==case['page'])
            return any(r['box'][0]<=core[0] and r['box'][1]<=core[1]
                       and r['box'][2]>=core[2] and r['box'][3]>=core[3] for r in page['regions'])
        results.append({**case,'before':contains(before),'after':contains(after)})
    assert all(r['after'] for r in results), '存在未覆盖的已标记谱行'
    return {'pages_checked':len(after['pages']),'prior_suggested_regions_preserved':preserved,
            'marked_staff_cores_before':sum(r['before'] for r in results),
            'marked_staff_cores_after':sum(r['after'] for r in results),'cases':results,
            'limitation':'仅标记样例的谱线主体覆盖，不是整本分区或音符准确率'}


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('before',type=Path)
    parser.add_argument('after',type=Path)
    parser.add_argument('--out',required=True,type=Path)
    args=parser.parse_args()
    read=lambda p:json.loads(p.read_text(encoding='utf-8'))
    result=evaluate(read(args.before),read(args.after),read(Path(__file__).with_name('textbook-coverage-cases.json')))
    args.out.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))
