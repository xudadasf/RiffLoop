"""Compare an alphaTab GP round trip without touching the input or the app.

Passing these checks is not proof of a lossless edit or correct playback. The
semantic comparison covers only the explicitly selected fields in the probe.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

SCORE_ENTRY = "Content/score.gpif"
CHUNK_SIZE = 1024 * 1024


def zip_entry_hashes(path):
    """Hash every uncompressed non-score entry; never extract archive paths."""
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)) or names.count(SCORE_ENTRY) != 1:
            raise ValueError("GP archive must contain exactly one score.gpif and no duplicate entry names")
        result = {}
        for info in infos:
            if info.filename == SCORE_ENTRY:
                continue
            digest = hashlib.sha256()
            with archive.open(info) as stream:
                for chunk in iter(lambda: stream.read(CHUNK_SIZE), b""):
                    digest.update(chunk)
            result[info.filename] = {"size": info.file_size, "sha256": digest.hexdigest()}
        return result


def compare_resources(before, after):
    old, new = set(before), set(after)
    entries = []
    for name in sorted(old | new):
        status = ("added" if name not in old else "missing" if name not in new
                  else "unchanged" if before[name] == after[name] else "changed")
        entries.append({"name": name, "status": status,
                        "before": before.get(name), "after": after.get(name)})
    renamed = []
    for old_name in sorted(old - new):
        for new_name in sorted(new - old):
            if before[old_name] == after[new_name] and before[old_name]["size"] > 0:
                renamed.append({"original": old_name, "matching_content_at": new_name})
    return {
        "missing": sorted(old - new),
        "added": sorted(new - old),
        "changed": sorted(name for name in old & new if before[name] != after[name]),
        "unchanged_count": sum(before[name] == after[name] for name in old & new),
        "same_content_different_name": renamed,
        "entries": entries,
    }


def compare_semantics(before, after, limit=100):
    """Count differences without embedding the entire score in the report."""
    examples = []
    count = 0

    def visit(a, b, path):
        nonlocal count
        if isinstance(a, dict) and isinstance(b, dict):
            for key in sorted(a.keys() | b.keys()):
                if key not in a or key not in b:
                    count += 1
                    if len(examples) < limit:
                        examples.append({"path": path + "." + key, "before": a.get(key), "after": b.get(key)})
                else:
                    visit(a[key], b[key], path + "." + key)
        elif isinstance(a, list) and isinstance(b, list):
            if len(a) != len(b):
                count += 1
                if len(examples) < limit:
                    examples.append({"path": path + ".length", "before": len(a), "after": len(b)})
            for index, (item_a, item_b) in enumerate(zip(a, b)):
                visit(item_a, item_b, f"{path}[{index}]")
        elif a != b:
            count += 1
            if len(examples) < limit:
                examples.append({"path": path, "before": a, "after": b})

    visit(before, after, "score")
    return {"difference_count": count, "examples": examples, "examples_limit": limit}


def audit(source, node="node", output_dir=None):
    source = Path(source).resolve(strict=True)
    # Reject unsupported or ambiguous inputs before handing them to the exporter.
    original_resources = zip_entry_hashes(source)
    probe = Path(__file__).with_name("gp-roundtrip-probe.cjs")
    with tempfile.TemporaryDirectory(prefix="riffloop-gp-audit-") as temp:
        generated = Path(temp) / "roundtrip.gp"
        completed = subprocess.run(
            [node, str(probe), str(source), str(generated)],
            check=True, capture_output=True, text=True, encoding="utf-8",
        )
        snapshots = json.loads(completed.stdout)
        report = {
            "source": str(source),
            "limitations": "Selected alphaTab fields and uncompressed ZIP resources only; matching does not establish lossless GP editing or correct playback.",
            "semantics": compare_semantics(snapshots["before"], snapshots["after"]),
            "resources": compare_resources(original_resources, zip_entry_hashes(generated)),
        }
        if output_dir is not None:
            target = Path(output_dir).resolve(strict=True)
            if not target.is_dir():
                raise ValueError("Output directory must be an existing directory")
            output_gp = target / (source.name + ".roundtrip.gp")
            output_report = target / (source.name + ".roundtrip-report.json")
            # Exclusive creation ensures original scores and previous reports stay untouched.
            with output_gp.open("xb") as result:
                with generated.open("rb") as src:
                    shutil.copyfileobj(src, result)
            try:
                with output_report.open("x", encoding="utf-8") as result:
                    json.dump(report, result, ensure_ascii=False, indent=2)
                    result.write("\n")
            except BaseException:
                os.unlink(output_gp)
                raise
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="GP7/8 ZIP-format file; never modified")
    parser.add_argument("--output-dir", help="Existing directory for the exported GP and JSON report; omit to retain neither")
    parser.add_argument("--node", default="node", help="Node.js executable")
    args = parser.parse_args()
    print(json.dumps(audit(args.input, args.node, args.output_dir), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
