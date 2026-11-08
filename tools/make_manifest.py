#!/usr/bin/env python3
"""M0.01 provenance manifest.

Hashes the supplied source trees and the upload archive, and records what can
and cannot be established about their identity. Deliberately reports "unknown"
where an upstream commit cannot be proven, per the RFC's M0.01 acceptance text.

The tree hash is sha256 over the sorted lines "<sha256>  <relpath>" for every
regular file, so it changes if any file content or path changes.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parent.parent
UPLOADS = WORKSPACE.parent
DOWNLOADS = UPLOADS.parent
OUT = WORKSPACE / "artifacts"

TREES = ["godot-dynamic_gi_2", "Terrain3D-main", "Foliage3D-master"]
ARCHIVE_CANDIDATES = [DOWNLOADS / "godot upgraded .zip", UPLOADS / "godot upgraded .zip"]

SKIP_DIRS = {".git", "__pycache__", ".mypy_cache"}


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def walk(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            p = Path(dirpath) / name
            if p.is_file() and not p.is_symlink():
                yield p


def tree_digest(root: Path) -> tuple[str, int, int]:
    lines = []
    total = 0
    count = 0
    for p in walk(root):
        rel = p.relative_to(root).as_posix()
        lines.append(f"{sha256_file(p)}  {rel}")
        total += p.stat().st_size
        count += 1
    lines.sort()
    h = hashlib.sha256("\n".join(lines).encode())
    return h.hexdigest(), count, total


def parse_version(root: Path) -> dict:
    vf = root / "version.py"
    if not vf.exists():
        return {"present": False}
    text = vf.read_text(errors="replace")
    out = {}
    for key in ("short_name", "name", "major", "minor", "patch", "status", "module_config"):
        m = re.search(rf'^{key}\s*=\s*(?:"([^"]*)"|([\w.]+))', text, re.M)
        if m:
            out[key] = m.group(1) if m.group(1) is not None else m.group(2)
    out["present"] = True
    return out


def git_state(root: Path) -> dict:
    if not (root / ".git").exists():
        return {"repository": False, "commit": "unknown", "reason": "no .git directory in supplied tree"}
    try:
        head = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=20)
        dirty = subprocess.run(["git", "-C", str(root), "status", "--porcelain"], capture_output=True, text=True, timeout=20)
        return {
            "repository": True,
            "commit": head.stdout.strip() or "unknown",
            "dirty": bool(dirty.stdout.strip()),
        }
    except Exception as exc:  # pragma: no cover - defensive
        return {"repository": True, "commit": "unknown", "reason": str(exc)}


def upstream_guess(root: Path) -> dict:
    """Look for evidence of the upstream base without asserting one."""
    evidence = {}
    changelog = root / "CHANGELOG.md"
    if changelog.exists():
        head = changelog.read_text(errors="replace")[:2000]
        evidence["changelog_head"] = head.splitlines()[:6]
    rev = root / "core" / "version.h"
    if rev.exists():
        evidence["core_version_h"] = rev.read_text(errors="replace").splitlines()[:10]
    return evidence


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)

    manifest = {
        "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "generator": "tools/make_manifest.py",
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "archive": None,
        "trees": {},
        "claims": {
            "upstream_commit": "unknown for all trees: no VCS metadata was supplied",
            "build_performed": False,
            "runtime_measured": False,
        },
    }

    archive = next((p for p in ARCHIVE_CANDIDATES if p.exists()), None)
    if archive is not None:
        manifest["archive"] = {
            "path": archive.name,
            "sha256": sha256_file(archive),
            "bytes": archive.stat().st_size,
        }
    else:
        manifest["archive"] = {"error": "not found", "searched": [str(p) for p in ARCHIVE_CANDIDATES]}

    for name in TREES:
        root = UPLOADS / name
        if not root.exists():
            manifest["trees"][name] = {"present": False}
            continue
        digest, count, total = tree_digest(root)
        entry = {
            "present": True,
            "tree_sha256": digest,
            "file_count": count,
            "bytes": total,
            "version": parse_version(root),
            "git": git_state(root),
        }
        if name == "godot-dynamic_gi_2":
            entry["upstream_evidence"] = upstream_guess(root)
        manifest["trees"][name] = entry

    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    eng = manifest["trees"].get("godot-dynamic_gi_2", {}).get("version", {})
    (OUT / "engine_version.txt").write_text(
        "source tree: godot-dynamic_gi_2\n"
        f"version.py: {eng.get('major', '?')}.{eng.get('minor', '?')}.{eng.get('patch', '?')}"
        f"-{eng.get('status', '?')}\n"
        f"tree_sha256: {manifest['trees']['godot-dynamic_gi_2']['tree_sha256']}\n"
        "git commit: unknown (no VCS metadata in supplied tree)\n"
        f"archive_sha256: {manifest['archive'].get('sha256', 'n/a')}\n"
    )

    print(json.dumps(manifest, indent=2)[:2000])
    return 0


if __name__ == "__main__":
    sys.exit(main())
