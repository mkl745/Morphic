#!/usr/bin/env python3
"""Regression tests for the device-smoke workspace swipe helper."""
import io
import os
import sys
import tempfile
import unittest
from unittest import mock

import swipe_workspace as swipe


class WorkspaceSwipeTest(unittest.TestCase):
    def test_coordinates_follow_screen_bounds_and_stay_in_leading_gutter(self):
        self.assertEqual(swipe.swipe_coordinates("[0,0][1080,2160]"), (10, 1728, 10, 864))
        self.assertEqual(swipe.swipe_coordinates("[4,20][724,1300]"), (11, 1044, 11, 532))
        self.assertEqual(swipe.swipe_coordinates("[0,0][320,400]"), (3, 320, 3, 160))

    def test_invalid_bounds_are_rejected(self):
        for bounds in ("", "[0,0][0,100]", "[0,0][100,0]", "not bounds"):
            with self.subTest(bounds=bounds), self.assertRaises(ValueError):
                swipe.swipe_coordinates(bounds)

    def test_dump_drives_the_selected_device(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".xml") as dump:
            dump.write('<hierarchy><node bounds="[0,0][1080,2160]" /></hierarchy>')
            dump.flush()
            with mock.patch.object(sys, "argv", ["swipe_workspace.py", dump.name]), \
                 mock.patch.dict(os.environ, {"MORPHIC_ADB_SERIAL": "device-123"}), \
                 mock.patch("sys.stdout", new_callable=io.StringIO), \
                 mock.patch.object(swipe.subprocess, "run") as run:
                self.assertEqual(swipe.main(), 0)
        run.assert_called_once_with(
            ["adb", "-s", "device-123", "shell", "input", "swipe", "10", "1728", "10", "864", "300"],
            check=True,
        )

    def test_invalid_xml_does_not_send_a_swipe(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".xml") as dump:
            dump.write("<hierarchy/>")
            dump.flush()
            with mock.patch.object(sys, "argv", ["swipe_workspace.py", dump.name]), \
                 mock.patch("sys.stderr", new_callable=io.StringIO), \
                 mock.patch.object(swipe.subprocess, "run") as run:
                self.assertEqual(swipe.main(), 1)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
