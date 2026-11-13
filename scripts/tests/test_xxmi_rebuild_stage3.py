#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Focused offline tests for optional stage-3 payload reconstruction."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "xxmi-rebuild-payload.py"
PLAN = Path(__file__).resolve().parents[2] / "compat" / "xxmi" / "build" / "payload-build-plan.json"
spec = importlib.util.spec_from_file_location("xxmi_rebuild_payload", SCRIPT)
REBUILD = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = REBUILD
spec.loader.exec_module(REBUILD)

FAKE_COMPILER = """#!{interpreter}
import hashlib
import os
import sys

argv = sys.argv[1:]
if "-o" not in argv or "-c" not in argv:
    sys.exit(2)
output = argv[argv.index("-o") + 1]
source = argv[argv.index("-c") + 1]
data = open(source, "rb").read()
open(output, "wb").write(hashlib.sha256(data).digest())
log = os.environ.get("FAKE_COMPILE_LOG")
if log:
    with open(log, "a", encoding="utf-8") as stream:
        stream.write(f"{output}\\t{source}\\n")
"""

FAKE_LINKER = """#!{interpreter}
import hashlib
import os
import sys

rsp = sys.argv[1]
if rsp.startswith("@"):
    rsp = rsp[1:]
objects = [
    line
    for line in open(rsp, encoding="utf-8").read().splitlines()
    if line.endswith(".obj")
]
digest = hashlib.sha256()
for path in objects:
    digest.update(open(path, "rb").read())
output = os.path.join(os.getcwd(), "d3d11.dll")
open(output, "wb").write(digest.digest())
log = os.environ.get("FAKE_LINK_LOG")
if log:
    with open(log, "a", encoding="utf-8") as stream:
        stream.write(f"{output}\\t{len(objects)}\\n")
"""


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(data: bytes) -> str:
    if len(data) >= 8:
        data = data[:4] + b"\0" * 4 + data[8:]
    return hashlib.sha256(data).hexdigest()


def object_bytes(source: bytes) -> bytes:
    return hashlib.sha256(source).digest()


def candidate_bytes(objects: list[bytes]) -> bytes:
    return hashlib.sha256(b"".join(objects)).digest()


def write(path: Path, data: bytes | str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
    return path


class Stage3Fixture:
    def __init__(self, root: Path, *, include_stage3: bool = True):
        self.root = root
        self.source = root / "source"
        write(self.source / "a.cpp", "int a;\n")
        write(self.source / "b.cpp", "int b;\n")
        write(self.source / "c.c", "int c;\n")

        patches = root / "patches"
        self.base_patch = write(
            patches / "0001-base.patch",
            "--- a/a.cpp\n+++ b/a.cpp\n@@ -1 +1 @@\n-int a;\n+int a_base;\n",
        )
        self.stage2_patch = write(
            patches / "0007-stage2.patch",
            "--- a/b.cpp\n+++ b/b.cpp\n@@ -1 +1 @@\n-int b;\n+int b_stage2;\n",
        )
        self.stage3a = write(
            patches / "0009-stage3-cursor.patch",
            "--- a/b.cpp\n+++ b/b.cpp\n@@ -1 +1 @@\n-int b_stage2;\n+int b_stage3;\n",
        )
        self.stage3b = write(
            patches / "0010-stage3-conditional.patch",
            "--- a/c.c\n+++ b/c.c\n@@ -1 +1 @@\n-int c;\n+int c_stage3;\n",
        )

        stage1 = {"a.cpp": b"int a_base;\n", "b.cpp": b"int b;\n", "c.c": b"int c;\n"}
        stage2 = {"a.cpp": b"int a_base;\n", "b.cpp": b"int b_stage2;\n", "c.c": b"int c;\n"}
        stage3 = {"a.cpp": b"int a_base;\n", "b.cpp": b"int b_stage3;\n", "c.c": b"int c_stage3;\n"}
        self.stage1_tree = self._tree("expected-stage1", stage1)
        self.stage2_tree = self._tree("expected-stage2", stage2)
        self.stage3_tree = self._tree("expected-stage3", stage3)

        objects1 = {name: object_bytes(data) for name, data in stage1.items()}
        objects2 = dict(objects1)
        objects2["a.cpp"] = object_bytes(stage2["a.cpp"])
        objects2["b.cpp"] = object_bytes(stage2["b.cpp"])
        objects3 = {name: object_bytes(data) for name, data in stage3.items()}

        rsp = ["/OUT:{BUILD}/d3d11.dll"]
        rsp.extend("{OBJDIR}/" + name + ".obj" for name in ("a.cpp", "b.cpp", "c.c"))

        self.plan = {
            "schemaVersion": 1,
            "sourcePin": {
                "repository": "https://example.invalid/XXMI-Libs-Package",
                "tag": "v1.2.2-test",
                "commit": "a" * 40,
                "cleanTreeSHA256": REBUILD.tree_manifest(self.source)["sha256"],
                "cleanFileCount": 3,
            },
            "basePatches": [
                {"path": str(self.base_patch), "sha256": sha(self.base_patch.read_bytes())}
            ],
            "stage1": {
                "patchedTreeSHA256": self.stage1_tree["sha256"],
                "candidateSHA256": sha(candidate_bytes([objects1[n] for n in ("a.cpp", "b.cpp", "c.c")])),
                "compatibilityEdits": [],
                "generatedAssets": [],
                "compile": [
                    self._command("a.cpp", stage1, objects1, "{CLANGXX}"),
                    self._command("b.cpp", stage1, objects1, "{CLANGXX}"),
                    self._command("c.c", stage1, objects1, "{CLANG}"),
                ],
                "thirdPartyObjects": [],
                "link": {"rspLines": list(rsp)},
            },
            "stage2": {
                "patch": {
                    "path": str(self.stage2_patch),
                    "sha256": sha(self.stage2_patch.read_bytes()),
                },
                "patchedTreeSHA256": self.stage2_tree["sha256"],
                "candidateSHA256": sha(candidate_bytes([objects2[n] for n in ("a.cpp", "b.cpp", "c.c")])),
                "compile": [
                    self._command("a.cpp", stage2, objects2, "{CLANGXX}"),
                    self._command("b.cpp", stage2, objects2, "{CLANGXX}"),
                ],
                "link": {"rspLines": list(rsp)},
            },
            "textPrinter": {
                "patch": {
                    "path": str(self.base_patch),
                    "sha256": sha(self.base_patch.read_bytes()),
                },
                "source": "payload/Core/SRMI/Shaders/TextPrinter.hlsl",
                "expectedSHA256": "2" * 64,
            },
        }
        if include_stage3:
            self.plan["stage3"] = {
                "patches": [
                    {"path": str(self.stage3a), "sha256": sha(self.stage3a.read_bytes())},
                    {"path": str(self.stage3b), "sha256": sha(self.stage3b.read_bytes())},
                ],
                "patchedTreeSHA256": self.stage3_tree["sha256"],
                "candidateSHA256": sha(candidate_bytes([objects3[n] for n in ("a.cpp", "b.cpp", "c.c")])),
                "compile": [
                    self._command("a.cpp", stage3, objects3, "{CLANGXX}"),
                    self._command("b.cpp", stage3, objects3, "{CLANGXX}"),
                    self._command("c.c", stage3, objects3, "{CLANG}"),
                ],
                "link": {"rspLines": list(rsp)},
            }
        self.objects1 = objects1
        self.objects2 = objects2
        self.objects3 = objects3

        self.generated = root / "generated"
        self.generated.mkdir(parents=True, exist_ok=True)
        self.third_party = root / "third-party"
        self.third_party.mkdir(parents=True, exist_ok=True)
        self.toolchain = self._toolchain()

    def _tree(self, name: str, files: dict[str, bytes]) -> dict:
        root = self.root / name
        for relative, data in files.items():
            write(root / relative, data)
        return REBUILD.tree_manifest(root)

    @staticmethod
    def _command(name: str, stage: dict[str, bytes], objects: dict[str, bytes], driver: str) -> dict:
        return {
            "source": name,
            "object": name + ".obj",
            "sourceSHA256": sha(stage[name]),
            "objectSHA256": sha(objects[name]),
            "objectCanonicalSHA256": canonical(objects[name]),
            "argv": [driver, "-c", "{SRC}/" + name, "-o", "{OBJDIR}/" + name + ".obj"],
        }

    def _toolchain(self) -> dict[str, Path]:
        tools = self.root / "tools"
        tools.mkdir(parents=True, exist_ok=True)
        compiler = write(tools / "clang", FAKE_COMPILER.replace("{interpreter}", sys.executable))
        compiler.chmod(0o755)
        linker = write(tools / "lld-link", FAKE_LINKER.replace("{interpreter}", sys.executable))
        linker.chmod(0o755)
        directories = {}
        for name in ("clang-resource", "msvc-include", "msvc-lib", "windows-sdk-include", "windows-sdk-lib"):
            directory = tools / name
            directory.mkdir(exist_ok=True)
            directories[name.replace("-", "_")] = directory
        toolchain = {
            "clang": compiler,
            "clangxx": compiler,
            "lld_link": linker,
            **directories,
        }
        return toolchain

    def plan_path(self) -> Path:
        return write(self.root / "plan.json", json.dumps(self.plan, indent=2) + "\n")


class Stage3RebuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-rebuild-stage3-tests-")
        self.root = Path(self.temp.name)
        self.compile_log = self.root / "compile.log"
        os.environ["FAKE_COMPILE_LOG"] = str(self.compile_log)
        self.fixture = Stage3Fixture(self.root)

    def tearDown(self):
        os.environ.pop("FAKE_COMPILE_LOG", None)
        self.temp.cleanup()

    def build(self, output_name: str = "out") -> dict:
        output = self.root / output_name
        return REBUILD.build(
            self.fixture.plan,
            source=self.fixture.source,
            generated_assets=self.fixture.generated,
            third_party_objects=self.fixture.third_party,
            toolchain=self.fixture.toolchain,
            output_dir=output,
        )

    def compile_lines(self) -> list[tuple[str, str]]:
        return [
            tuple(line.split("\t"))
            for line in self.compile_log.read_text(encoding="utf-8").splitlines()
        ]

    def test_builds_optional_stage3_and_recompiles_every_unit(self):
        manifest = self.build()
        self.assertEqual(manifest["finalStage"], 3)
        self.assertEqual(manifest["candidate"]["sha256"], self.fixture.plan["stage3"]["candidateSHA256"])
        self.assertEqual(
            [entry["path"] for entry in manifest["stage3Patches"]],
            [
                str(self.fixture.stage3a),
                str(self.fixture.stage3b),
            ],
        )
        self.assertIn("stage3", manifest["maps"])

        lines = self.compile_lines()
        self.assertEqual(len(lines), 3 + 2 + 3)
        stage3_lines = lines[-3:]
        self.assertEqual(
            [Path(source).name for _, source in stage3_lines],
            ["a.cpp", "b.cpp", "c.c"],
        )
        for output, _ in stage3_lines:
            self.assertIn("/stage3/objects/", output)
        stage3_objects = {
            path.name for path in (self.root / "out" / "work" / "stage3" / "objects").iterdir()
        }
        self.assertEqual(stage3_objects, {"a.cpp.obj", "b.cpp.obj", "c.c.obj"})

    def test_unchanged_translation_unit_is_compiled_again_for_stage3(self):
        self.build()
        lines = self.compile_lines()
        stage3_sources = [Path(source).name for _, source in lines[-3:]]
        self.assertIn("a.cpp", stage3_sources)
        stage1_object = (self.root / "out" / "work" / "stage1" / "objects" / "a.cpp.obj").read_bytes()
        stage2_object = (self.root / "out" / "work" / "stage2" / "objects" / "a.cpp.obj").read_bytes()
        stage3_object = (self.root / "out" / "work" / "stage3" / "objects" / "a.cpp.obj").read_bytes()
        self.assertEqual(stage1_object, stage2_object)
        self.assertEqual(stage1_object, stage3_object)
        self.assertEqual(stage3_object, object_bytes(b"int a_base;\n"))

    def test_without_stage3_keeps_stage2_final(self):
        fixture = Stage3Fixture(self.root / "old", include_stage3=False)
        output = self.root / "out-old"
        manifest = REBUILD.build(
            fixture.plan,
            source=fixture.source,
            generated_assets=fixture.generated,
            third_party_objects=fixture.third_party,
            toolchain=fixture.toolchain,
            output_dir=output,
        )
        self.assertEqual(manifest["finalStage"], 2)
        self.assertEqual(manifest["candidate"]["sha256"], fixture.plan["stage2"]["candidateSHA256"])
        self.assertNotIn("stage3Patches", manifest)
        self.assertFalse((output / "work" / "stage3").exists())
        self.assertEqual(len(self.compile_lines()), 3 + 2)

    def test_rejects_stale_stage3_patch_hash(self):
        self.fixture.plan["stage3"]["patches"][1]["sha256"] = "0" * 64
        with self.assertRaises(REBUILD.BuildError):
            self.build()
        self.assertFalse((self.root / "out" / "candidate" / "d3d11.dll").exists())

    def test_rejects_missing_stage3_patch(self):
        self.fixture.stage3b.unlink()
        with self.assertRaises(REBUILD.BuildError):
            self.build()
        self.assertFalse((self.root / "out" / "candidate" / "d3d11.dll").exists())

    def test_rejects_stale_stage3_object_hash(self):
        self.fixture.plan["stage3"]["compile"][1]["objectCanonicalSHA256"] = "0" * 64
        with self.assertRaises(REBUILD.BuildError):
            self.build()
        self.assertFalse((self.root / "out" / "candidate" / "d3d11.dll").exists())

    def test_rejects_stage3_tree_mismatch(self):
        self.fixture.plan["stage3"]["patchedTreeSHA256"] = "0" * 64
        with self.assertRaises(REBUILD.BuildError):
            self.build()
        self.assertFalse((self.root / "out" / "candidate" / "d3d11.dll").exists())

    def test_rejects_stage3_source_hash_mismatch(self):
        self.fixture.plan["stage3"]["compile"][0]["sourceSHA256"] = "0" * 64
        with self.assertRaises(REBUILD.BuildError):
            self.build()
        self.assertFalse((self.root / "out" / "candidate" / "d3d11.dll").exists())


class CheckedInStage3PlanTests(unittest.TestCase):
    def setUp(self):
        self.plan = json.loads(PLAN.read_text(encoding="utf-8"))

    def test_stage3_is_tokenized_and_pinned(self):
        stage3 = self.plan["stage3"]
        self.assertEqual(len(stage3["compile"]), 34)
        self.assertEqual(
            [Path(patch["path"]).name for patch in stage3["patches"]],
            [
                "0009-srmi-cursor-coordinate-contract.patch",
                "0010-srmi-invalid-conditional-fail-closed.patch",
                "0011-srmi-conditional-fold-fail-closed.patch",
            ],
        )
        self.assertEqual(
            stage3["patches"][0]["sha256"],
            "a808d2154af9c32ff81163fb25d12ada58969891a76feabab7ce64f8ec5c9f27",
        )
        self.assertEqual(
            stage3["patches"][1]["sha256"],
            "386e125112e1b4da799d1dd66583ffb4174c87071dfe2ee90a20d8f87c7670d0",
        )
        self.assertEqual(
            stage3["patches"][2]["sha256"],
            "ed484b91b38e6234d3b7d07045cf199f02337b4604d15ed52678c9ac7a09a6d9",
        )
        self.assertEqual(
            stage3["patchedTreeSHA256"],
            "40a10ae8123026dd1b34faea7c079a5a464d770a3abb541bb892edfc07e68a65",
        )
        self.assertEqual(
            stage3["candidateSHA256"],
            "e519f0241d86a45d408838aedf228ea274cb6e4a94ac55e4614bceec0c1a78bc",
        )

        serialized = json.dumps(stage3)
        self.assertNotIn("/Users/", serialized)
        self.assertNotIn("/private/tmp/", serialized)
        self.assertNotIn("/var/folders/", serialized)
        for command in stage3["compile"]:
            self.assertIn("objectCanonicalSHA256", command)
            self.assertEqual(len(command["sourceSHA256"]), 64)
            for part in command["argv"]:
                self.assertFalse(part.startswith("/"), part)

    def test_stage3_covers_every_first_party_translation_unit(self):
        expected = []
        seen = set()
        for command in self.plan["stage1"]["compile"]:
            expected.append(command["source"])
            seen.add(command["source"])
        for command in self.plan["stage2"]["compile"]:
            if command["source"] not in seen:
                expected.append(command["source"])
                seen.add(command["source"])
        self.assertEqual(
            [command["source"] for command in self.plan["stage3"]["compile"]],
            expected,
        )
        self.assertEqual(len(expected), 34)

    def test_canonical_object_hash_ignores_timestamp_but_not_payload(self):
        with tempfile.TemporaryDirectory(prefix="xxmi-canonical-") as name:
            first = write(Path(name) / "first.obj", b"ABCD" + b"\x01\x02\x03\x04" + b"payload")
            second = write(Path(name) / "second.obj", b"ABCD" + b"\xff\xff\xff\xff" + b"payload")
            changed = write(Path(name) / "changed.obj", b"ABCD" + b"\x01\x02\x03\x04" + b"PAYLOAD")
            self.assertEqual(
                REBUILD.canonical_object_sha256(first),
                REBUILD.canonical_object_sha256(second),
            )
            self.assertNotEqual(
                REBUILD.canonical_object_sha256(first),
                REBUILD.canonical_object_sha256(changed),
            )
            self.assertEqual(
                REBUILD.canonical_object_sha256(changed),
                canonical(b"ABCD" + b"\x01\x02\x03\x04" + b"PAYLOAD"),
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
