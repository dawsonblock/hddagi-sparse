#!/usr/bin/env python3
"""Verifies a built HDDAGI.app against the source project and the engine build.

Checks, in order:
  1. bundle structure: Info.plist, CFBundleExecutable, launch script, engine binary
  2. Contents/MacOS/godot is byte-identical to the engine binary it was built from
  3. every file in platform/test_project (except .godot/) is present and identical
     in the bundle; the only allowed extras are generated .uid siblings
  4. every .import dest_file in the bundle exists, i.e. the textures were imported
  5. a headless startup exits 0, reaches HDDAGI_SMOKE_READY and logs no errors
  6. a rendered Metal run (windowed) produces non-blank normal and debug captures

The rendered check is what catches shader and lighting failures that a headless
run cannot see. Use --skip-rendered only where there is no display, and record
that the run was not rendered.

    ./platform/verify_app.py --app ../hddagi-run/HDDAGI.app \
        --json artifacts/app_build/manifest.json \
        --markdown artifacts/app_build/report.md \
        --log-dir artifacts/app_build
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parent
ROOT = WORKSPACE.parent

sys.path.insert(0, str(WORKSPACE / "tools"))
import capture_check  # noqa: E402

# Re-exported so platform/test_verify_app.py exercises the exact code the
# verifier runs, and so there is one set of thresholds for app and bench checks.
CAPTURE_MARKER = capture_check.DEFAULT_MARKER
parse_capture_stats = capture_check.parse_stats
image_ok = capture_check.image_ok

DEFAULT_SOURCE = HERE / "test_project"
DEFAULT_BINARY = ROOT / "hddagi-build" / "godot-dynamic_gi_2" / "bin" / "godot.macos.editor.dev.arm64"

ERROR_PATTERNS = (
    "SCRIPT ERROR:",
    "SHADER ERROR:",
    "ERROR:",
    "Failed loading resource:",
    "Failed to load",
    "Can't open file",
    "Failed to compile",
)


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def tree_manifest(root: Path, exclude: tuple = (".godot",)) -> dict:
    out = {}
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(root).as_posix()
        if any(part in exclude for part in Path(rel).parts):
            continue
        out[rel] = sha256_file(p)
    return out


def manifest_digest(manifest: dict) -> str:
    h = hashlib.sha256()
    for rel in sorted(manifest):
        h.update(rel.encode())
        h.update(b"\0")
        h.update(manifest[rel].encode())
        h.update(b"\n")
    return h.hexdigest()


def run(cmd, log_path: Path, timeout: int, env=None) -> dict:
    started = time.time()
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=timeout, env=env, text=True, errors="replace",
        )
        output = proc.stdout
        code = proc.returncode
        timed_out = False
    except subprocess.TimeoutExpired as e:
        output = (e.stdout or "")
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        code = -1
        timed_out = True
    elapsed = time.time() - started
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(output)
    errors = [ln for ln in output.splitlines() if any(p in ln for p in ERROR_PATTERNS)]
    return {
        "command": [str(c) for c in cmd],
        "exit_code": code,
        "timed_out": timed_out,
        "elapsed_s": round(elapsed, 3),
        "log": str(log_path),
        "error_lines": errors,
        "output": output,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, type=Path)
    ap.add_argument("--app-label", default=None,
                    help="path to record in the manifest when --app is a staging copy")
    ap.add_argument("--source", default=DEFAULT_SOURCE, type=Path)
    ap.add_argument("--binary", default=DEFAULT_BINARY, type=Path)
    ap.add_argument("--json", type=Path)
    ap.add_argument("--markdown", type=Path)
    ap.add_argument("--log-dir", type=Path)
    ap.add_argument("--trees", default=1500, type=int)
    ap.add_argument("--skip-rendered", action="store_true")
    ap.add_argument("--timeout", default=600, type=int)
    args = ap.parse_args()

    app = args.app.resolve()
    source = args.source.resolve()
    binary = args.binary.resolve()
    log_dir = (args.log_dir or (app.parent / "verify_logs")).resolve()
    log_dir.mkdir(parents=True, exist_ok=True)

    failures = []
    notes = []
    limitations = []

    def check(ok: bool, msg: str) -> None:
        print(("ok    " if ok else "FAIL  ") + msg)
        if not ok:
            failures.append(msg)

    if not app.is_dir():
        print(f"FAIL  bundle not found: {app}", file=sys.stderr)
        return 1

    contents = app / "Contents"
    macos = contents / "MacOS"
    project = contents / "Resources" / "project"
    app_binary = macos / "godot"
    launcher = macos / "launch"
    plist = contents / "Info.plist"

    # 1. Structure ---------------------------------------------------------
    check(plist.is_file(), "Info.plist exists")
    if plist.is_file():
        info = plistlib.loads(plist.read_bytes())
        check(info.get("CFBundleExecutable") == "launch",
              f"CFBundleExecutable is launch (got {info.get('CFBundleExecutable')!r})")
    check(launcher.is_file() and os.access(launcher, os.X_OK), "launch script is executable")
    check(app_binary.is_file() and os.access(app_binary, os.X_OK), "engine binary is executable")
    check(project.is_dir(), "embedded project directory exists")
    if failures:
        print("structure is broken; stopping", file=sys.stderr)
        return 1

    # 2. Engine binary -----------------------------------------------------
    binary_sha = sha256_file(binary)
    app_sha = sha256_file(app_binary)
    check(app_sha == binary_sha,
          f"engine binary matches the build ({app_sha[:16]} vs {binary_sha[:16]})")

    # 3. Project files -----------------------------------------------------
    src_manifest = tree_manifest(source)
    bnd_manifest = tree_manifest(project)

    missing = sorted(set(src_manifest) - set(bnd_manifest))
    differing = sorted(f for f in set(src_manifest) & set(bnd_manifest)
                       if src_manifest[f] != bnd_manifest[f])
    extras = sorted(set(bnd_manifest) - set(src_manifest))

    check(not missing, f"no source file missing from the bundle ({len(missing)} missing)")
    check(not differing, f"all source files identical in the bundle ({len(differing)} differ)")
    unexpected = []
    for f in extras:
        base = f[:-4] if f.endswith(".uid") else None
        if base is None or base not in src_manifest:
            unexpected.append(f)
    check(not unexpected, f"extras are only generated .uid siblings ({len(unexpected)} unexpected)")

    src_digest = manifest_digest(src_manifest)
    bnd_digest = manifest_digest(bnd_manifest)

    # 4. Import cache ------------------------------------------------------
    import_files = sorted(project.rglob("*.import"))
    dest_checked = 0
    dest_missing = []
    source_missing = []
    for imp in import_files:
        text = imp.read_text(errors="replace")
        for m in re.finditer(r'^dest_files=\[(.*?)\]', text, re.MULTILINE):
            for raw in m.group(1).split(","):
                raw = raw.strip().strip('"')
                if not raw.startswith("res://"):
                    continue
                rel = raw[len("res://"):]
                dest_checked += 1
                if not (project / rel).is_file():
                    dest_missing.append(rel)
        for m in re.finditer(r'^source_file="res://(.*?)"', text, re.MULTILINE):
            rel = m.group(1)
            if not (project / rel).is_file():
                source_missing.append(rel)

    check(dest_checked > 0, f"import cache was generated ({dest_checked} dest files checked)")
    check(not dest_missing, f"every .import dest_file exists ({len(dest_missing)} missing)")
    check(not source_missing, f"every .import source_file exists ({len(source_missing)} missing)")

    # 5. Headless startup --------------------------------------------------
    headless = run(
        [str(app_binary), "--headless", "--path", str(project), "--quit-after", "3"],
        log_dir / "headless.log", timeout=180,
    )
    check(headless["exit_code"] == 0, f"headless startup exits 0 (got {headless['exit_code']})")
    check("HDDAGI_SMOKE_READY" in headless["output"], "headless startup reaches HDDAGI_SMOKE_READY")
    check(not headless["error_lines"],
          f"headless startup logs no errors ({len(headless['error_lines'])} found)")

    # 6. Rendered Metal run ------------------------------------------------
    rendered = {"ran": False}
    if args.skip_rendered:
        limitations.append("rendered smoke skipped with --skip-rendered")
        notes.append("rendered smoke skipped; shader/lighting correctness not verified")
    else:
        cap_dir = log_dir / "captures"
        cap_dir.mkdir(parents=True, exist_ok=True)
        normal = cap_dir / "normal.png"
        debug = cap_dir / "debug.png"
        env = os.environ.copy()
        env["HDDAGI_CAPTURE"] = "1"
        env["HDDAGI_TREES"] = str(args.trees)
        env["HDDAGI_CAPTURE_NORMAL"] = str(normal)
        env["HDDAGI_CAPTURE_DEBUG"] = str(debug)
        r = run([str(launcher)], log_dir / "rendered.log", timeout=args.timeout, env=env)
        stats = parse_capture_stats(r["output"])
        normal_stats = next((s for s in stats if s["path"] == str(normal)), None)
        debug_stats = next((s for s in stats if s["path"] == str(debug)), None)

        check(r["exit_code"] == 0, f"rendered run exits 0 (got {r['exit_code']})")
        check(not r["error_lines"], f"rendered run logs no errors ({len(r['error_lines'])} found)")
        check(normal.is_file(), "normal capture was written")
        check(debug.is_file(), "debug capture was written")
        check(normal_stats is not None, "normal capture reported stats")
        check(debug_stats is not None, "debug capture reported stats")
        if normal_stats:
            ok, why = image_ok(normal_stats, "normal")
            check(ok, f"normal capture has rendered contrast ({why})")
        if debug_stats:
            ok, why = image_ok(debug_stats, "debug")
            check(ok, f"debug capture has voxel contrast ({why})")
        rendered = {
            "ran": True,
            "trees": args.trees,
            "exit_code": r["exit_code"],
            "elapsed_s": r["elapsed_s"],
            "normal": normal_stats,
            "debug": debug_stats,
            "log": r["log"],
        }

    # Manifest -------------------------------------------------------------
    def git(*a):
        try:
            return subprocess.run(["git", "-C", str(WORKSPACE), *a],
                                  capture_output=True, text=True).stdout.strip()
        except Exception:
            return ""

    manifest = {
        "verified_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "app": str(args.app_label) if args.app_label else str(app),
        "app_size_bytes": sum(p.stat().st_size for p in app.rglob("*") if p.is_file()),
        "source": str(source),
        "source_commit": git("rev-parse", "HEAD"),
        "source_dirty": bool(git("status", "--porcelain")),
        "engine_binary": {
            "path": str(binary),
            "sha256": binary_sha,
            "size_bytes": binary.stat().st_size,
            "mtime": datetime.fromtimestamp(binary.stat().st_mtime, timezone.utc).isoformat(timespec="seconds"),
        },
        "app_binary": {"path": str(app_binary), "sha256": app_sha, "size_bytes": app_binary.stat().st_size},
        "project": {
            "source_files": len(src_manifest),
            "bundle_files": len(bnd_manifest),
            "source_manifest_sha256": src_digest,
            "bundle_manifest_sha256": bnd_digest,
            "missing": missing,
            "differing": differing,
            "unexpected_extras": unexpected,
            "generated_uid_extras": [f for f in extras if f.endswith(".uid")],
        },
        "imports": {
            "import_files": len(import_files),
            "dest_files_checked": dest_checked,
            "dest_missing": dest_missing,
            "source_missing": source_missing,
        },
        "headless": {k: v for k, v in headless.items() if k != "output"},
        "rendered": rendered,
        "failures": failures,
        "notes": notes,
        "limitations": limitations,
        "ok": not failures,
    }

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(manifest, indent=2) + "\n")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# HDDAGI.app verification",
            "",
            f"Verified `{manifest['verified_at']}` from commit `{manifest['source_commit']}`"
            f"{' (dirty tree)' if manifest['source_dirty'] else ''}.",
            "",
            "| check | result |",
            "|---|---|",
            f"| engine binary sha256 | `{binary_sha}` |",
            f"| bundle binary matches build | {'yes' if app_sha == binary_sha else 'NO'} |",
            f"| source files in bundle | {len(src_manifest) - len(missing)}/{len(src_manifest)} |",
            f"| files differing | {len(differing)} |",
            f"| unexpected extra files | {len(unexpected)} |",
            f"| .import dest files present | {dest_checked - len(dest_missing)}/{dest_checked} |",
            f"| headless startup | exit {headless['exit_code']}, "
            f"{len(headless['error_lines'])} error lines |",
            f"| rendered smoke | {'skipped' if args.skip_rendered else f'ran, {args.trees} trees, exit ' + str(rendered.get('exit_code'))} |",
        ]
        if rendered.get("normal"):
            n = rendered["normal"]
            lines.append(f"| normal capture | {n['width']}x{n['height']}, "
                         f"min {n['min']}, max {n['max']}, mean {n['mean']} |")
        if rendered.get("debug"):
            d = rendered["debug"]
            lines.append(f"| debug capture | {d['width']}x{d['height']}, max {d['max']} |")
        lines += [
            "",
            f"**Result: {'PASS' if not failures else 'FAIL'}**",
            "",
        ]
        if failures:
            lines += ["Failures:", ""] + [f"- {f}" for f in failures] + [""]
        if limitations:
            lines += ["Limitations:", ""] + [f"- {x}" for x in limitations] + [""]
        lines += [
            "Logs: `headless.log`, `rendered.log` and `captures/` sit next to this report.",
            "",
        ]
        args.markdown.write_text("\n".join(lines))

    print()
    print(f"{'PASS' if not failures else 'FAIL'}: {len(failures)} failed check(s)")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
