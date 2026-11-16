#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline regression tests for patch 0012 (disassembly exception fail-closed).

``BinaryToAsmText`` in ``util.h`` calls the DXBC disassembler without an
exception guard. A ``[ShaderRegex]`` section sends game shaders through
``HackerContext::DeferredShaderReplacement`` on the draw path, and the
disassembler can throw (observed: ``std::out_of_range`` "invalid string
position") on a shader it does not understand. Nothing on that path catches
it. Callers already treat an empty return as "disassembly failed" and keep
the original shader.

The harness compiles the verbatim v1.2.3 ``BinaryToAsmText`` excerpt
(``fixtures/xxmi-disassembly``) with boundary stubs for ``byte``,
``HRESULT``, ``LogTime``, ``LogInfo`` (which records messages) and the
``disassembler`` itself, which can succeed, return a failing ``HRESULT``,
throw ``std::out_of_range`` or throw a non-``std::exception`` value. Two
builds are compared: the pristine excerpt (upstream behaviour: the exception
escapes) and the excerpt after
``0012-srmi-disassembly-exception-fail-closed.patch`` (it returns an empty
string and logs).

``XXMI_LIBS_SOURCE`` may point at the full pinned clean v1.2.3 tree. When set,
it is authenticated against the build plan, the full stage-3 patch chain,
including 0012, must apply with ``--fuzz=0`` and no offset, and the patched
excerpt must appear verbatim in the result. Without it that parity test is
skipped.

This is host-native evidence of control flow, not a live rendering test.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any

REPO = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "xxmi-disassembly"
BUILD_PLAN = REPO / "compat" / "xxmi" / "build" / "payload-build-plan.json"
SOURCE_PINS = REPO / "compat" / "xxmi" / "source-pins.json"
PATCH_DIR = REPO / "compat" / "xxmi" / "patches"
GUARD_PATCH = PATCH_DIR / "0012-srmi-disassembly-exception-fail-closed.patch"
REBUILD_SCRIPT = REPO / "scripts" / "xxmi-rebuild-payload.py"
BANNER_LINES = 6


def load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


REBUILD = load_module("xxmi_rebuild_payload_disassembly", REBUILD_SCRIPT)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def verify_fixture(root: Path, plan: dict[str, Any]) -> dict[str, Any]:
    """Authenticate the excerpt and its source-pin metadata."""

    source_pin = plan["sourcePin"]
    pins = load_json(SOURCE_PINS)["sourcePins"]["xxmiLibsPackage"]
    metadata = load_json(root / "PROVENANCE.json")
    if metadata.get("schemaVersion") != 1:
        raise AssertionError("fixture PROVENANCE schemaVersion must be 1")
    expected = {
        "repository": source_pin["repository"],
        "tag": source_pin["tag"],
        "commit": source_pin["commit"],
        "cleanTreeSHA256": source_pin["cleanTreeSHA256"],
        "cleanFileCount": source_pin["cleanFileCount"],
        "archiveSHA256": pins["archiveSHA256"],
        "license": pins["license"],
    }
    for key, value in expected.items():
        if metadata["source"].get(key) != value:
            raise AssertionError(
                f"fixture source metadata {key} mismatch: "
                f"got {metadata['source'].get(key)!r}, expected {value!r}"
            )
    for excerpt in metadata["excerpts"]:
        text = (root / excerpt["path"]).read_text(encoding="utf-8")
        lines = text.splitlines(keepends=True)
        if len(lines) != excerpt["fixtureLineCount"]:
            raise AssertionError(f"fixture line count mismatch for {excerpt['path']}")
        if sha256_text(text) != excerpt["fixtureSHA256"]:
            raise AssertionError(f"fixture SHA-256 mismatch for {excerpt['path']}")
        banner = "".join(lines[: excerpt["bannerLineCount"]])
        for required in ("SPDX-License-Identifier: GPL-3.0-only", source_pin["commit"]):
            if required not in banner:
                raise AssertionError(f"fixture banner for {excerpt['path']} lacks {required!r}")
        index = excerpt["bannerLineCount"]
        separator = excerpt["segmentSeparator"]
        for position, segment in enumerate(excerpt["segments"]):
            if segment["sourceEnd"] - segment["sourceStart"] + 1 != segment["lineCount"]:
                raise AssertionError("fixture source line range is inconsistent")
            chunk = "".join(lines[index : index + segment["lineCount"]])
            if sha256_text(chunk) != segment["sha256"]:
                raise AssertionError(
                    f"source excerpt SHA-256 mismatch for {excerpt['path']} "
                    f"lines {segment['sourceStart']}-{segment['sourceEnd']}"
                )
            index += segment["lineCount"]
            if position + 1 < len(excerpt["segments"]):
                if lines[index] != separator:
                    raise AssertionError(f"fixture separator mismatch in {excerpt['path']}")
                index += 1
        if index != len(lines):
            raise AssertionError(f"fixture {excerpt['path']} has unauthenticated trailing lines")
    return metadata


def apply_fixture_patch(tree: Path, patch: Path) -> str:
    """Apply a patch to a minimal fixture, allowing offsets but no fuzz."""

    result = subprocess.run(
        ["patch", "-p1", "--fuzz=0", "--no-backup-if-mismatch", "-i", str(patch)],
        cwd=tree,
        text=True,
        capture_output=True,
    )
    output = result.stdout + result.stderr
    if result.returncode != 0:
        raise AssertionError(f"{patch.name} failed:\n{output}")
    if "fuzz" in output.lower():
        raise AssertionError(f"{patch.name} applied with fuzz:\n{output}")
    if sorted(tree.rglob("*.rej")):
        raise AssertionError(f"{patch.name} left rejects")
    return output


def excerpt_body(path: Path) -> str:
    return "".join(path.read_text(encoding="utf-8").splitlines(keepends=True)[BANNER_LINES:])


HEADER = r"""
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

using namespace std;

typedef unsigned char byte;
typedef int HRESULT;
#define FAILED(hr) (((HRESULT)(hr)) < 0)
#define S_OK ((HRESULT)0)
#define E_FAIL ((HRESULT)0x80004005u)
#define MIGOTO_DX 11
#define VER_FILE_VERSION_STR "test"

static string g_log;
static void LogInfo(const char *fmt, ...)
{
    char buffer[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    g_log += buffer;
}
static string LogTime() { return "now"; }

static string g_mode;
static int g_calls = 0;

// Boundary stub with the DX11 wrapper's signature.
static HRESULT disassembler(vector<byte> *, vector<byte> *disassembly, const char *,
        int, bool, bool, bool)
{
    g_calls++;
    if (g_mode == "out-of-range") {
        disassembly->push_back('p');
        (void)string("ps_5_0").substr(99);  // throws std::out_of_range
        return S_OK;
    }
    if (g_mode == "unknown")
        throw 42;
    if (g_mode == "hresult")
        return E_FAIL;
    const char text[] = "ps_5_0\nret\n";
    disassembly->assign(text, text + strlen(text));
    return S_OK;
}
"""

MAIN = r"""
int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    g_mode = argv[1];
    const unsigned char bytecode[4] = {'D', 'X', 'B', 'C'};
    string result;
    int escaped = 0;
    try {
        result = BinaryToAsmText(bytecode, sizeof(bytecode), false);
    } catch (const std::exception &) {
        escaped = 1;
    } catch (...) {
        escaped = 2;
    }
    printf("ESCAPED=%d\n", escaped);
    printf("CALLS=%d\n", g_calls);
    printf("EMPTY=%d\n", result.empty() ? 1 : 0);
    printf("RESULT_OK=%d\n", result == "ps_5_0\nret\n" ? 1 : 0);
    printf("LOG_EXCEPTION=%d\n", g_log.find("disassembly failed with exception: ") != string::npos ? 1 : 0);
    printf("LOG_WHAT=%d\n", g_log.find("basic_string") != string::npos
        || g_log.find("substr") != string::npos || g_log.find("out of range") != string::npos
        || g_log.find("invalid string position") != string::npos ? 1 : 0);
    printf("LOG_UNKNOWN=%d\n", g_log.find("disassembly failed with an unknown exception") != string::npos ? 1 : 0);
    printf("LOG_HRESULT=%d\n", g_log.find("disassembly failed. Error: 80004005") != string::npos ? 1 : 0);
    return 0;
}
"""


def build_harness(root: Path) -> str:
    return "\n".join(["#include <cstdarg>", HEADER, excerpt_body(root / "util.h"), MAIN])


class DisassemblyGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = load_json(BUILD_PLAN)
        cls.pin = cls.plan["sourcePin"]
        cls.provenance = verify_fixture(FIXTURE, cls.plan)
        cls.cxx = shutil.which("clang++") or shutil.which("c++")
        if cls.cxx is None:
            raise unittest.SkipTest("a C++ compiler is required for the disassembly harness")
        if shutil.which("patch") is None:
            raise unittest.SkipTest("patch(1) is required for the disassembly harness")
        cls._temp = tempfile.TemporaryDirectory(prefix="macgacha-disassembly-guard-")
        cls.temp = Path(cls._temp.name)
        cls.old_tree = cls.temp / "fixture-old"
        cls.new_tree = cls.temp / "fixture-new"
        shutil.copytree(FIXTURE, cls.old_tree)
        shutil.copytree(FIXTURE, cls.new_tree)
        apply_fixture_patch(cls.new_tree, GUARD_PATCH)
        cls.old_harness = cls._compile("old", cls.old_tree)
        cls.new_harness = cls._compile("new", cls.new_tree)

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "_temp"):
            cls._temp.cleanup()

    @classmethod
    def _compile(cls, name: str, root: Path) -> Path:
        cpp = cls.temp / f"disassembly_harness_{name}.cpp"
        exe = cls.temp / f"disassembly_harness_{name}"
        cpp.write_text(build_harness(root), encoding="utf-8")
        command = [
            cls.cxx, "-std=c++14", "-O0", "-Wall", "-Wextra", "-Werror",
            "-Wno-unused-parameter", "-Wno-unused-function", "-Wno-unused-variable",
            "-o", str(exe), str(cpp),
        ]
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode != 0:
            raise AssertionError(
                f"disassembly harness compilation failed for {name}:\n{result.stdout}{result.stderr}"
            )
        return exe

    @staticmethod
    def _run(harness: Path, mode: str) -> dict[str, int]:
        result = subprocess.run(
            [str(harness), mode], text=True, capture_output=True, check=True
        )
        values: dict[str, int] = {}
        for line in result.stdout.splitlines():
            key, raw = line.split("=", 1)
            values[key] = int(raw)
        return values

    def test_fixture_metadata_is_authenticated(self) -> None:
        self.assertEqual(self.provenance["source"]["commit"], self.pin["commit"])

    def test_tampered_fixture_is_rejected(self) -> None:
        tampered = self.temp / "tampered"
        shutil.copytree(FIXTURE, tampered)
        path = tampered / "util.h"
        path.write_text(
            path.read_text(encoding="utf-8").replace("if (FAILED(r))", "if (!FAILED(r))", 1),
            encoding="utf-8",
        )
        with self.assertRaises(AssertionError):
            verify_fixture(tampered, self.plan)

    def test_patch_is_pinned_in_plan_and_source_pins(self) -> None:
        digest = REBUILD.sha256_file(GUARD_PATCH)
        stage3 = [entry["path"] for entry in self.plan["stage3"]["patches"]]
        self.assertEqual(stage3[-1], "compat/xxmi/patches/" + GUARD_PATCH.name)
        self.assertEqual(self.plan["stage3"]["patches"][-1]["sha256"], digest)
        pins = load_json(SOURCE_PINS)
        order = pins["sources"]["patches"]["order"]
        self.assertEqual(order[-1], GUARD_PATCH.name)
        self.assertEqual(pins["sources"]["patches"]["sha256"][GUARD_PATCH.name], digest)
        listed = {entry["path"]: entry["sha256"] for entry in pins["sourcePins"]["patches"]}
        self.assertEqual(listed["compat/xxmi/patches/" + GUARD_PATCH.name], digest)

    def test_patch_only_guards_the_dx11_disassembler_call(self) -> None:
        old = (self.old_tree / "util.h").read_text(encoding="utf-8")
        new = (self.new_tree / "util.h").read_text(encoding="utf-8")
        self.assertNotIn("\r", new)
        self.assertNotIn("try {", old)
        dx9 = "#if MIGOTO_DX == 9\n\tr = disassemblerDX9(&byteCode, &disassembly, comments.c_str());\n#elif MIGOTO_DX == 11\n"
        self.assertIn(dx9, old)
        self.assertIn(dx9, new)
        branch = new[new.index("#elif MIGOTO_DX == 11"):new.index("#endif // MIGOTO_DX")]
        try_at = branch.index("\ttry {\n")
        call_at = branch.index("r = disassembler(&byteCode")
        catch_std = branch.index("} catch (const std::exception &e) {")
        catch_all = branch.index("} catch (...) {")
        self.assertLess(try_at, call_at)
        self.assertLess(call_at, catch_std)
        self.assertLess(catch_std, catch_all)
        self.assertEqual(branch.count('return "";'), 2)
        # Outside the DX11 branch the function is unchanged.
        head = old[:old.index("#elif MIGOTO_DX == 11")]
        tail = old[old.index("#endif // MIGOTO_DX"):]
        self.assertTrue(new.startswith(head))
        self.assertTrue(new.endswith(tail))

    def test_upstream_lets_a_disassembler_exception_escape(self) -> None:
        values = self._run(self.old_harness, "out-of-range")
        self.assertEqual(values["ESCAPED"], 1)
        values = self._run(self.old_harness, "unknown")
        self.assertEqual(values["ESCAPED"], 2)

    def test_guard_returns_empty_and_logs_std_exception(self) -> None:
        values = self._run(self.new_harness, "out-of-range")
        self.assertEqual(values["ESCAPED"], 0)
        self.assertEqual(values["CALLS"], 1)
        self.assertEqual(values["EMPTY"], 1)
        self.assertEqual(values["LOG_EXCEPTION"], 1)
        self.assertEqual(values["LOG_WHAT"], 1)
        self.assertEqual(values["LOG_HRESULT"], 0)

    def test_guard_returns_empty_and_logs_unknown_exception(self) -> None:
        values = self._run(self.new_harness, "unknown")
        self.assertEqual(values["ESCAPED"], 0)
        self.assertEqual(values["EMPTY"], 1)
        self.assertEqual(values["LOG_UNKNOWN"], 1)
        self.assertEqual(values["LOG_EXCEPTION"], 0)

    def test_hresult_failure_and_success_are_unchanged(self) -> None:
        for mode in ("hresult", "ok"):
            with self.subTest(mode):
                old = self._run(self.old_harness, mode)
                new = self._run(self.new_harness, mode)
                self.assertEqual(old, new)
                self.assertEqual(new["ESCAPED"], 0)
        self.assertEqual(self._run(self.new_harness, "hresult")["LOG_HRESULT"], 1)
        self.assertEqual(self._run(self.new_harness, "hresult")["EMPTY"], 1)
        self.assertEqual(self._run(self.new_harness, "ok")["RESULT_OK"], 1)

    def test_full_stage3_chain_matches_plan(self) -> None:
        override = os.environ.get("XXMI_LIBS_SOURCE")
        if not override:
            self.skipTest("XXMI_LIBS_SOURCE is not set; full-tree parity is optional")
        source = Path(override)
        manifest = REBUILD.tree_manifest(source)
        self.assertEqual(manifest["sha256"], self.pin["cleanTreeSHA256"])
        self.assertEqual(manifest["fileCount"], self.pin["cleanFileCount"])
        tree = self.temp / "full"
        logs = self.temp / "full-logs"
        shutil.copytree(source, tree)
        logs.mkdir()
        for entry in self.plan["basePatches"]:
            REBUILD.apply_patch(tree, REBUILD.resolve_plan_path(entry["path"]), logs)
        REBUILD.apply_compatibility_edits(tree, self.plan["stage1"]["compatibilityEdits"])
        REBUILD.apply_patch(tree, REBUILD.resolve_plan_path(self.plan["stage2"]["patch"]["path"]), logs)
        for entry in self.plan["stage3"]["patches"]:
            REBUILD.apply_patch(tree, REBUILD.resolve_plan_path(entry["path"]), logs)
        patched = (tree / "util.h").read_text(encoding="utf-8")
        self.assertIn(excerpt_body(self.new_tree / "util.h"), patched)


if __name__ == "__main__":
    unittest.main()
