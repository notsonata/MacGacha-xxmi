#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline tests for the experimental SRMI candidate builder's patch selection.

These tests exercise the pure helpers behind ``scripts/xxmi-build-cursor-candidate.py``:
they do not compile, link, patch, download or touch any build input. The full
build is covered by the cursor and conditional contract harnesses plus the
recorded candidate manifest.
"""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

REPO = Path(__file__).resolve().parents[2]
BUILDER = REPO / "scripts" / "xxmi-build-cursor-candidate.py"


def load_builder() -> ModuleType:
    spec = importlib.util.spec_from_file_location("xxmi_build_cursor_candidate", BUILDER)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {BUILDER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PatchPurposeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.builder = load_builder()

    def test_cursor_only_purpose_is_unchanged(self) -> None:
        self.assertEqual(
            self.builder.build_purpose([]),
            "ABI-consistent experimental SRMI candidate with patches 0001-0007 and 0009",
        )
        self.assertEqual(
            self.builder.experimental_purpose([]),
            "experimental SRMI candidate with patches 0001-0007 and 0009",
        )

    def test_conditional_purpose_lists_patch_0010(self) -> None:
        self.assertEqual(
            self.builder.build_purpose(["0010"]),
            "ABI-consistent experimental SRMI candidate with patches 0001-0007, 0009 and 0010",
        )
        self.assertEqual(
            self.builder.experimental_purpose(["0010"]),
            "experimental SRMI candidate with patches 0001-0007, 0009 and 0010",
        )

    def test_extra_patches_are_listed_in_order(self) -> None:
        self.assertEqual(
            self.builder.build_purpose(["0010", "0011"]),
            "ABI-consistent experimental SRMI candidate with patches 0001-0007, 0009, 0010 and 0011",
        )

    def test_patch_labels_come_from_four_digit_prefix(self) -> None:
        self.assertEqual(self.builder.patch_label(Path("/a/0010-foo.patch")), "0010")
        self.assertEqual(self.builder.patch_label(Path("custom.patch")), "custom.patch")


class OptionalPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.builder = load_builder()

    def test_parser_accepts_repeated_extra_patches(self) -> None:
        args = self.builder.create_parser().parse_args(
            [
                "--conditional-patch",
                "0010.patch",
                "--extra-patch",
                "0011.patch",
                "--extra-patch",
                "0012.patch",
            ]
        )
        self.assertEqual(args.conditional_patch, Path("0010.patch"))
        self.assertEqual(
            args.extra_patches, [Path("0011.patch"), Path("0012.patch")]
        )

    def test_conditional_patch_defaults_to_none(self) -> None:
        args = self.builder.create_parser().parse_args([])
        self.assertIsNone(args.conditional_patch)
        self.assertEqual(args.extra_patches, [])

    def test_missing_optional_patch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            missing = Path(raw) / "0010-missing.patch"
            with self.assertRaisesRegex(self.builder.BuildError, "missing optional patch"):
                self.builder.check_optional_patches(missing, [])

    def test_duplicate_optional_patch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            patch = Path(raw) / "0010-duplicate.patch"
            patch.write_text("", encoding="utf-8")
            with self.assertRaisesRegex(self.builder.BuildError, "duplicate optional patch"):
                self.builder.check_optional_patches(patch, [patch])

    def test_distinct_optional_patches_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            first = Path(raw) / "0010-first.patch"
            second = Path(raw) / "0011-second.patch"
            first.write_text("", encoding="utf-8")
            second.write_text("", encoding="utf-8")
            self.builder.check_optional_patches(first, [second])


class StaticStringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.builder = load_builder()

    def test_conditional_static_string_is_exact(self) -> None:
        self.assertEqual(
            self.builder.CONDITIONAL_LOG_STRINGS,
            ("Invalid conditional expression; block disabled",),
        )

    def test_missing_static_string_is_reported(self) -> None:
        data = "before Invalid conditional expression; block disabled after".encode(
            self.builder.CONDITIONAL_LOG_ENCODING
        )
        self.assertEqual(
            self.builder.missing_static_strings(
                data,
                self.builder.CONDITIONAL_LOG_STRINGS,
                encoding=self.builder.CONDITIONAL_LOG_ENCODING,
            ),
            [],
        )
        self.assertEqual(
            self.builder.missing_static_strings(
                b"unrelated",
                self.builder.CONDITIONAL_LOG_STRINGS,
                encoding=self.builder.CONDITIONAL_LOG_ENCODING,
            ),
            ["Invalid conditional expression; block disabled"],
        )

    def test_conditional_log_string_encoding_is_utf16le(self) -> None:
        self.assertEqual(self.builder.CONDITIONAL_LOG_ENCODING, "utf-16-le")


if __name__ == "__main__":
    unittest.main()
