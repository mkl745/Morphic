#!/usr/bin/env python3
"""Regression coverage for the emulator's synthetic source-to-row check."""
import unittest

from check_sample_row import check_row


class SampleRowTest(unittest.TestCase):
    def test_ranked_columns_are_compared_by_name_not_position(self):
        ok, _ = check_row(
            "Row 1: time: 2026-11-05T14:00:02.000Z, level: ERROR, "
            "latency_ms: 128, service: auth, message: Upstream timeout"
        )
        self.assertTrue(ok)

    def test_real_emulator_misassociation_is_rejected(self):
        ok, reason = check_row(
            "Row 1: time: 2026-11-05T14:00:02.000Z, level: ERROR, "
            "latency_ms: auth, service: Upstream timeout, message: 128"
        )
        self.assertFalse(ok)
        self.assertIn("fields do not match", reason)

    def test_later_page_uses_the_record_at_its_offset(self):
        ok, _ = check_row(
            "Row 257: time: 2026-11-05T14:10:32.000Z, level: DEBUG, "
            "latency_ms: 24, service: auth, message: Query plan chosen"
        )
        self.assertTrue(ok)

    def test_bad_row_identity_missing_or_duplicate_field_fails(self):
        for signature in (
            "Row 0: time: no",
            "Row 601: time: no",
            "record 1: time: no",
            "Row 1: time: 2026-11-05T14:00:02.000Z",
            "Row 1: level: ERROR, level: ERROR",
        ):
            with self.subTest(signature=signature):
                ok, _ = check_row(signature)
                self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()
