"""One-shot offline VLM probe: no listening socket or persistent model service."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time

from local_model_probe import sha256
from local_vlm_probe import PROMPT


def generation_finished(returncode, log, limit):
    # Upstream mtmd-cli exits 0 both at EOS and the token limit. Count actual
    # decoder evaluations; missing diagnostics must never be counted as EOS.
    counts = []
    for line in log.splitlines():
        if 'eval time' in line and 'prompt eval' not in line:
            match = re.search(r'/\s*(\d+)\s+runs', line)
            if match:
                counts.append(int(match[1]))
    return returncode == 0 and len(counts) == 1 and counts[0] < limit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', type=Path, required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Preserve frozen predictions; use a new output')
    clips = json.loads(args.manifest.read_text(encoding='utf-8'))
    if not clips or any(set(c) != {'id', 'image'} for c in clips):
        raise ValueError('Only id and image may enter inference')
    source = json.loads((args.model_dir/'sources.json').read_text())
    for item in source['files']:
        if sha256(args.model_dir/item['name']) != item['sha256']:
            raise ValueError('Model hash mismatch')
    model = next(item['name'] for item in source['files'] if not item['name'].startswith('mmproj'))
    template_path = args.model_dir/'chat_template.jinja'
    template_source = json.loads((args.model_dir/'template-source.json').read_text())
    if sha256(template_path) != template_source['sha256']:
        raise ValueError('Template hash mismatch')
    template = '{% set enable_thinking = false %}\n'+template_path.read_text(encoding='utf-8')
    common = [str(args.runtime), '-m', str(args.model_dir/model), '--mmproj', str(args.model_dir/'mmproj-F16.gguf'),
              '-c', '8192', '-fit', 'on', '-fitt', '1536', '-fa', 'on', '-b', '256', '-ub', '128', '-t', '4',
              '--image-min-tokens', '1024', '--image-max-tokens', '2048', '--jinja', '--chat-template', template,
              '--temp', '0.7', '--top-p', '0.8', '--top-k', '20', '--min-p', '0', '--presence-penalty', '1.5',
              '--seed', '42', '-n', '4096', '-lv', '4']
    raw_dir = args.output.with_suffix('')
    raw_dir.mkdir(parents=True, exist_ok=False)
    result = {'format': 'vlm-compact-rhythm-v1', 'transport': 'offline-cli', 'model': model,
              'source': source, 'template_source': template_source, 'runtime_sha256': sha256(args.runtime),
              'manifest_sha256': sha256(args.manifest), 'prompt': PROMPT,
              'timing_scope': 'cold process including model loading', 'predictions': []}
    for index, clip in enumerate(clips):
        out_path, err_path = raw_dir/f'{index:03d}.out.txt', raw_dir/f'{index:03d}.err.txt'
        started = time.perf_counter()
        with out_path.open('w', encoding='utf-8') as out, err_path.open('w', encoding='utf-8') as err:
            try:
                run = subprocess.run(common+['--image', clip['image'], '-p', PROMPT], stdout=out, stderr=err, timeout=300)
                returncode = run.returncode
            except subprocess.TimeoutExpired:
                returncode = -1
        log = err_path.read_text(encoding='utf-8', errors='replace')
        finished = generation_finished(returncode, log, 4096)
        prediction = {'id': clip['id'], 'image_sha256': sha256(clip['image']),
                      'seconds': round(time.perf_counter()-started, 3), 'returncode': returncode,
                      'log_sha256': sha256(err_path), 'response': {'choices': [{
                          'finish_reason': 'stop' if finished else 'incomplete-or-unverified',
                          'message': {'content': out_path.read_text(encoding='utf-8', errors='replace')}}]}}
        result['predictions'].append(prediction)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        print(json.dumps({'id': clip['id'], 'seconds': prediction['seconds'], 'finished': finished}), flush=True)


if __name__ == '__main__':
    main()
