"""Download the pinned TAB model for local testing; verify every file before use."""
import argparse
import json
from pathlib import Path
import urllib.request

from local_model_probe import sha256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-dir', type=Path, required=True)
    args = parser.parse_args()
    lock_path = Path(__file__).with_name('local-model-sources.json')
    lock = json.loads(lock_path.read_text())
    files = []
    for name, digest in lock['downloaded_files_sha256'].items():
        if name.endswith('.py'):
            url = f'https://raw.githubusercontent.com/LIU9293/guitar-tab-omr/{lock["github_revision"]}/scripts/{name}'
        else:
            url = f'https://huggingface.co/kk9293/guitar-tab-omr/resolve/{lock["model_revision"]}/{name}'
        files.append((name, url, digest))
    files += [('best.pt', f'https://huggingface.co/kk9293/guitar-tab-omr/resolve/{lock["model_revision"]}/best.pt',
               lock['checkpoint_sha256']),
              ('official-example.png', f'https://huggingface.co/spaces/kk9293/guitar-tab-omr/resolve/{lock["space_revision"]}/assets/single-system-tab-example.png',
               lock['official_example_sha256'])]
    args.model_dir.mkdir(parents=True, exist_ok=True)
    for name, url, digest in files:
        path = args.model_dir/name
        if not path.exists():
            temporary = path.with_suffix(path.suffix+'.part')
            urllib.request.urlretrieve(url, temporary)
            if sha256(temporary) != digest:
                raise ValueError(f'Download hash mismatch: {name}')
            temporary.rename(path)
        if sha256(path) != digest:
            raise ValueError(f'Existing file hash mismatch: {name}')
        print(f'Verified {name}', flush=True)


if __name__ == '__main__':
    main()
