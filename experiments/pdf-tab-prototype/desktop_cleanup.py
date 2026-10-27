"""Clean generated intermediates only; preserve GP, source and user files."""
import hashlib
import json
from pathlib import Path
import re

ROOT_FILES = {'worker.log','image-digits.log','image-model.log','image-manifest.json',
              'image-model-predictions.json','image-score.json','overlay.pdf'}
DIGIT_FILES = re.compile(r'(?:page-\d+\.png|p\d+-s\d+(?:-boxes)?\.png|p\d+-s\d+-(?:bands|ocr)\.json|prediction\.json|review\.html)')
IMAGE_FILES = re.compile(r'page-\d+(?:-system-\d+)?\.png')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def context(folder):
    original = Path(folder).absolute()
    if original.is_symlink() or original.is_junction():
        raise ValueError('不清理链接或目录联接指向的结果目录')
    root = original.resolve()
    result = json.loads((root/'result.json').read_text(encoding='utf-8'))
    if Path(result['folder']).resolve() != root:
        raise ValueError('结果目录与处理记录不一致，未执行清理')
    return root, result


def allowed(root, path, source):
    if not path.is_file() or path.is_symlink() or path.resolve() == source:
        return False
    if not path.resolve().is_relative_to(root):
        return False
    relative = path.relative_to(root)
    if len(relative.parts)==1:
        return relative.name in ROOT_FILES
    if len(relative.parts)!=2:
        return False
    parent = path.parent
    if parent.is_symlink() or parent.is_junction():
        return False
    pattern = DIGIT_FILES if relative.parts[0]=='digit-ocr' else IMAGE_FILES if relative.parts[0]=='images' else None
    return bool(pattern and pattern.fullmatch(relative.name))


def register_intermediates(folder):
    root,result = context(folder)
    source = Path(result['source']).resolve()
    candidates = list(root.iterdir())
    for name in ('digit-ocr','images'):
        parent=root/name
        if parent.is_dir() and not parent.is_symlink() and not parent.is_junction():
            candidates.extend(parent.iterdir())
    files=[]
    for path in candidates:
        if allowed(root,path,source):
            files.append({'path':path.relative_to(root).as_posix(),'bytes':path.stat().st_size,'sha256':digest(path)})
    manifest={'version':1,'files':files}
    (root/'cleanup-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    return manifest


def clean_intermediates(folder):
    root,result = context(folder)
    source=Path(result['source']).resolve()
    manifest_path=root/'cleanup-manifest.json'
    # Older results predate ownership manifests. Only the strict generated-file
    # allowlist is adopted; GP files and arbitrary user filenames never qualify.
    manifest=json.loads(manifest_path.read_text(encoding='utf-8')) if manifest_path.exists() else register_intermediates(root)
    removed,kept,errors,freed=[],[],[],0
    for item in manifest['files']:
        relative=Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            kept.append(item['path'])
            continue
        path=root/relative
        if not path.exists():
            continue
        try:
            if not allowed(root,path,source) or digest(path)!=item['sha256']:
                kept.append(item['path'])
                continue
            size=path.stat().st_size
            path.unlink()
            removed.append(item['path'])
            freed+=size
        except OSError as error:
            errors.append(f'{item["path"]}: {error}')
    for name in ('digit-ocr','images'):
        parent=root/name
        if parent.is_dir() and not parent.is_symlink() and not parent.is_junction() and not any(parent.iterdir()):
            parent.rmdir()
    cleanup={'removed':removed,'bytes_freed':freed,'kept_modified_or_unowned':kept,'errors':errors}
    (root/'cleanup-result.json').write_text(json.dumps(cleanup,ensure_ascii=False,indent=2),encoding='utf-8')
    result['cleanup']=cleanup
    result.setdefault('message_before_cleanup',result['message'])
    result['message'] = result['message_before_cleanup'] + f' 中间文件已清理 {freed/1048576:.1f} MB；GP、原文件和修改清单保留。'
    data_path=root/'recognized.json'
    data=json.loads(data_path.read_text(encoding='utf-8')) if data_path.exists() else {}
    from desktop_batch import write_report
    write_report(source,root,result,data)
    return cleanup
