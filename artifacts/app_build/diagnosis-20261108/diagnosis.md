# Staged package startup diagnosis, 2026-11-08

The 013416 validation terminated with SIGTERM (-15) after 59.119 seconds. Its
headless check, import inventory and source/binary parity passed, but neither
rendered capture was reached. Its verifier timeout was 600 seconds, so the
record does not establish that the verifier itself initiated that termination.
The sender of SIGTERM remains unknown.

A separate manually staged run recorded in `/tmp/stage_run.json` timed out at
60.026 seconds (exit 124). Its import completed and scene startup reached
HDDAGI_SMOKE_READY with dense lighting, but no capture.

After confirming no competing Godot build/test process, an isolated retry used
that manual stage and a 180-second bound. It completed in 46.589 seconds, exit 0,
with both 1600x900 captures. The first restricted-shell invocation had aborted
with -6 before logging; the desktop-enabled invocation is the successful result.
See stage-unrestricted.log and stage-unrestricted.json. Diagnostic PNGs are stored
under captures/ (the log records their original location before organizing them).

The live stack sample (stage.sample.txt) shows the main render thread waiting in
PipelineHashMapRD::wait_for_pipeline / WorkerThreadPool::wait_for_task_completion,
with Metal compiler IPC waits. Two compiler services were using about 100% CPU
each. This supports pipeline compilation as the delay in the observed retry,
not a proven deadlock or shader compilation error. It does not identify who
terminated the previous process. A later compiler sample during packaging caught
an idle service and is not evidence of a persistent hang.

The normal capture was visually inspected: a textured forest, shadows and fog
are rendered, rather than a blank or untextured frame. The fresh package run
20261108-014308 then passed all 23 validation checks. It spent 101.681 seconds
in the rendered smoke and preserved the old app before installing the new one.
No source-code fix or relaxed acceptance criterion was required.

Independent checks: all 14 capture-parser/image unit tests passed; all 11
engine-copy/patch consistency checks passed; bash syntax checks passed for the
packager, benchmark runner and failure-injection script. The complete failure-
injection suite was not rerun as part of this diagnosis.

These startup durations are materially longer than the older ~10-second cold
startup results; they are different binaries/scenarios and must not be conflated
with those results. Cold-cache behavior and startup usability remain performance
work, even though packaging correctness now passes.

Final installed-path revalidation also passed all 23 checks, including the rendered
1,500-tree smoke in 11.441 seconds. See
`app_build/20261108-014308/installed-manifest.json` and `installed-report.md`.
