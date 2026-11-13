#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Focused static (and optional compile) tests for the target-aware runner."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "compat" / "xxmi" / "runner" / "xxmi_hook_launcher.c"
LEGACY_SOURCE = ROOT / "compat" / "xxmi" / "runner" / "srmi_hook_launcher.c"
BUILD_SCRIPT = ROOT / "scripts" / "xxmi-build-runner.sh"
SUPPORTED_TARGETS = {"StarRail.exe", "ZenlessZoneZero.exe"}


def function_body(source: str, name: str) -> str:
    start = source.index(f"{name}(")
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
    raise AssertionError(f"unterminated function: {name}")


class RunnerContractTests(unittest.TestCase):
    def setUp(self):
        self.source = SOURCE.read_text(encoding="utf-8")

    def test_default_target_is_star_rail(self):
        self.assertIn('static const wchar_t *default_target_exe = L"StarRail.exe";', self.source)

    def test_only_two_game_targets_are_supported(self):
        body = function_body(self.source, "target_exe_is_supported")
        self.assertEqual(set(re.findall(r'L"([^"\\]+\.exe)"', body)), SUPPORTED_TARGETS)

    def test_only_the_approved_wrappers_are_accepted(self):
        body = function_body(self.source, "resolve_game_command")
        literals = set(re.findall(r'L"([^"\\]+\.exe)"', body))
        self.assertEqual(literals, {"steam.exe", "jadeite.exe"})

    def test_allowlist_rejects_other_names(self):
        body = function_body(self.source, "target_exe_is_supported")
        self.assertIn('L"StarRail.exe"', body)
        self.assertIn('L"ZenlessZoneZero.exe"', body)
        self.assertIn("lstrcmpiW", body)

    def test_argument_parser_requires_valid_target_option(self):
        body = function_body(self.source, "parse_arguments")
        self.assertIn('L"--loader"', body)
        self.assertIn('L"--payload"', body)
        self.assertIn('L"--target-exe"', body)
        self.assertIn("target_exe_is_supported", body)
        self.assertIn("target_seen", body)
        self.assertIn("return FALSE", body)

    def test_target_checks_follow_the_chosen_executable(self):
        for name in (
            "is_target_path",
            "target_already_running",
            "verify_target_modules",
            "wait_for_target_window",
        ):
            body = function_body(self.source, name)
            self.assertIn("target_exe", body, name)
            self.assertNotIn('L"StarRail.exe"', body, name)
            self.assertNotIn('L"ZenlessZoneZero.exe"', body, name)

    def test_launch_binding_rejects_unapproved_leading_executable(self):
        body = function_body(self.source, "resolve_game_command")
        self.assertNotIn("for (", body)
        self.assertIn("is_target_path(argv[first], target_exe)", body)
        self.assertIn("is_named_path(argv[first], L\"steam.exe\")", body)
        self.assertIn("is_named_path(argv[first], L\"jadeite.exe\")", body)
        self.assertIn("is_target_path(argv[first + 1], target_exe)", body)
        self.assertLess(body.index("is_target_path(argv[first], target_exe)"),
                        body.index("is_named_path(argv[first], L\"steam.exe\")"))

    def test_injection_and_window_checks_use_the_target(self):
        entry = function_body(self.source, "srmi_hook_launcher_entry")
        self.assertIn("parse_arguments", entry)
        self.assertIn("resolve_game_command(argv, game_index, argc, target_exe, &launch_path, &target)", entry)
        self.assertIn("CreateProcessW(launch_path, command", entry)
        self.assertNotIn("CreateProcessW(argv[game_index]", entry)
        self.assertIn("target_already_running(target_exe)", entry)
        self.assertIn("target_exe, 600", entry)
        self.assertIn("verify_target_modules(target_exe, target, payload_path)", entry)
        self.assertIn("wait_for_target_window(target_exe, target, payload_path, 30000)", entry)

    def test_command_binding_rejects_before_loading_the_injector(self):
        entry = function_body(self.source, "srmi_hook_launcher_entry")
        self.assertLess(entry.index("resolve_game_command"), entry.index("LoadLibraryW"))
        self.assertNotIn("find_target_argument", self.source)

    def test_legitimate_direct_and_wrapper_shapes_are_bound(self):
        body = function_body(self.source, "resolve_game_command")
        self.assertIn("is_target_path(argv[first], target_exe)", body)
        self.assertIn("is_named_path(argv[first], L\"steam.exe\")", body)
        self.assertIn("is_named_path(argv[first], L\"jadeite.exe\")", body)
        self.assertIn("is_target_path(argv[first + 1], target_exe)", body)
        self.assertIn("*launch = argv[first]", body)
        self.assertIn("*target = argv[first + 1]", body)

    def test_historical_hsr_source_is_unchanged(self):
        self.assertEqual(
            hashlib.sha256(LEGACY_SOURCE.read_bytes()).hexdigest(),
            "9d2bc095be608ae40f137fdcbc5587a8f78de4dce833a92832f488759f80c89b",
        )

    def test_build_script_has_valid_shell_syntax(self):
        result = subprocess.run(["bash", "-n", str(BUILD_SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_zzz_pins_require_exact_locally_built_runner(self):
        pins = json.loads(
            (ROOT / "compat" / "xxmi" / "zzz-source-pins.json").read_text(encoding="utf-8")
        )
        runner = pins["verifiedBinaries"]["runner"]
        self.assertEqual(
            runner["sha256"],
            "98c202f777848bb4811aac1bd86703db89e1a78fbfcd40653f4ffbcfcc730172",
        )
        self.assertEqual(runner["size"], 12800)
        self.assertEqual(
            runner["sourceSHA256"],
            hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        )
        self.assertEqual(runner["sourcePath"], "compat/xxmi/runner/xxmi_hook_launcher.c")


class RunnerCompileTests(unittest.TestCase):
    """Optional compile check using a local authenticated Wine runtime."""

    def test_compiled_runner_contains_both_targets(self):
        runtime = os.environ.get("MACGACHA_XXMI_RUNNER_RUNTIME_ROOT")
        lld = os.environ.get("MACGACHA_XXMI_LLD_LINK")
        for key, value in (
            ("MACGACHA_XXMI_RUNNER_RUNTIME_ROOT", runtime),
            ("MACGACHA_XXMI_LLD_LINK", lld),
        ):
            if not value:
                self.skipTest(f"{key} is not set")
        sdk = os.environ.get("MACGACHA_XXMI_SDK_ROOT")
        if not sdk:
            sdk = subprocess.run(
                ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                capture_output=True,
                text=True,
            ).stdout.strip()
        if not sdk:
            self.skipTest("macOS SDK root is unavailable")
        with tempfile.TemporaryDirectory(prefix="xxmi-runner-tests-") as temporary:
            output = Path(temporary) / "hook-runner.exe"
            command = [
                str(BUILD_SCRIPT),
                "--source", str(SOURCE),
                "--runtime-root", runtime,
                "--clang", os.environ.get("MACGACHA_XXMI_CLANG", "/usr/bin/clang"),
                "--lld-link", lld,
                "--sdk-root", sdk,
                "--output", str(output),
            ]
            library_path = os.environ.get("MACGACHA_XXMI_LLD_LIBRARY_PATH")
            if library_path:
                command.extend(["--lld-library-path", library_path])
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode != 0:
                self.skipTest(f"runner toolchain unavailable: {result.stderr.strip()}")
            data = output.read_bytes()
            self.assertEqual(data[:2], b"MZ")
            for marker in ("--target-exe", "StarRail.exe", "ZenlessZoneZero.exe"):
                self.assertIn(marker.encode("utf-16-le"), data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
