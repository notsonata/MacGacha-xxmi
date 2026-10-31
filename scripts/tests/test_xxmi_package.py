#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Focused offline tests for the HSR XXMI package builder and verifier."""

from __future__ import annotations

import importlib.util
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "xxmi-package.py"
spec = importlib.util.spec_from_file_location("xxmi_package", SCRIPT)
xxmi_package = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(xxmi_package)

INJECTOR_EXPORTS = [
    "DllMain",
    "HookLibrary",
    "Inject",
    "StartProcess",
    "UnhookLibrary",
    "WaitForInjection",
]


def make_pe(names: list[str], *, dll: bool = True) -> bytes:
    section_rva = 0x1000
    section_raw = 0x200
    section_size = 0x1000
    header_size = 0x200
    data = bytearray(header_size + section_size)
    data[0:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x40)
    data[0x40:0x44] = b"PE\0\0"
    struct.pack_into(
        "<HHIIIHH",
        data,
        0x44,
        0x8664,
        1,
        0,
        0,
        0,
        0xF0,
        0x2022 if dll else 0x0022,
    )
    optional = 0x58
    struct.pack_into("<H", data, optional, 0x20B)
    struct.pack_into("<BB", data, optional + 2, 14, 0)
    struct.pack_into("<I", data, optional + 4, 0x200)
    struct.pack_into("<I", data, optional + 8, 0x200)
    struct.pack_into("<I", data, optional + 12, 0)
    struct.pack_into("<I", data, optional + 16, section_rva)
    struct.pack_into("<Q", data, optional + 24, 0x180000000)
    struct.pack_into("<I", data, optional + 32, 0x1000)
    struct.pack_into("<I", data, optional + 36, 0x200)
    struct.pack_into("<HHHHHH", data, optional + 40, 6, 0, 0, 0, 6, 0)
    struct.pack_into("<I", data, optional + 56, 0x2000)
    struct.pack_into("<I", data, optional + 60, header_size)
    struct.pack_into("<H", data, optional + 68, 2 if dll else 3)
    struct.pack_into("<H", data, optional + 70, 0)
    struct.pack_into("<QQQQ", data, optional + 72, 0x100000, 0x1000, 0x100000, 0x1000)
    struct.pack_into("<I", data, optional + 108, 16)
    struct.pack_into("<II", data, optional + 112, section_rva, 0x100)
    section = optional + 0xF0
    data[section:section + 8] = b".rdata\0\0"
    struct.pack_into("<I", data, section + 8, section_size)
    struct.pack_into("<I", data, section + 12, section_rva)
    struct.pack_into("<I", data, section + 16, section_size)
    struct.pack_into("<I", data, section + 20, section_raw)
    struct.pack_into("<I", data, section + 36, 0x40000040)

    count = len(names)
    export = section_raw
    functions = export + 0x40
    name_table = functions + count * 4
    ordinals = name_table + count * 4
    strings = (ordinals + count * 2 + 3) & ~3

    struct.pack_into(
        "<IIHHIIIIIII",
        data,
        export,
        0,
        0,
        0,
        0,
        section_rva + 0x100,
        1,
        count,
        count,
        section_rva + (functions - section_raw),
        section_rva + (name_table - section_raw),
        section_rva + (ordinals - section_raw),
    )
    string_offset = strings
    for index, name in enumerate(names):
        struct.pack_into("<I", data, functions + index * 4, section_rva)
        struct.pack_into("<I", data, name_table + index * 4, section_rva + string_offset - section_raw)
        struct.pack_into("<H", data, ordinals + index * 2, index)
        encoded = name.encode("ascii") + b"\0"
        data[string_offset:string_offset + len(encoded)] = encoded
        string_offset += len(encoded)
    dll_name = b"fixture.dll\0"
    struct.pack_into("<I", data, export + 12, section_rva + string_offset - section_raw)
    data[string_offset:string_offset + len(dll_name)] = dll_name
    return bytes(data)


def write(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def sha(data: bytes) -> str:
    return xxmi_package.sha256_bytes(data)


def fixture_pins(root: Path, *, injector: bytes, payload: bytes, runner: bytes,
                 compiler: bytes, shader: bytes) -> dict:
    return {
        "schemaVersion": 1,
        "package": {
            "id": "hsr-srmi",
            "version": "2.4.3-macgacha.1",
            "gameID": "starrail",
            "supportedRuntimeBundleIDs": ["d3dmetal-wine11.20-gptk4.0b3"],
            "runnerPath": "hook-runner.exe",
            "injectorPath": "3dmloader.dll",
            "payloadPath": "payload/d3d11.dll",
            "archiveName": "hsr-srmi.zip",
            "manifestName": "manifest.json",
            "license": "GPL-3.0-only",
        },
        "verifiedBinaries": {
            "runner": {"sha256": sha(runner), "size": len(runner)},
            "injector": {
                "sha256": sha(injector),
                "size": len(injector),
                "requiredExports": INJECTOR_EXPORTS,
                "expectedExports": INJECTOR_EXPORTS,
            },
            "payload": {"sha256": sha(payload), "size": len(payload)},
            "d3dcompiler": {"sha256": sha(compiler), "size": len(compiler)},
            "textPrinterShader": {"sha256": sha(shader), "size": len(shader)},
        },
        "sources": {
            "fixture-source": {"repository": "fixture", "license": "GPL-3.0-only"}
        },
    }


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.runner = write(root / "hook-runner.exe", make_pe([], dll=False))
        self.injector = write(root / "3dmloader.dll", make_pe(INJECTOR_EXPORTS))
        self.payload = write(root / "payload" / "d3d11.dll", make_pe([], dll=True))
        self.compiler = write(root / "payload" / "d3dcompiler_47.dll", make_pe([], dll=True))
        self.shader = write(
            root / "payload" / "Core" / "SRMI" / "Shaders" / "TextPrinter.hlsl",
            b"// numeric literal fixture\n",
        )
        write(root / "payload" / "Core" / "SRMI" / "main.ini", b"[Constants]\nfixture=1\n")
        write(root / "payload" / "Mods" / "PersonalMod" / "private.ini", b"user mod\n")
        write(root / "payload" / "ShaderFixes" / "private.png", b"user shader fix\n")
        write(root / "payload" / "ShaderCache" / "cache.bin", b"cache\n")
        write(root / "payload" / "d3dx_user.ini", b"personal settings\n")
        write(root / "payload" / "d3d11_log.txt", b"log\n")
        write(
            root / "payload" / "d3dx.ini",
            b"[Loader]\ntarget = StarRail.exe\nloader = hook-runner.exe\nmodule = d3d11.dll\n"
            b"[System]\nproxy_d3d11 = Z:\\Users\\developer\\runtime\\d3d11.dll\n"
            b"[Logging]\ncalls = 1\ndebug = 1\nunbuffered = 1\n",
        )
        self.pins = fixture_pins(
            root,
            injector=self.injector.read_bytes(),
            payload=self.payload.read_bytes(),
            runner=self.runner.read_bytes(),
            compiler=self.compiler.read_bytes(),
            shader=self.shader.read_bytes(),
        )
        self.pins_path = root / "pins.json"
        self.pins_path.write_text(json.dumps(self.pins, indent=2) + "\n", encoding="utf-8")

    def build(self, output: Path) -> dict:
        return xxmi_package.build_package(
            runner=self.runner,
            injector=self.injector,
            payload_dir=self.root / "payload",
            output_dir=output,
            pins_path=self.pins_path,
        )


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-package-tests-")
        self.root = Path(self.temp.name)
        self.fixture = Fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_builds_deterministic_manifest_and_archive(self):
        first = self.root / "out-a"
        second = self.root / "out-b"
        manifest = self.fixture.build(first)
        manifest_again = self.fixture.build(second)
        self.assertEqual(first.joinpath("hsr-srmi.zip").read_bytes(), second.joinpath("hsr-srmi.zip").read_bytes())
        self.assertEqual(
            first.joinpath("manifest.json").read_bytes(), second.joinpath("manifest.json").read_bytes()
        )
        self.assertEqual(manifest, manifest_again)
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "hsr-srmi")
        self.assertEqual(manifest["version"], "2.4.3-macgacha.1")
        self.assertEqual(manifest["gameID"], "starrail")
        self.assertEqual(manifest["supportedRuntimeBundleIDs"], ["d3dmetal-wine11.20-gptk4.0b3"])
        self.assertEqual(manifest["runnerPath"], "hook-runner.exe")
        self.assertEqual(manifest["injectorPath"], "3dmloader.dll")
        self.assertEqual(manifest["payloadPath"], "payload/d3d11.dll")
        self.assertEqual(manifest["license"], "GPL-3.0-only")
        self.assertTrue(all(isinstance(value, str) for value in manifest["sources"].values()))
        self.assertIsInstance(manifest["archiveSize"], int)
        self.assertEqual(manifest["archiveSize"], first.joinpath("hsr-srmi.zip").stat().st_size)
        self.assertEqual(manifest["archiveSHA256"], xxmi_package.sha256_file(first / "hsr-srmi.zip"))
        paths = [entry["path"] for entry in manifest["files"]]
        self.assertEqual(paths, sorted(paths))
        self.assertNotIn("Mods/PersonalMod/private.ini", paths)
        self.assertFalse(any(path.startswith(("payload/Mods/", "payload/ShaderFixes/", "payload/ShaderCache/")) for path in paths))
        self.assertNotIn("payload/d3dx_user.ini", paths)
        self.assertNotIn("payload/d3d11_log.txt", paths)
        with zipfile.ZipFile(first / "hsr-srmi.zip") as archive:
            infos = archive.infolist()
            self.assertEqual([info.filename for info in infos], paths)
            for info in infos:
                self.assertFalse(info.is_dir())
                self.assertEqual(info.date_time, xxmi_package.ZIP_DATE_TIME)
                self.assertEqual(info.create_system, 3)
                self.assertEqual(info.external_attr >> 16, xxmi_package.ZIP_FILE_MODE)
                self.assertEqual(info.compress_type, zipfile.ZIP_DEFLATED)
                data = archive.read(info)
                entry = next(item for item in manifest["files"] if item["path"] == info.filename)
                self.assertEqual(entry["size"], len(data))
                self.assertEqual(entry["sha256"], sha(data))
            ini = archive.read("payload/d3dx.ini").decode("utf-8")
            self.assertIn("proxy_d3d11 =\n", ini)
            self.assertNotIn("developer", ini)
            self.assertIn("calls = 0", ini)
            self.assertIn("debug = 0", ini)
            self.assertIn("unbuffered = 0", ini)

    def test_verify_actual_generated_package(self):
        package = Path(__file__).resolve().parents[2] / "App" / "Resources" / "XXMI"
        if not (package / "manifest.json").is_file():
            self.skipTest("generated App/Resources/XXMI package is not present")
        pins = Path(__file__).resolve().parents[2] / "compat" / "xxmi" / "source-pins.json"
        manifest = xxmi_package.verify_package(package, pins_path=pins)
        self.assertEqual(manifest["version"], "2.4.3-macgacha.1")
        self.assertEqual(manifest["archiveSize"], (package / "hsr-srmi.zip").stat().st_size)
        with zipfile.ZipFile(package / "hsr-srmi.zip") as archive:
            for entry in manifest["files"]:
                data = archive.read(entry["path"])
                self.assertEqual(entry["size"], len(data))
                self.assertEqual(entry["sha256"], sha(data))

    def test_rejects_unexpected_payload_root_file(self):
        write(self.root / "payload" / "notes.txt", b"personal note\n")
        with self.assertRaisesRegex(xxmi_package.PackageError, "refusing to package user data"):
            self.fixture.build(self.root / "out")

    def test_rejects_symlink_in_payload(self):
        target = write(self.root / "elsewhere.ini", b"x")
        link = self.root / "payload" / "Core" / "SRMI" / "linked.ini"
        link.symlink_to(target)
        with self.assertRaisesRegex(xxmi_package.PackageError, "symlink"):
            self.fixture.build(self.root / "out")

    def test_rejects_tampered_payload_hash(self):
        write(self.root / "payload" / "d3d11.dll", make_pe([], dll=True) + b"tampered")
        with self.assertRaisesRegex(xxmi_package.PackageError, "payload D3D11 SHA-256"):
            self.fixture.build(self.root / "out")

    def test_rejects_bad_ini_contract(self):
        write(
            self.root / "payload" / "d3dx.ini",
            b"[Loader]\ntarget = NotStarRail.exe\nloader = hook-runner.exe\nmodule = d3d11.dll\n"
            b"[System]\nproxy_d3d11 = Z:\\Users\\developer\\d3d11.dll\n"
            b"[Logging]\ncalls = 1\ndebug = 1\nunbuffered = 1\n",
        )
        with self.assertRaisesRegex(xxmi_package.PackageError, "target must be StarRail.exe"):
            self.fixture.build(self.root / "out")

    def test_rejects_missing_injector_export(self):
        self.fixture.injector = write(
            self.root / "3dmloader.dll", make_pe(INJECTOR_EXPORTS[:-1])
        )
        self.fixture.pins = fixture_pins(
            self.root,
            injector=self.fixture.injector.read_bytes(),
            payload=self.fixture.payload.read_bytes(),
            runner=self.fixture.runner.read_bytes(),
            compiler=self.fixture.compiler.read_bytes(),
            shader=self.fixture.shader.read_bytes(),
        )
        self.fixture.pins_path.write_text(json.dumps(self.fixture.pins, indent=2) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(xxmi_package.PackageError, "missing required exports"):
            self.fixture.build(self.root / "out")

    def test_verify_rejects_undeclared_archive_entry(self):
        output = self.root / "out"
        self.fixture.build(output)
        with zipfile.ZipFile(output / "hsr-srmi.zip", "a") as archive:
            info = zipfile.ZipInfo("payload/Unexpected.txt", date_time=xxmi_package.ZIP_DATE_TIME)
            info.create_system = 3
            info.external_attr = xxmi_package.ZIP_FILE_MODE << 16
            archive.writestr(info, b"unexpected")
        with self.assertRaisesRegex(xxmi_package.PackageError, "exactly match"):
            xxmi_package.verify_package(output, pins_path=self.fixture.pins_path)

    def test_verify_rejects_tampered_archive_bytes(self):
        output = self.root / "out"
        self.fixture.build(output)
        archive_path = output / "hsr-srmi.zip"
        data = bytearray(archive_path.read_bytes())
        data[-20] ^= 0xFF
        archive_path.write_bytes(data)
        with self.assertRaises(xxmi_package.PackageError):
            xxmi_package.verify_package(output, pins_path=self.fixture.pins_path)

    def test_output_directory_with_unrelated_entries_is_refused(self):
        output = self.root / "out"
        output.mkdir()
        (output / "keep.txt").write_text("keep me", encoding="utf-8")
        with self.assertRaisesRegex(xxmi_package.PackageError, "unrelated entries"):
            self.fixture.build(output)
        self.assertEqual((output / "keep.txt").read_text(encoding="utf-8"), "keep me")

    def test_source_pins_and_build_plan_patch_hashes_agree(self):
        root = Path(__file__).resolve().parents[2]
        pins = json.loads((root / "compat" / "xxmi" / "source-pins.json").read_text(encoding="utf-8"))
        plan = json.loads(
            (root / "compat" / "xxmi" / "build" / "payload-build-plan.json").read_text(encoding="utf-8")
        )
        pinned = {
            Path(entry["path"]).name: entry["sha256"]
            for entry in pins["sourcePins"]["patches"]
        }
        for entry in plan["basePatches"]:
            self.assertEqual(pinned[Path(entry["path"]).name], entry["sha256"])
        self.assertEqual(pinned[Path(plan["stage2"]["patch"]["path"]).name], plan["stage2"]["patch"]["sha256"])
        self.assertEqual(
            pinned[Path(plan["textPrinter"]["patch"]["path"]).name],
            plan["textPrinter"]["patch"]["sha256"],
        )

    def test_rebuild_tool_fails_closed_without_toolchain(self):
        script = Path(__file__).resolve().parents[2] / "scripts" / "xxmi-rebuild-payload.py"
        command = [
            sys.executable,
            "-I",
            str(script),
            "--check",
            "--source", str(self.root / "missing-source"),
            "--generated-assets", str(self.root / "missing-generated"),
            "--third-party-objects", str(self.root / "missing-objects"),
            "--clangxx", str(self.root / "missing-clang++"),
            "--clang-resource", str(self.root / "missing-clang-resource"),
            "--msvc-include", str(self.root / "missing-msvc-include"),
            "--msvc-lib", str(self.root / "missing-msvc-lib"),
            "--windows-sdk-include", str(self.root / "missing-sdk-include"),
            "--windows-sdk-lib", str(self.root / "missing-sdk-lib"),
            "--lld-link", str(self.root / "missing-lld-link"),
        ]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing pinned clean source", result.stderr)
        self.assertIn("missing lld_link", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
