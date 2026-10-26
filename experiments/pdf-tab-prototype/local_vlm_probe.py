"""Localhost-only visual rhythm probe. Inputs contain images, never GP answers."""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import time
import urllib.request

from local_model_probe import sha256

PROMPT = '''Transcribe the exact printed rhythm of this guitar tablature system, left to right.
Use note stems, beams, flags, dots, rests, tuplet brackets and ties. If standard
notation is present above TAB, use it for rhythm; these are the same part, not
two independent parts. Do not invent notes, repair durations to fit a meter,
or omit empty bars. Ignore prose and illustrations. An empty full measure is
one whole-measure rest. Parentheses around a fret can denote a tied continuation;
a slur between different frets is not a duration tie. Grace notes have grace=1.
Return only JSON with keys "bars" and "uncertain". "bars" is a list of measures;
each measure is a list of beat arrays. Each beat is exactly seven integers:
[duration_denominator, dot_count, tuplet_numerator, tuplet_denominator,
 rest, tied_note_count, grace]. Duration denominators: 1,2,4,8,16,32,64.
Use dot_count=0 without dots, tuplet=1,1 without tuplets, 3,2 for triplets.
rest and grace are 0 or 1. tied_note_count counts tie destinations in that beat,
not all slurred notes. Simultaneous chord notes form ONE beat. Example of two
ordinary quarter-note beats, the second silent: {"bars":[[[4,0,1,1,0,0,0],
[4,0,1,1,1,0,0]]],"uncertain":[]}. This is format only, not the image's answer.
When a beat cannot be read, put null instead of that beat and describe its
location in "uncertain". If there is no score, return empty bars and explain.
Do not include markdown, reasoning or any other keys.'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--thinking', action='store_true')
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Preserve predictions; choose a new output path')
    clips = json.loads(args.manifest.read_text(encoding='utf-8'))
    if not clips or any(set(c) != {'id', 'image'} for c in clips):
        raise ValueError('Only id and image may be passed to inference')
    models = json.load(urllib.request.urlopen('http://127.0.0.1:8142/v1/models', timeout=10))
    model = models['data'][0]['id']
    result = {'format': 'vlm-compact-rhythm-v1', 'model': model,
              'manifest_sha256': sha256(args.manifest), 'prompt': PROMPT,
              'temperature': 1.0 if args.thinking else 0.7, 'seed': 42, 'max_tokens': 4096,
              'top_p': 0.95 if args.thinking else 0.8, 'top_k': 20, 'min_p': 0.0,
              'presence_penalty': 1.5, 'thinking': args.thinking, 'predictions': []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for clip in clips:
        encoded = base64.b64encode(Path(clip['image']).read_bytes()).decode('ascii')
        body = {k: result[k] for k in ('model', 'temperature', 'seed', 'max_tokens',
                                      'top_p', 'top_k', 'min_p', 'presence_penalty')}
        body.update({'chat_template_kwargs': {'enable_thinking': args.thinking},
                'messages': [{'role': 'user', 'content': [
                    {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,'+encoded}},
                    {'type': 'text', 'text': PROMPT}]}]})
        started = time.perf_counter()
        request = urllib.request.Request('http://127.0.0.1:8142/v1/chat/completions',
                                         data=json.dumps(body).encode(),
                                         headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=300) as response:
            raw = json.load(response)
        prediction = {'id': clip['id'], 'image_sha256': sha256(clip['image']),
                      'seconds': round(time.perf_counter()-started, 3), 'response': raw}
        result['predictions'].append(prediction)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        gpu = subprocess.run(['nvidia-smi', '--query-gpu=memory.used,memory.free,utilization.gpu',
                              '--format=csv,noheader,nounits'], capture_output=True, text=True)
        prediction['gpu_snapshot_after_request'] = gpu.stdout.strip()
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        print(json.dumps({'id': clip['id'], 'seconds': prediction['seconds'],
                          'finish_reason': raw['choices'][0]['finish_reason'],
                          'gpu': gpu.stdout.strip()}), flush=True)


if __name__ == '__main__':
    main()
