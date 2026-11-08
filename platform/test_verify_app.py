#!/usr/bin/env python3
"""Regression tests for the app verifier's capture parsing and image checks.

Run with:
    python3 platform/test_verify_app.py

The spaced path is not hypothetical: this workspace lives under
"/Users/.../godot upgraded ", and a whitespace-splitting parser silently dropped
every capture line, which made a rendered smoke fail for the wrong reason.
"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_app  # noqa: E402

SPACED_PATH = (
    "/Users/dawsonblock/Downloads/godot upgraded /hddagi-run/"
    "HDDAGI.app.staging.81338/artifacts/app_build/20260101-000000/captures/normal.png"
)


def stats(min_v=23, max_v=235, mean=98.54):
    return {
        "path": SPACED_PATH,
        "width": 1622,
        "height": 1017,
        "min": min_v,
        "max": max_v,
        "mean": mean,
        "range": max_v - min_v,
    }


class ParseCaptureStatsTest(unittest.TestCase):
    def line(self, payload):
        return "CAPTURE_STATS " + json.dumps(payload)

    def test_path_with_spaces_round_trips(self):
        out = "some log noise\n" + self.line(stats()) + "\nCAPTURED_NORMAL\n"
        parsed = verify_app.parse_capture_stats(out)
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["path"], SPACED_PATH)
        self.assertEqual(parsed[0]["max"], 235)

    def test_multiple_captures(self):
        second = stats(max_v=128, mean=10.78)
        second["path"] = SPACED_PATH.replace("normal", "debug")
        out = self.line(stats()) + "\n" + self.line(second)
        parsed = verify_app.parse_capture_stats(out)
        self.assertEqual([p["path"] for p in parsed],
                         [SPACED_PATH, SPACED_PATH.replace("normal", "debug")])

    def test_malformed_payload_is_ignored(self):
        self.assertEqual(verify_app.parse_capture_stats("CAPTURE_STATS {not json"), [])

    def test_missing_fields_is_ignored(self):
        self.assertEqual(verify_app.parse_capture_stats("CAPTURE_STATS {\"path\": \"x\"}"), [])

    def test_no_stats(self):
        self.assertEqual(verify_app.parse_capture_stats("CAPTURED_NORMAL only"), [])


class ImageCheckTest(unittest.TestCase):
    def test_normal_rendered_frame_passes(self):
        ok, why = verify_app.image_ok(stats(), "normal")
        self.assertTrue(ok, why)

    def test_dark_but_contrasty_frame_passes(self):
        # A viewpoint under the canopy: mean 19, full range. This is rendered, not
        # blank, and used to be rejected by a mean>=20 threshold.
        ok, why = verify_app.image_ok(stats(min_v=0, max_v=246, mean=19.02), "normal")
        self.assertTrue(ok, why)

    def test_black_frame_rejected(self):
        ok, why = verify_app.image_ok(stats(min_v=0, max_v=0, mean=0.0), "normal")
        self.assertFalse(ok)
        self.assertIn("dark", why)

    def test_solid_white_frame_rejected(self):
        ok, why = verify_app.image_ok(stats(min_v=255, max_v=255, mean=255.0), "normal")
        self.assertFalse(ok)
        self.assertIn("flat", why)

    def test_solid_grey_frame_rejected(self):
        ok, why = verify_app.image_ok(stats(min_v=128, max_v=128, mean=128.0), "normal")
        self.assertFalse(ok)
        self.assertIn("flat", why)

    def test_low_contrast_frame_rejected(self):
        ok, why = verify_app.image_ok(stats(min_v=100, max_v=120, mean=110.0), "normal")
        self.assertFalse(ok)
        self.assertIn("flat", why)

    def test_debug_voxel_frame_passes(self):
        ok, why = verify_app.image_ok(stats(min_v=0, max_v=128, mean=10.78), "debug")
        self.assertTrue(ok, why)

    def test_debug_blank_rejected(self):
        ok, why = verify_app.image_ok(stats(min_v=0, max_v=0, mean=0.0), "debug")
        self.assertFalse(ok)

    def test_missing_stats_rejected(self):
        ok, why = verify_app.image_ok(None, "normal")
        self.assertFalse(ok)
        self.assertIn("no stats", why)


if __name__ == "__main__":
    unittest.main(verbosity=2)
