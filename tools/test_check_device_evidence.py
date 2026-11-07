#!/usr/bin/env python3
"""Tests for the AT-07 evidence gate.

The gate is the last thing standing between an unmeasured latency claim and a milestone marked
complete. These cases are the ways a green-looking file could still be worthless: an emulator, a
rehearsal, a table too small to be the one AT-07 names, a median hiding a slow frame, a budget
quietly loosened, or a verdict that contradicts its own samples.

Run: python3 tools/test_check_device_evidence.py
"""
from __future__ import annotations

import copy
import importlib.util
import pathlib
import unittest

_SPEC = importlib.util.spec_from_file_location(
    "gate", pathlib.Path(__file__).with_name("check_device_evidence.py")
)
gate = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(gate)

VERSION = "0.1.0"


def honest() -> dict:
    """A file that should qualify: real phone, 100k rows, every sample under the ceiling."""
    return {
        "schema": "morphic/perf-evidence/1",
        "appVersion": VERSION,
        "physicalDevice": True,
        "rehearsal": False,
        "at07Evidence": True,
        "gitSha": "abc1234",
        "device": {"class": "mid", "model": "RMX3830", "abi": "arm64-v8a"},
        "probe": {
            "schema": "morphic/perf-probe/1",
            "representative": True,
            "passes": True,
            "rowCount": 100000,
            "budgetMs": 150.0,
            "worstMs": 132.4,
            "samples": [{"ms": m} for m in (90, 101, 110, 120, 132.4, 95, 102)],
        },
    }


class At07Gate(unittest.TestCase):
    def reasons(self, **patch) -> list[str]:
        doc = honest()
        probe_patch = patch.pop("probe", None)
        doc.update(patch)
        if probe_patch is not None:
            doc["probe"].update(probe_patch)
        return gate.qualifies_at07(doc, VERSION)

    def test_honest_evidence_qualifies(self):
        self.assertEqual(self.reasons(), [])

    def test_emulator_is_rejected(self):
        self.assertIn("not a physical device", self.reasons(physicalDevice=False))

    def test_rehearsal_is_rejected_even_on_real_hardware(self):
        self.assertIn("marked as a rehearsal", self.reasons(rehearsal=True))

    def test_unmarked_evidence_is_rejected(self):
        self.assertIn("not marked as AT-07 evidence", self.reasons(at07Evidence=False))

    def test_small_table_is_rejected(self):
        # The 600-row device sample would pass the timing easily and prove nothing.
        reasons = self.reasons(probe={"rowCount": 600, "representative": False})
        self.assertTrue(any("600" in r for r in reasons), reasons)

    def test_row_count_cannot_lie_about_representativeness(self):
        # The flag says yes but the count says no. The count wins: the gate re-checks the
        # arithmetic instead of trusting a boolean a buggy recorder could have set.
        reasons = self.reasons(probe={"rowCount": 600, "representative": True})
        self.assertTrue(any("600" in r for r in reasons), reasons)

    def test_missing_row_count_is_rejected(self):
        reasons = self.reasons(probe={"rowCount": None})
        self.assertTrue(any("below AT-01" in r for r in reasons), reasons)

    def test_slow_worst_sample_is_rejected(self):
        reasons = self.reasons(probe={"worstMs": 400.0, "passes": False})
        self.assertTrue(any("400.0" in r for r in reasons), reasons)

    def test_verdict_contradicting_its_samples_is_rejected(self):
        reasons = self.reasons(probe={"samples": [{"ms": 10}] * 6 + [{"ms": 900}]})
        self.assertTrue(any("contradict" in r or "exceeds 150" in r for r in reasons), reasons)

    def test_loosened_budget_is_rejected(self):
        reasons = self.reasons(probe={"budgetMs": 500.0})
        self.assertTrue(any("looser" in r for r in reasons), reasons)

    def test_too_few_samples_is_rejected(self):
        reasons = self.reasons(probe={"samples": [{"ms": 10}] * 3})
        self.assertTrue(any("at least 5" in r for r in reasons), reasons)

    def test_missing_timings_is_rejected(self):
        reasons = self.reasons(probe={"worstMs": None})
        self.assertTrue(any("timings missing" in r for r in reasons), reasons)

    def test_missing_sha_is_rejected(self):
        self.assertIn("git sha not recorded", self.reasons(gitSha=""))

    def test_other_version_is_rejected(self):
        reasons = self.reasons(appVersion="0.2.0")
        self.assertTrue(any("0.2.0" in r for r in reasons), reasons)

    def test_functional_evidence_is_not_perf_evidence(self):
        doc = honest()
        doc["schema"] = "morphic/device-evidence/1"
        self.assertEqual(gate.qualifies_at07(doc, VERSION), ["not perf evidence"])

    def test_exactly_on_the_ceiling_qualifies(self):
        doc = honest()
        doc["probe"]["worstMs"] = 150.0
        doc["probe"]["samples"] = [{"ms": 150.0}] * 5
        self.assertEqual(gate.qualifies_at07(doc, VERSION), [])


class FunctionalGateStillWorks(unittest.TestCase):
    def test_perf_file_does_not_satisfy_the_functional_gate(self):
        reasons = gate.qualifying(honest(), VERSION)
        self.assertIn("unknown evidence schema", reasons)


if __name__ == "__main__":
    unittest.main(verbosity=2)