#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline tests for the standalone XXMI release download wrapper."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TESTS = Path(__file__).resolve().parent
SCRIPTS = TESTS.parent


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


package_tests = _load("test_xxmi_package_fixture", TESTS / "test_xxmi_package.py")
standalone = _load("xxmi_standalone", SCRIPTS / "xxmi-standalone.py")


class StandaloneTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-standalone-tests-")
        self.root = Path(self.temp.name)
        self.fixture = package_tests.Fixture(self.root)
        self.pair = self.root / "pair"
        self.fixture.build(self.pair)
        self.notice = self.root / "NOTICE.md"
        self.notice.write_text("notice\n", encoding="utf-8")
        self.licenses = self.root / "licenses"
        self.licenses.mkdir()
        (self.licenses / "GPL-3.0.txt").write_text("gpl\n", encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def build(self, output: Path) -> Path:
        return standalone.build_standalone(self.pair, self.fixture.pins_path, output, self.notice, self.licenses)

    def test_wraps_the_verified_pair_in_one_folder_deterministically(self):
        first = self.build(self.root / "a")
        second = self.build(self.root / "b")
        self.assertEqual(first.name, "XXMI-HSR-2.4.3-macgacha.1.zip")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        folder = "XXMI-HSR-2.4.3-macgacha.1"
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(sorted(archive.namelist()), sorted([
                f"{folder}/NOTICE.md", f"{folder}/README.txt", f"{folder}/licenses/GPL-3.0.txt",
                f"{folder}/manifest.json", f"{folder}/hsr-srmi.zip",
            ]))
            self.assertEqual(archive.read(f"{folder}/hsr-srmi.zip"), (self.pair / "hsr-srmi.zip").read_bytes())
            self.assertEqual(archive.read(f"{folder}/manifest.json"), (self.pair / "manifest.json").read_bytes())
            readme = archive.read(f"{folder}/README.txt").decode("utf-8")
            self.assertIn("Import Package", readme)
            self.assertIn(folder, readme)
        sidecar = (first.parent / (first.name + ".sha256")).read_text(encoding="utf-8")
        self.assertEqual(sidecar, f"{hashlib.sha256(first.read_bytes()).hexdigest()}  {first.name}\n")

    def test_refuses_to_overwrite_and_to_wrap_a_tampered_pair(self):
        output = self.root / "out"
        self.build(output)
        with self.assertRaises(standalone.StandaloneError):
            self.build(output)
        archive = self.pair / "hsr-srmi.zip"
        archive.write_bytes(archive.read_bytes() + b"tamper")
        with self.assertRaises(standalone.xxmi_package.PackageError):
            self.build(self.root / "tampered")
        self.assertFalse((self.root / "tampered").exists() and any((self.root / "tampered").iterdir()))

    def test_readme_names_the_minimum_app_build(self):
        self.fixture.pins["package"]["minimumAppBuild"] = 9
        self.fixture.pins_path.write_text(package_tests.json.dumps(self.fixture.pins, indent=2) + "\n", encoding="utf-8")
        pair = self.root / "pinned"
        self.fixture.build(pair)
        self.pair = pair
        path = self.build(self.root / "pinned-out")
        with zipfile.ZipFile(path) as archive:
            readme = archive.read("XXMI-HSR-2.4.3-macgacha.1/README.txt").decode("utf-8")
        self.assertIn("MacGacha build 9 or later", readme)


if __name__ == "__main__":
    unittest.main()
