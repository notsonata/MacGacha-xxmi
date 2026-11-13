#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Accepted shapes of the authenticated third-party object manifest."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("xxmi_derive", Path(__file__).resolve().parents[1] / "xxmi-derive-build-plan.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ObjectManifestTests(unittest.TestCase):
    def test_list_and_build_plan_shapes(self):
        entries = [{"path": "object.obj", "sha256": "0" * 64}]
        for value in (entries, {"stage1": {"thirdPartyObjects": entries}}):
            with self.subTest(value=value):
                self.assertEqual(module.object_entries(value), entries)

    def test_invalid_shapes_fail_with_a_domain_error(self):
        for value in (None, [], 42, {}, {"stage1": []}, {"stage1": {"thirdPartyObjects": "bad"}}):
            with self.subTest(value=value):
                with self.assertRaises(module.DeriveError):
                    module.object_entries(value)

if __name__ == "__main__":
    unittest.main()
