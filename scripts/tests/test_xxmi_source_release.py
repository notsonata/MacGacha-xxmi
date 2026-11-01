#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Focused offline tests for the XXMI corresponding-source archive tool."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "xxmi-source-release.py"
spec = importlib.util.spec_from_file_location("xxmi_source_release", SCRIPT)
xxmi_source_release = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = xxmi_source_release
spec.loader.exec_module(xxmi_source_release)

SOURCE_NAME = "XXMI-Libs-Package-" + "a" * 40


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write(path: Path, data: bytes | str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
    return path


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.source = root / "source"
        write(self.source / "DirectX11" / "X.cpp", "int x;\n")
        write(self.source / "a.txt", "old\n")

        patches = root / "patches"
        self.patch1 = write(
            patches / "0001-base.patch",
            "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n",
        )
        self.patch2 = write(
            patches / "0002-stage2.patch",
            "--- /dev/null\n+++ b/b.txt\n@@ -0,0 +1 @@\n+stage2\n",
        )
        self.shader_patch = write(
            patches / "0003-shader.patch",
            "--- a/unused\n+++ b/unused\n@@ -0,0 +1 @@\n+x\n",
        )

        self.generated_root = root / "generated"
        self.generated = write(
            self.generated_root / "DirectXTK" / "Inc" / "SimpleMath.inl",
            "generated\n",
        )

        self.objects_root = root / "objects-root"
        self.object = write(self.objects_root / "objects" / "foo.obj", b"OBJ\0")

        expected_stage1 = root / "expected-stage1"
        write(expected_stage1 / "DirectX11" / "X.cpp", "int x;\n")
        write(expected_stage1 / "a.txt", "new compat\n")
        write(expected_stage1 / "DirectXTK" / "Inc" / "SimpleMath.inl", "generated\n")
        expected_stage2 = root / "expected-stage2"
        shutil.copytree(expected_stage1, expected_stage2)
        write(expected_stage2 / "b.txt", "stage2\n")

        clean_manifest = xxmi_source_release.REBUILD.tree_manifest(self.source)
        stage1_manifest = xxmi_source_release.REBUILD.tree_manifest(expected_stage1)
        stage2_manifest = xxmi_source_release.REBUILD.tree_manifest(expected_stage2)
        object_sha = sha(self.object.read_bytes())

        self.plan = {
            "schemaVersion": 1,
            "sourcePin": {
                "repository": "https://example.invalid/XXMI-Libs-Package",
                "tag": "v1.2.2-test",
                "commit": "a" * 40,
                "cleanTreeSHA256": clean_manifest["sha256"],
                "cleanFileCount": clean_manifest["fileCount"],
            },
            "basePatches": [
                {
                    "path": str(self.patch1),
                    "sha256": sha(self.patch1.read_bytes()),
                }
            ],
            "stage1": {
                "patchedTreeSHA256": stage1_manifest["sha256"],
                "candidateSHA256": "0" * 64,
                "compatibilityEdits": [
                    {
                        "path": "a.txt",
                        "old": "new",
                        "new": "new compat",
                        "occurrences": 1,
                        "sha256_before": sha(b"new\n"),
                        "sha256_after": sha(b"new compat\n"),
                    }
                ],
                "generatedAssets": [
                    {
                        "path": "DirectXTK/Inc/SimpleMath.inl",
                        "sha256": sha(self.generated.read_bytes()),
                    }
                ],
                "compile": [
                    {
                        "source": "a.txt",
                        "sourceSHA256": sha(b"new compat\n"),
                    }
                ],
                "thirdPartyObjects": [
                    {"path": "objects/foo.obj", "sha256": object_sha}
                ],
                "link": {"rspLines": []},
            },
            "stage2": {
                "patch": {
                    "path": str(self.patch2),
                    "sha256": sha(self.patch2.read_bytes()),
                },
                "patchedTreeSHA256": stage2_manifest["sha256"],
                "candidateSHA256": "1" * 64,
                "compile": [
                    {
                        "source": "a.txt",
                        "sourceSHA256": sha(b"new compat\n"),
                    },
                    {
                        "source": "b.txt",
                        "sourceSHA256": sha(b"stage2\n"),
                    },
                ],
                "link": {"rspLines": []},
            },
            "textPrinter": {
                "patch": {
                    "path": str(self.shader_patch),
                    "sha256": sha(self.shader_patch.read_bytes()),
                },
                "source": "payload/Core/SRMI/Shaders/TextPrinter.hlsl",
                "expectedSHA256": "2" * 64,
            },
        }
        self.plan_path = write(
            root / "payload-build-plan.json",
            json.dumps(self.plan, indent=2) + "\n",
        )

    def run(self, output: Path, *, version: str = "9.9.9-test", extra: list[str] | None = None):
        command = [
            "--plan", str(self.plan_path),
            "--source", str(self.source),
            "--generated-assets", str(self.generated_root),
            "--output-dir", str(output),
            "--version", version,
        ]
        if extra:
            command.extend(extra)
        return xxmi_source_release.main(command)

    def archive(self, output: Path) -> Path:
        return next(output.glob("*.tar.gz"))


class Stage3Fixture(Fixture):
    """Fixture whose plan also carries an optional final stage-3 tree."""

    def __init__(self, root: Path):
        super().__init__(root)
        patches = root / "patches"
        self.patch3a = write(
            patches / "0004-stage3-cursor.patch",
            "--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-stage2\n+stage3a\n",
        )
        self.patch3b = write(
            patches / "0005-stage3-conditional.patch",
            "--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-stage3a\n+stage3b\n",
        )
        expected_stage3 = root / "expected-stage3"
        shutil.copytree(root / "expected-stage2", expected_stage3)
        write(expected_stage3 / "b.txt", "stage3b\n")
        stage3_manifest = xxmi_source_release.REBUILD.tree_manifest(expected_stage3)
        self.plan["stage3"] = {
            "patches": [
                {
                    "path": str(self.patch3a),
                    "sha256": sha(self.patch3a.read_bytes()),
                },
                {
                    "path": str(self.patch3b),
                    "sha256": sha(self.patch3b.read_bytes()),
                },
            ],
            "patchedTreeSHA256": stage3_manifest["sha256"],
            "candidateSHA256": "3" * 64,
            "compile": [
                {
                    "source": "b.txt",
                    "sourceSHA256": sha(b"stage3b\n"),
                }
            ],
            "link": {"rspLines": []},
        }
        self.stage3_tree = stage3_manifest
        self.plan_path.write_text(json.dumps(self.plan, indent=2) + "\n", encoding="utf-8")


class SourceReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-source-release-tests-")
        self.root = Path(self.temp.name)
        self.fixture = Fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_builds_deterministic_safe_archive(self):
        out_a = self.root / "out-a"
        out_b = self.root / "out-b"
        self.assertEqual(self.fixture.run(out_a), 0)
        self.assertEqual(self.fixture.run(out_b), 0)

        archive_a = self.fixture.archive(out_a)
        archive_b = self.fixture.archive(out_b)
        self.assertEqual(archive_a.name, "xxmi-libs-v1.2.2-test-source-9.9.9-test.tar.gz")
        self.assertEqual(archive_a.read_bytes(), archive_b.read_bytes())
        digest = sha(archive_a.read_bytes())
        self.assertEqual(
            (out_a / f"{archive_a.name}.sha256").read_text(encoding="utf-8"),
            f"{digest}  {archive_a.name}\n",
        )

        extract = self.root / "extract"
        extract.mkdir()
        with tarfile.open(archive_a) as archive:
            members = archive.getmembers()
            archive.extractall(extract)
        root_name = "xxmi-libs-v1.2.2-test-source-9.9.9-test"
        self.assertTrue(all(
            member.name == root_name or member.name.startswith(f"{root_name}/")
            for member in members
        ))
        files = [member for member in members if member.isfile()]
        directories = [member for member in members if member.isdir()]
        for member in members:
            self.assertFalse(member.name.startswith("/"))
            self.assertNotIn("..", Path(member.name).parts)
            self.assertEqual((member.uid, member.gid), (0, 0))
            self.assertEqual((member.uname, member.gname), ("", ""))
            self.assertEqual(member.mtime, 0)
            self.assertIn(member.mode, (0o644, 0o755))
        self.assertEqual([member.name for member in files], sorted(member.name for member in files))
        self.assertEqual([member.name for member in directories], sorted(member.name for member in directories))
        self.assertLess(max(members.index(item) for item in directories), min(members.index(item) for item in files))

        top = extract / root_name
        self.assertEqual((top / "upstream" / SOURCE_NAME / "a.txt").read_bytes(), b"old\n")
        self.assertEqual((top / "patched" / SOURCE_NAME / "a.txt").read_bytes(), b"new compat\n")
        self.assertEqual((top / "patched" / SOURCE_NAME / "b.txt").read_bytes(), b"stage2\n")
        self.assertEqual(
            (top / "patched" / SOURCE_NAME / "DirectXTK" / "Inc" / "SimpleMath.inl").read_bytes(),
            b"generated\n",
        )
        self.assertEqual(
            (top / "generated" / "DirectXTK" / "Inc" / "SimpleMath.inl").read_bytes(),
            b"generated\n",
        )
        self.assertFalse((top / "third-party-objects").exists())

        for required in (
            "compat/xxmi/source-pins.json",
            "compat/xxmi/NOTICE.md",
            "compat/xxmi/README.md",
            "compat/xxmi/build/payload-build-plan.json",
            "compat/xxmi/runner/srmi_hook_launcher.c",
            "scripts/xxmi-rebuild-payload.py",
            "scripts/xxmi-package.py",
            "scripts/xxmi-build-runner.sh",
            "scripts/xxmi-source-release.py",
        ):
            self.assertTrue((top / required).is_file(), required)
        self.assertEqual(
            sorted(path.name for path in (top / "compat" / "xxmi" / "patches").iterdir()),
            sorted(path.name for path in (SCRIPT.parents[1] / "compat" / "xxmi" / "patches").iterdir()),
        )
        self.assertTrue(all(
            path.is_file() for path in (top / "compat" / "xxmi" / "licenses").iterdir()
        ))

        readme = (top / "README.md").read_text(encoding="utf-8")
        self.assertIn("tag `v9.9.9-test`", readme)
        self.assertIn(xxmi_source_release.APP_REPOSITORY, readme)
        self.assertIn("System toolchains", readme)
        self.assertIn("not included", readme)

        metadata = json.loads((top / "SOURCE-RELEASE.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["releaseVersion"], "9.9.9-test")
        self.assertEqual(metadata["appSourceTag"], "v9.9.9-test")
        self.assertEqual(
            metadata["trees"]["upstream"]["sha256"],
            self.fixture.plan["sourcePin"]["cleanTreeSHA256"],
        )
        self.assertEqual(
            metadata["trees"]["patched"]["sha256"],
            self.fixture.plan["stage2"]["patchedTreeSHA256"],
        )
        self.assertFalse(metadata["thirdPartyObjects"]["included"])
        self.assertEqual(metadata["thirdPartyObjects"]["count"], 1)
        self.assertNotIn(str(self.root), json.dumps(metadata))

        lines = (top / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
        listed = {}
        for line in lines:
            file_hash, name = line.split("  ", 1)
            listed[name] = file_hash
        actual = {
            path.relative_to(top).as_posix(): sha(path.read_bytes())
            for path in top.rglob("*")
            if path.is_file()
        }
        actual.pop("SHA256SUMS")
        self.assertEqual(listed, actual)

        self.assertEqual(
            xxmi_source_release.REBUILD.tree_manifest(top / "upstream" / SOURCE_NAME)["sha256"],
            self.fixture.plan["sourcePin"]["cleanTreeSHA256"],
        )
        self.assertEqual(
            xxmi_source_release.REBUILD.tree_manifest(top / "patched" / SOURCE_NAME)["sha256"],
            self.fixture.plan["stage2"]["patchedTreeSHA256"],
        )

        raw = archive_a.read_bytes()
        self.assertNotIn(str(self.root).encode(), raw)
        self.assertFalse(any(".git" in Path(member.name).parts for member in members))
        self.assertFalse(any(Path(member.name).name == ".DS_Store" for member in members))

    def test_includes_authenticated_third_party_objects_when_requested(self):
        output = self.root / "out"
        self.assertEqual(
            self.fixture.run(output, extra=["--third-party-objects", str(self.fixture.objects_root)]),
            0,
        )
        archive = self.fixture.archive(output)
        extract = self.root / "extract"
        extract.mkdir()
        with tarfile.open(archive) as opened:
            opened.extractall(extract)
        top = extract / "xxmi-libs-v1.2.2-test-source-9.9.9-test"
        self.assertEqual(
            (top / "third-party-objects" / "objects" / "foo.obj").read_bytes(),
            b"OBJ\0",
        )
        metadata = json.loads((top / "SOURCE-RELEASE.json").read_text(encoding="utf-8"))
        self.assertTrue(metadata["thirdPartyObjects"]["included"])
        self.assertEqual(
            metadata["thirdPartyObjects"]["entries"],
            [{"path": "objects/foo.obj", "sha256": sha(b"OBJ\0")}],
        )
        readme = (top / "README.md").read_text(encoding="utf-8")
        self.assertIn("third-party-objects/", readme)

    def test_rejects_clean_tree_hash_mismatch(self):
        write(self.fixture.source / "a.txt", "tampered\n")
        output = self.root / "out"
        self.assertEqual(self.fixture.run(output), 1)
        self.assertFalse(output.exists() and any(output.iterdir()))

    def test_rejects_unsafe_version(self):
        output = self.root / "out"
        self.assertEqual(self.fixture.run(output, version="../escape"), 1)
        self.assertFalse(output.exists() and any(output.iterdir()))

    def test_rejects_forbidden_source_entries(self):
        write(self.fixture.source / ".git" / "config", "[core]\n")
        self.assertEqual(self.fixture.run(self.root / "out"), 1)

    def test_rejects_symlink_in_source(self):
        (self.fixture.source / "linked.txt").symlink_to(self.fixture.source / "a.txt")
        self.assertEqual(self.fixture.run(self.root / "out"), 1)

    def test_rejects_tampered_patch(self):
        write(self.fixture.patch1, "tampered patch\n")
        self.assertEqual(self.fixture.run(self.root / "out"), 1)

    def test_rejects_output_directory_with_unrelated_entries(self):
        output = self.root / "out"
        output.mkdir()
        keep = write(output / "keep.txt", "keep me\n")
        self.assertEqual(self.fixture.run(output), 1)
        self.assertEqual(keep.read_text(encoding="utf-8"), "keep me\n")

    def test_does_not_modify_the_pinned_source_tree(self):
        before = xxmi_source_release.REBUILD.tree_manifest(self.fixture.source)
        self.assertEqual(self.fixture.run(self.root / "out"), 0)
        after = xxmi_source_release.REBUILD.tree_manifest(self.fixture.source)
        self.assertEqual(before, after)


class SourceReleaseStage3Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-source-release-stage3-tests-")
        self.root = Path(self.temp.name)
        self.fixture = Stage3Fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def extract(self, output: Path) -> Path:
        archive = self.fixture.archive(output)
        destination = self.root / "extract"
        destination.mkdir()
        with tarfile.open(archive) as opened:
            opened.extractall(destination)
        return destination / "xxmi-libs-v1.2.2-test-source-9.9.9-test"

    def test_archives_final_stage3_tree_not_stage2(self):
        output = self.root / "out"
        self.assertEqual(self.fixture.run(output), 0)
        top = self.extract(output)
        patched = top / "patched" / SOURCE_NAME
        self.assertEqual((patched / "b.txt").read_bytes(), b"stage3b\n")
        self.assertEqual(
            xxmi_source_release.REBUILD.tree_manifest(patched)["sha256"],
            self.fixture.stage3_tree["sha256"],
        )
        self.assertNotEqual(
            xxmi_source_release.REBUILD.tree_manifest(patched)["sha256"],
            self.fixture.plan["stage2"]["patchedTreeSHA256"],
        )

        metadata = json.loads((top / "SOURCE-RELEASE.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["trees"]["patched"]["sha256"], self.fixture.stage3_tree["sha256"])
        self.assertEqual(
            metadata["trees"]["stage2"]["sha256"],
            self.fixture.plan["stage2"]["patchedTreeSHA256"],
        )
        self.assertEqual(
            [entry["path"] for entry in metadata["stage3Patches"]],
            [
                "compat/xxmi/patches/0004-stage3-cursor.patch",
                "compat/xxmi/patches/0005-stage3-conditional.patch",
            ],
        )
        readme = (top / "README.md").read_text(encoding="utf-8")
        self.assertIn("0004-stage3-cursor.patch", readme)
        self.assertIn("0005-stage3-conditional.patch", readme)
        self.assertIn(self.fixture.stage3_tree["sha256"], readme)
        self.assertIn("stage-3 candidates", readme)

    def test_rejects_stale_stage3_patch_hash(self):
        self.fixture.plan["stage3"]["patches"][0]["sha256"] = "0" * 64
        self.fixture.plan_path.write_text(
            json.dumps(self.fixture.plan, indent=2) + "\n", encoding="utf-8"
        )
        output = self.root / "out"
        self.assertEqual(self.fixture.run(output), 1)
        self.assertFalse(output.exists() and any(output.iterdir()))

    def test_rejects_missing_stage3_patch(self):
        self.fixture.patch3b.unlink()
        output = self.root / "out"
        self.assertEqual(self.fixture.run(output), 1)
        self.assertFalse(output.exists() and any(output.iterdir()))

    def test_rejects_stage3_tree_mismatch(self):
        self.fixture.plan["stage3"]["patchedTreeSHA256"] = "0" * 64
        self.fixture.plan_path.write_text(
            json.dumps(self.fixture.plan, indent=2) + "\n", encoding="utf-8"
        )
        output = self.root / "out"
        self.assertEqual(self.fixture.run(output), 1)
        self.assertFalse(output.exists() and any(output.iterdir()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
