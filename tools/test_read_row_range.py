#!/usr/bin/env python3
"""Keep table semantics compatible with the device-smoke XML reader."""
import contextlib
import io
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest import mock

import read_row_range as reader


class RowRangeTest(unittest.TestCase):
    @staticmethod
    def read_xml(xml: str, *flags: str) -> str:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".xml") as dump:
            dump.write(xml)
            dump.flush()
            with mock.patch.object(sys, "argv", ["read_row_range.py", dump.name, *flags]):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    result = reader.main()
        if result != 0:
            raise AssertionError(f"unexpected reader exit: {result}")
        return output.getvalue().strip()

    def test_named_columns_and_encoded_range_are_extracted(self):
        xml = '''<hierarchy>
          <node text="Records 600" content-desc="" />
          <node content-desc="Row 1: region: eu, amount: 10, note: No value" />
          <node content-desc="1&#8211;256 of 600" />
        </hierarchy>'''
        self.assertEqual(self.read_xml(xml), "1-256 of 600")
        self.assertEqual(
            self.read_xml(xml, "--signature"),
            "Row 1: region: eu, amount: 10, note: No value",
        )

    def test_new_page_has_a_different_first_row_signature(self):
        first = '<hierarchy><node content-desc="Row 1: note: Empty string" /></hierarchy>'
        next_page = '<hierarchy><node content-desc="Row 257: note: Empty string" /></hierarchy>'
        self.assertNotEqual(self.read_xml(first, "--signature"), self.read_xml(next_page, "--signature"))

    def test_text_and_escaped_content_description_are_supported(self):
        xml = '''<hierarchy>
          <node text="Row 2: region: us, note: Alice &amp; Bob" />
          <node text="257–512 of 1,000" />
        </hierarchy>'''
        self.assertEqual(self.read_xml(xml), "257-512 of 1,000")
        self.assertEqual(self.read_xml(xml, "--signature"), "Row 2: region: us, note: Alice & Bob")

    def test_missing_row_is_not_invented_from_a_metric_or_pager(self):
        tree = ET.ElementTree(ET.fromstring('<hierarchy><node text="600 rows"/><node text="0 of 0"/></hierarchy>'))
        self.assertEqual(reader.first_data_row(tree), "")
        self.assertEqual(self.read_xml('<hierarchy><node text="0 of 0"/></hierarchy>'), "0 of 0")
        self.assertEqual(self.read_xml('<hierarchy><node text="no page"/></hierarchy>'), "")


if __name__ == "__main__":
    unittest.main()
