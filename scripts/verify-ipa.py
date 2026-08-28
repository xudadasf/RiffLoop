"""Fail closed before installing a package: commit, hash and actual bundle metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import zipfile


def verify_package(ipa, metadata, commit, version, build):
    if metadata.get("head_sha") != commit:
        raise ValueError("Package commit does not match the requested git ref")
    if metadata.get("ipa_file") != ipa.name:
        raise ValueError("Manifest belongs to a different IPA filename")
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    if metadata.get("sha256", "").lower() != digest:
        raise ValueError("IPA SHA256 mismatch")
    with zipfile.ZipFile(ipa) as archive:
        app_plists = [name for name in archive.namelist()
                      if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if app_plists != ["Payload/RiffLoop.app/Info.plist"]:
            raise ValueError("Expected exactly one RiffLoop application")
        info = plistlib.loads(archive.read(app_plists[0]))
    expected = {"CFBundleIdentifier": "com.riffloop.prototype",
                "CFBundleShortVersionString": version, "CFBundleVersion": str(build),
                "CFBundleSupportedPlatforms": ["iPhoneOS"]}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"IPA {key} mismatch: expected {value!r}, got {info.get(key)!r}")
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    commit = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "--verify", "--end-of-options", f"{args.ref}^{{commit}}"], text=True).strip()
    project = subprocess.check_output(["git", "-C", str(repo), "show", f"{commit}:project.yml"], text=True)
    version = re.search(r"MARKETING_VERSION:\s*([0-9.]+)", project).group(1)
    build = re.search(r"CURRENT_PROJECT_VERSION:\s*(\d+)", project).group(1)
    metadata = json.loads((args.manifest or args.ipa.parent / "build-info.json").read_text(encoding="utf-8-sig"))
    digest = verify_package(args.ipa, metadata, commit, version, build)
    print(f"Verified RiffLoop {version} ({build}), commit {commit}, SHA256 {digest}")


if __name__ == "__main__":
    main()
