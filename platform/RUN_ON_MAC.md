# Running on this Mac

The fork builds and runs natively here. Nothing below needs Windows, Vulkan, or a
GPU other than the one in the machine.

## The app

```
platform/make_mac_app.sh --open
```

Builds `../hddagi-run/HDDAGI.app` (about 257 MB: the engine binary plus the embedded
project) and launches it. The window shows a forest rendered with HDDAGI enabled.

The script builds into a staging directory and validates it there before replacing the
live bundle: engine binary hash, every embedded source file, the import cache, a
headless startup and a rendered Metal run at the packaged 1,500-tree default. The
previous bundle is kept as `HDDAGI.app.bak-<stamp>` rather than deleted. The report and
manifest land in `artifacts/app_build/<stamp>/`; `artifacts/app_package.md` records the
current package.

`--skip-rendered` skips the windowed check where there is no display (and records that
in the manifest). `--trees N` changes the smoke-test density.

Density and behaviour come from the environment, which is awkward to set for a
double-clicked app, so the launcher defaults to `HDDAGI_TREES=1500` and interactive
mode. To change them, launch from a terminal instead:

```bash
HDDAGI_TREES=4000 "../hddagi-run/HDDAGI.app/Contents/MacOS/launch"
```

`HDDAGI_TREES=0` gives the empty room instead of the forest.

To re-verify an installed bundle without rebuilding:

```bash
python3 platform/verify_app.py --app "../hddagi-run/HDDAGI.app" \
  --json /tmp/manifest.json --markdown /tmp/report.md --log-dir /tmp/verify --trees 1500
```

## Seeing the sparse self-test

The app's stdout is swallowed by `open`. To watch the engine-side sparse test run,
launch from a terminal:

```bash
HDDAGI_TREES=0 "../hddagi-build/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64" \
  --path platform/test_project --quit-after 60
```

Expected output:

```
HDDAGI sparse probe: SUPPORTED (check 0) - all capability checks passed
HDDAGI sparse self-test: PASS
  probe   : 1180 records, 0 mismatches, first_bad=-1
  canary  : 524288 texels, 0 mismatches
  alloc   : compacted=300 allocated=256 overflow=44 committed=256 duplicates=0
```

## Distance LOD

The forest draws three distance rings: lod0 under 35 m, lod1 from 35 to 75 m, lod2
beyond that, and trees past 75 m do not cast shadows. At 1,500 trees this is -21.8%
frame time for 0.8% of pixels changing by more than 8/255 (`artifacts/lod.md`).

```bash
HDDAGI_LOD=0            # every tree at lod0
HDDAGI_SHADOW_LOD=off   # restore all tree shadows (far/near/off)
HDDAGI_LOD_MID=50       # aggressive: no shadows past 50 m
```

## Capturing frames

`HDDAGI_CAPTURE=1` makes the scene write `/tmp/hddagi_normal.png` and
`/tmp/hddagi_debug.png` (the latter is `DEBUG_DRAW_HDDAGI`, which draws the voxel
volume) and then exit. Useful for comparing a change against a baseline.

## Editing the scene

`platform/test_project/` is a normal Godot project. Open it with the built editor:

```bash
"../hddagi-build/godot-dynamic_gi_2/bin/godot.macos.editor.dev.arm64" \
  --path platform/test_project --editor
```

Changing anything in `platform/test_project/` requires re-running
`make_mac_app.sh` to get it into the bundle, because the bundle embeds a copy.

## What you are looking at

- Backend: Metal 4, Forward+.
- HDDAGI: 6 cascades, 16x8x16 format, 0.2 m minimum cell size.
- The light-process buffers are sized at `solid_cell_ratio = 0.10` in this project,
  which is the measured-safe value for this scene, not the engine default of 0.25.

This is the dense HDDAGI path. The sparse-brick work runs as a self-test at startup;
it does not render anything yet.
