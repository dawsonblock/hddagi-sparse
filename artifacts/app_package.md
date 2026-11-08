# Packaged app provenance

The double-clickable bundle is `../hddagi-run/HDDAGI.app`. It is generated, never
hand-edited: `platform/make_mac_app.sh` assembles it in a staging directory, validates
it there, and only then swaps it in. The previous bundle is kept as
`HDDAGI.app.bak-<stamp>`.

## Current package: 20261108-024210

Repackaged and validated on 2026-11-08 after the controlled-matrix pass: the only
project change since the 014308 package is `bench.gd` (frame-indexed trajectory,
run_kind/timing_usable, effective settings/trajectory fields, MSAA value). All 23
staged checks pass including the rendered 1,500-tree scene; the prior app is
preserved as `../hddagi-run/HDDAGI.app.bak-20261108-024210`.

- Engine SHA256: `a3e594ca1e6748c5506f50e1962b6a31042f1ed508022589f7bf1eb40532c59b`
  (unchanged — no engine source was touched in the matrix pass).
- Detailed provenance: `app_build/20261108-024210/manifest.json`, `report.md`,
  and installed-path revalidation `installed-manifest.json` / `installed-report.md`.

## Earlier package: 20261108-014308

Repackaged and validated on 2026-11-08 after the interrupted 013416 attempt.
All 23 staged checks pass, including the rendered 1,500-tree scene. The live app
was replaced only after validation; the prior app is preserved as
`../hddagi-run/HDDAGI.app.bak-20261108-014308`.

- Engine SHA256: `a3e594ca1e6748c5506f50e1962b6a31042f1ed508022589f7bf1eb40532c59b`.
- Source and embedded project manifest SHA256:
  `56f0a387a960112cd9782bb42c03acd9399d6280ce225149b9ae10624bba1b56`.
- 107/107 source files identical, no extras, all 21 imported destination files present.
- Headless and rendered startup exit 0 with no detected errors. Normal capture:
  1600x900, range 203, mean 89.77. Debug capture: range 123.
- Rendered smoke took **101.681 s** at the new staging path. A separate staged
  diagnostic capture took 46.589 s. These are whole smoke-test durations, not FPS
  or time-to-first-frame measurements.
- Detailed provenance: `app_build/20261108-014308/manifest.json` and `report.md`.
- Diagnosis: `app_build/diagnosis-20261108/diagnosis.md`.

No renderer source was changed during this recovery. Sparse lighting remains
probe-only, as documented in `sparse_status.md`.


Final installed-path revalidation also passed all 23 checks, including the rendered
1,500-tree smoke in 11.441 seconds. See
`app_build/20261108-014308/installed-manifest.json` and `installed-report.md`.

## Earlier verified package: 20261108-010730

| field | value |
|---|---|
| build stamp | `20261108-010730` |
| source commit | `f73568d20e3741ea8a274062f435b512ad2cc1c0` (tree dirty at build time: the changes in this session) |
| engine binary | `29fa35ed5bc45167ed2e23368a82ecef49f029dd83fb9c31946bbf714eb77a9e` |
| source project manifest | `1ddf486a11017d7991890fd08db14a54333e2374399a5abc8e583c5b0d460f65` |
| embedded project manifest | `1ddf486a11017d7991890fd08db14a54333e2374399a5abc8e583c5b0d460f65` (identical) |
| project files | 107 source, 107 embedded, 0 differing, 0 unexpected extras |
| imported dest files | 21/21 present |
| previous bundle | `../hddagi-run/HDDAGI.app.bak-20261108-010730` |

The two manifest digests are equal, so the embedded project is byte-for-byte the source
project apart from the regenerated `.godot` import cache (and `.uid` siblings, which are
present in both).

## Verification performed

`platform/verify_app.py` ran 23 checks and passed all of them:

- bundle structure (`Info.plist`, `CFBundleExecutable=launch`, executable launcher)
- `Contents/MacOS/godot` sha256 equals the build-tree binary
- every source file present and identical; no unexpected extras
- every `.import` `dest_file` and `source_file` present
- headless startup: exit 0, reaches `HDDAGI_SMOKE_READY`, no error lines
- rendered Metal run at the packaged default of **1,500 trees**: exit 0, no error
  lines, normal capture 1623x1017 with range 203 and mean 91.8, debug capture with
  range 122. A flat or uniform capture is rejected, so a missing import or dead shader
  cannot pass as a "fast" run.

Logs, the manifest and the report are in `artifacts/app_build/20261108-010730/`.
The two PNGs are kept locally but gitignored (3.1 MB per build).

## Reproducing

```bash
cd hddagi-sparse
./platform/make_mac_app.sh --trees 1500     # stage, validate, swap, keep previous
./platform/test_verify_app.py               # parser and image-check regressions
python3 platform/verify_app.py \
  --app "../hddagi-run/HDDAGI.app" --json /tmp/manifest.json --markdown /tmp/report.md \
  --log-dir /tmp/verify --trees 1500        # re-verify an installed bundle
```

## Known limitations

- The bundle embeds `godot.macos.editor.dev.arm64`, an editor/dev build, not a release
  export template. It is 270 MB and carries editor code.
- The bundle is ad-hoc: no code signing, no notarization, no hardened runtime.
- The import cache is regenerated inside each bundle rather than copied, so the bundle
  is reproducible only as far as Godot's importer is.
- `open HDDAGI.app` swallows stdout. For logs, launch
  `HDDAGI.app/Contents/MacOS/launch` from a terminal.
- Verification is machine-specific: it proves this bundle matches this source and this
  engine binary on this Mac. It does not prove the app runs on another machine.
