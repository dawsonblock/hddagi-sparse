# HDDAGI.app verification

Verified `2026-11-08T07:35:27+00:00` from commit `f73568d20e3741ea8a274062f435b512ad2cc1c0` (dirty tree).

| check | result |
|---|---|
| engine binary sha256 | `a3e594ca1e6748c5506f50e1962b6a31042f1ed508022589f7bf1eb40532c59b` |
| bundle binary matches build | yes |
| source files in bundle | 107/107 |
| files differing | 0 |
| unexpected extra files | 0 |
| .import dest files present | 21/21 |
| headless startup | exit 0, 0 error lines |
| rendered smoke | ran, 1500 trees, exit -15 |

**Result: FAIL**

Failures:

- rendered run exits 0 (got -15)
- normal capture was written
- debug capture was written
- normal capture reported stats
- debug capture reported stats

Logs: `headless.log`, `rendered.log` and `captures/` sit next to this report.
