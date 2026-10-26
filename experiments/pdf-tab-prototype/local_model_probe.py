"""Isolated image-only probe; never imports GP references or changes recognition.

Uses pinned upstream implementation and safe checkpoint loading. A parseable
token sequence is not an accuracy result. Run reference comparison separately.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--constrained', action='store_true')
    parser.add_argument('--uncached', action='store_true')
    args = parser.parse_args()
    lock = json.loads(Path(__file__).with_name('local-model-sources.json').read_text())
    for name in ('guitar_omr_train.py', 'guitar_omr_eval.py', 'guitar_omr_dataset_smoke.py'):
        if sha256(args.model_dir / name) != lock['downloaded_files_sha256'][name]:
            raise ValueError(f'Unexpected upstream source: {name}')
    if sha256(args.model_dir / 'best.pt') != lock['checkpoint_sha256']:
        raise ValueError('Unexpected model checkpoint')
    clips = json.loads(args.manifest.read_text(encoding='utf-8'))
    if not clips or any(set(c) != {'id', 'image'} for c in clips):
        raise ValueError('Manifest must contain only id and image for each clip')
    if len({c['id'] for c in clips}) != len(clips):
        raise ValueError('Duplicate clip IDs')
    if args.output.exists():
        raise FileExistsError('Use a new output file to preserve frozen predictions')
    os.environ['HF_HUB_OFFLINE'] = '1'
    sys.path.insert(0, str(args.model_dir.resolve()))
    import torch
    import timm
    from guitar_omr_dataset_smoke import load_image_tensor
    from guitar_omr_eval import create_model, greedy_decode, decode_ids, build_token_groups
    from guitar_omr_train import validate_token_structure

    torch.set_num_threads(4)
    checkpoint = torch.load(args.model_dir / 'best.pt', map_location='cpu', weights_only=True)
    model_args = dict(checkpoint['config']['args'])
    # All encoder weights are already in this checkpoint. No extra downloads.
    model_args['pretrained_encoder'] = False
    vocab = checkpoint['vocab']
    model = create_model(model_args, vocab, checkpoint['config'])
    model.load_state_dict(checkpoint['model'], strict=True)
    model.eval()
    del checkpoint
    id_to_token = {v: k for k, v in vocab.items()}
    groups = build_token_groups(vocab) if args.constrained else None
    result = {'model_revision': lock['model_revision'], 'checkpoint_sha256': lock['checkpoint_sha256'],
              'manifest_sha256': sha256(args.manifest), 'torch': torch.__version__, 'timm': timm.__version__,
              'device': 'cpu', 'threads': 4, 'constrained': args.constrained,
              'cached_encoder': not args.uncached, 'predictions': []}
    encoder = model.encoder

    class CachedEncoder(torch.nn.Module):
        def __init__(self, memory):
            super().__init__()
            self.memory = memory

        def forward(self, images):
            return self.memory

    args.output.parent.mkdir(parents=True, exist_ok=True)
    for clip in clips:
        started = time.perf_counter()
        image = load_image_tensor(Path(clip['image']), model_args['width'], model_args['height'])
        model.encoder = encoder
        with torch.inference_mode():
            if not args.uncached:
                model.encoder = CachedEncoder(encoder(image.unsqueeze(0)))
            ids, eos = greedy_decode(model, image, vocab['<BOS>'], vocab['<EOS>'],
                                     model_args['max_seq_len'], torch.device('cpu'), id_to_token, groups)
        tokens = decode_ids(ids, id_to_token)
        valid, bars = validate_token_structure(tokens)
        prediction = {'id': clip['id'], 'image_sha256': sha256(clip['image']), 'tokens': tokens,
                      'eos': eos, 'upstream_structure_valid': valid, 'bar_count': bars,
                      'seconds': round(time.perf_counter() - started, 3)}
        result['predictions'].append(prediction)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({k: v for k, v in prediction.items() if k != 'tokens'}), flush=True)


if __name__ == '__main__':
    main()
