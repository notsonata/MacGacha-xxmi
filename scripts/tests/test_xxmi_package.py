#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Focused offline tests for the HSR XXMI package builder and verifier."""

from __future__ import annotations

import hashlib
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


def fixture_zzz_pins(root: Path, *, runner: bytes, runner_source: Path, injector: bytes,
                     payload: bytes, compiler: bytes, shader: bytes, d3dx: bytes,
                     main_ini: bytes, help_ini: bytes, patch_ini: bytes, sample: bytes) -> dict:
    return {
        "schemaVersion": 1,
        "package": {
            "id": "zzz-zzmi",
            "version": "1.5.0-macgacha.1",
            "gameID": "zzz",
            "upstreamVersion": "1.5.0",
            "targetExe": "ZenlessZoneZero.exe",
            "supportedRuntimeBundleIDs": ["d3dmetal-wine11.20-gptk4.0b3"],
            "runnerPath": "hook-runner.exe",
            "injectorPath": "3dmloader.dll",
            "payloadPath": "payload/d3d11.dll",
            "archiveName": "zzz-zzmi.zip",
            "manifestName": "zzz-zzmi.manifest.json",
            "payloadRootDirs": ["Core", "ShaderFixes"],
            "shaderPath": "Core/ZZMI/Shaders/TextPrinter.hlsl",
            "license": "GPL-3.0-only",
        },
        "verifiedBinaries": {
            "runner": {
                "sha256": sha(runner),
                "size": len(runner),
                "sourcePath": str(runner_source),
                "sourceSHA256": sha(runner_source.read_bytes()),
            },
            "injector": {
                "sha256": sha(injector),
                "size": len(injector),
                "requiredExports": INJECTOR_EXPORTS,
                "expectedExports": INJECTOR_EXPORTS,
            },
            "payload": {"sha256": sha(payload), "size": len(payload)},
            "d3dcompiler": {"sha256": sha(compiler), "size": len(compiler)},
            "textPrinterShader": {
                "sha256": sha(shader),
                "size": len(shader),
                "path": "Core/ZZMI/Shaders/TextPrinter.hlsl",
            },
            "config": {
                "d3dxIni": {"path": "d3dx.ini", "sha256": sha(d3dx), "size": len(d3dx)},
                "mainIni": {
                    "path": "Core/ZZMI/main.ini",
                    "sha256": sha(main_ini),
                    "size": len(main_ini),
                },
                "helpIni": {"path": "Core/ZZMI/help.ini", "sha256": sha(help_ini)},
                "patchIni": {
                    "path": "Core/ZZMI/d3dx_patch.ini",
                    "sha256": sha(patch_ini),
                },
                "shaderFixesSample": {
                    "path": "ShaderFixes/Sucrose.png",
                    "sha256": sha(sample),
                    "size": len(sample),
                },
            },
        },
        "sources": {
            "fixture-zzmi": {
                "repository": "https://example.invalid/ZZMI-Package",
                "license": "GPL-3.0-only",
            }
        },
    }


class ZzziFixture:
    def __init__(self, root: Path):
        self.root = root
        self.runner_source = write(
            root / "runner-source.c",
            (
                'static const wchar_t *t = L"--target-exe";\n'
                'static const wchar_t *a = L"StarRail.exe";\n'
                'static const wchar_t *b = L"ZenlessZoneZero.exe";\n'
            ).encode(),
        )
        self.runner = write(
            root / "hook-runner.exe",
            make_pe([], dll=False)
            + b"\x00--target-exe\x00StarRail.exe\x00ZenlessZoneZero.exe\x00",
        )
        self.injector = write(root / "3dmloader.dll", make_pe(INJECTOR_EXPORTS))
        self.payload = write(root / "payload" / "d3d11.dll", make_pe([], dll=True))
        self.compiler = write(root / "payload" / "d3dcompiler_47.dll", make_pe([], dll=True))
        self.shader = write(
            root / "payload" / "Core" / "ZZMI" / "Shaders" / "TextPrinter.hlsl",
            b"// zzmi text printer fixture\n",
        )
        self.main_ini = write(
            root / "payload" / "Core" / "ZZMI" / "main.ini",
            b"[ResourceVersionNotification]\ndata = \"ZZMI 1.5.0 (PRESS F12 TO SHOW GUIDE)\"\n"
            b"global $version = 1.50\n",
        )
        self.slotfix = write(
            root / "payload" / "Core" / "ZZMI" / "Libraries" / "SlotFix" / "SlotFix.ini",
            b"[CommandListReset]\n$Poolt[*] = $default_filter\n",
        )
        self.help_ini = write(root / "payload" / "Core" / "ZZMI" / "help.ini", b"[Help]\n")
        self.patch_ini = write(
            root / "payload" / "Core" / "ZZMI" / "d3dx_patch.ini", b"[Patch]\n"
        )
        self.notification = write(
            root / "payload" / "Core" / "ZZMI" / "Notifications" / "UserGuide.md",
            b"# ZZMI fixture guide\n",
        )
        self.sample = write(root / "payload" / "ShaderFixes" / "Sucrose.png", b"png fixture\n")
        self.d3dx = write(
            root / "payload" / "d3dx.ini",
            b"[Loader]\ntarget = ZenlessZoneZero.exe\nloader = XXMI Launcher.exe\n"
            b"launch = C:\\Games\\ZenlessZoneZero Game\\ZenlessZoneZero.exe\nmodule = d3d11.dll\n"
            b"[System]\n[Logging]\nlog_level = info\nunbuffered = 1\n",
        )
        self.pins = fixture_zzz_pins(
            root,
            runner=self.runner.read_bytes(),
            runner_source=self.runner_source,
            injector=self.injector.read_bytes(),
            payload=self.payload.read_bytes(),
            compiler=self.compiler.read_bytes(),
            shader=self.shader.read_bytes(),
            d3dx=self.d3dx.read_bytes(),
            main_ini=self.main_ini.read_bytes(),
            help_ini=self.help_ini.read_bytes(),
            patch_ini=self.patch_ini.read_bytes(),
            sample=self.sample.read_bytes(),
        )
        self.shared_pins_path = root / "shared-pins.json"
        self.shared_pins_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "package": {"id": "hsr-srmi", "version": "2.4.3-test"},
                    "verifiedBinaries": {
                        "injector": {"sha256": sha(self.injector.read_bytes())},
                        "payload": {"sha256": sha(self.payload.read_bytes())},
                        "d3dcompiler": {"sha256": sha(self.compiler.read_bytes())},
                    },
                    "sourcePins": {"xxmiLibsPackage": {"tag": "v1.2.2"}},
                    "sources": {},
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        self.pins["sharedXxmiCore"] = {
            "pins": str(self.shared_pins_path),
            "version": "1.2.2",
            "verifiedPayloadSHA256": sha(self.payload.read_bytes()),
            "verifiedCompilerSHA256": sha(self.compiler.read_bytes()),
            "verifiedInjectorSHA256": sha(self.injector.read_bytes()),
        }
        self.pins["coreCompatibility"] = {
            "minimumVersion": "1.2.0",
            "pinnedVersion": "1.2.2",
            "basis": "Fixture uses the v1.2.0 pool range feature.",
            "upstreamRelease": "https://github.com/SpectrumQT/XXMI-Libs-Package/releases/tag/v1.2.0",
            "featureChecks": [
                {
                    "path": "Core/ZZMI/Libraries/SlotFix/SlotFix.ini",
                    "contains": "$Poolt[*]",
                    "introducedIn": "1.2.0",
                }
            ],
        }
        self.pins_path = root / "zzz-pins.json"
        self.refresh_runtime_pins()
        self.write_pins()

    def runtime_files(self) -> dict[str, Path]:
        return {
            "d3dx.ini": self.d3dx,
            "Core/ZZMI/main.ini": self.main_ini,
            "Core/ZZMI/help.ini": self.help_ini,
            "Core/ZZMI/d3dx_patch.ini": self.patch_ini,
            "Core/ZZMI/Shaders/TextPrinter.hlsl": self.shader,
            "Core/ZZMI/Libraries/SlotFix/SlotFix.ini": self.slotfix,
            "Core/ZZMI/Notifications/UserGuide.md": self.notification,
            "ShaderFixes/Sucrose.png": self.sample,
        }

    def refresh_runtime_pins(self) -> None:
        self.pins["runtimeFiles"] = {
            relative: {
                "size": path.stat().st_size,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
            for relative, path in sorted(self.runtime_files().items())
        }
        normalized = xxmi_package.normalize_d3dx_ini(
            self.d3dx, target_exe="ZenlessZoneZero.exe"
        )
        self.pins["package"]["normalizedD3dxIni"] = {
            "path": "d3dx.ini",
            "size": len(normalized),
            "sha256": sha(normalized),
        }

    def write_pins(self) -> None:
        self.pins_path.write_text(json.dumps(self.pins, indent=2) + "\n", encoding="utf-8")

    def build(self, output: Path) -> dict:
        return xxmi_package.build_package(
            runner=self.runner,
            injector=self.injector,
            payload_dir=self.root / "payload",
            output_dir=output,
            pins_path=self.pins_path,
        )


class ZzziPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-zzz-package-tests-")
        self.root = Path(self.temp.name)
        self.fixture = ZzziFixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_builds_distinct_zzz_identity_and_config(self):
        output = self.root / "out"
        manifest = self.fixture.build(output)
        self.assertTrue((output / "zzz-zzmi.zip").is_file())
        self.assertFalse((output / "hsr-srmi.zip").exists())
        self.assertEqual(manifest["id"], "zzz-zzmi")
        self.assertEqual(manifest["gameID"], "zzz")
        self.assertEqual(manifest["version"], "1.5.0-macgacha.1")
        self.assertEqual(manifest["archiveSHA256"], xxmi_package.sha256_file(output / "zzz-zzmi.zip"))
        paths = [entry["path"] for entry in manifest["files"]]
        self.assertIn("payload/Core/ZZMI/Shaders/TextPrinter.hlsl", paths)
        self.assertIn("payload/Core/ZZMI/main.ini", paths)
        self.assertIn("payload/ShaderFixes/Sucrose.png", paths)
        self.assertNotIn("payload/Core/SRMI/main.ini", paths)
        with zipfile.ZipFile(output / "zzz-zzmi.zip") as archive:
            ini = archive.read("payload/d3dx.ini").decode("utf-8")
            self.assertIn("target = ZenlessZoneZero.exe", ini)
            self.assertIn("loader = hook-runner.exe", ini)
            self.assertIn("proxy_d3d11 =\n", ini)
            self.assertIn(";launch =", ini)
            self.assertNotIn("C:\\Games", ini)
            self.assertIn("log_level = none", ini)
            self.assertIn("unbuffered = 0", ini)
            self.assertNotIn("log_level = info", ini)
        xxmi_package.verify_package(output, pins_path=self.fixture.pins_path)

    def test_zzz_rejects_star_rail_target(self):
        self.fixture.d3dx.write_bytes(self.fixture.d3dx.read_bytes().replace(
            b"target = ZenlessZoneZero.exe", b"target = StarRail.exe"
        ))
        self.fixture.pins["verifiedBinaries"]["config"]["d3dxIni"]["sha256"] = sha(
            self.fixture.d3dx.read_bytes()
        )
        self.fixture.pins["verifiedBinaries"]["config"]["d3dxIni"]["size"] = len(
            self.fixture.d3dx.read_bytes()
        )
        self.fixture.pins["runtimeFiles"]["d3dx.ini"] = {
            "size": self.fixture.d3dx.stat().st_size,
            "sha256": sha(self.fixture.d3dx.read_bytes()),
        }
        self.fixture.write_pins()
        with self.assertRaisesRegex(
            xxmi_package.PackageError, "target must be ZenlessZoneZero.exe"
        ):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_mismatched_game_target_pin(self):
        self.fixture.pins["package"]["targetExe"] = "StarRail.exe"
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "requires targetExe"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_runner_hash_tamper(self):
        self.fixture.runner.write_bytes(
            self.fixture.runner.read_bytes() + b"\x00tampered"
        )
        with self.assertRaisesRegex(xxmi_package.PackageError, "runner SHA-256"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_runner_size_mismatch(self):
        self.fixture.pins["verifiedBinaries"]["runner"]["size"] += 1
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "runner size"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_missing_runner_hash_pin(self):
        del self.fixture.pins["verifiedBinaries"]["runner"]["sha256"]
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "exact SHA-256 pin"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_missing_core_compatibility(self):
        del self.fixture.pins["coreCompatibility"]
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "coreCompatibility"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_older_core_than_minimum(self):
        self.fixture.pins["coreCompatibility"]["minimumVersion"] = "1.2.3"
        self.fixture.pins["coreCompatibility"]["upstreamRelease"] = (
            "https://github.com/SpectrumQT/XXMI-Libs-Package/releases/tag/v1.2.3"
        )
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "older than the compatibility"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_mismatched_upstream_release_version(self):
        self.fixture.pins["coreCompatibility"]["upstreamRelease"] = (
            "https://github.com/SpectrumQT/XXMI-Libs-Package/releases/tag/v1.1.7"
        )
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "declared minimum"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_shared_payload_mismatch(self):
        self.fixture.pins["sharedXxmiCore"]["verifiedPayloadSHA256"] = "0" * 64
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "verifiedPayloadSHA256"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_missing_feature_marker(self):
        self.fixture.slotfix.write_bytes(b"[CommandListReset]\n")
        self.fixture.pins["runtimeFiles"]["Core/ZZMI/Libraries/SlotFix/SlotFix.ini"] = {
            "size": self.fixture.slotfix.stat().st_size,
            "sha256": sha(self.fixture.slotfix.read_bytes()),
        }
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "core feature"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_wrong_upstream_version(self):
        self.fixture.main_ini.write_bytes(
            self.fixture.main_ini.read_bytes().replace(b"ZZMI 1.5.0", b"ZZMI 1.4.9")
        )
        self.fixture.pins["verifiedBinaries"]["config"]["mainIni"]["sha256"] = sha(
            self.fixture.main_ini.read_bytes()
        )
        self.fixture.pins["verifiedBinaries"]["config"]["mainIni"]["size"] = len(
            self.fixture.main_ini.read_bytes()
        )
        self.fixture.write_pins()
        with self.assertRaisesRegex(xxmi_package.PackageError, "does not declare version"):
            self.fixture.build(self.root / "out")

    def test_zzz_rejects_unpinned_config_change(self):
        self.fixture.main_ini.write_bytes(b"[Constants]\nversion = 2\n")
        with self.assertRaisesRegex(xxmi_package.PackageError, "config file SHA-256"):
            self.fixture.build(self.root / "out")

    def test_zzz_build_preserves_hsr_sibling_files(self):
        output = self.root / "resources"
        output.mkdir()
        (output / "manifest.json").write_text("hsr manifest\n", encoding="utf-8")
        (output / "hsr-srmi.zip").write_bytes(b"hsr bytes")
        self.fixture.build(output)
        self.assertEqual(
            (output / "manifest.json").read_text(encoding="utf-8"),
            "hsr manifest\n",
        )
        self.assertEqual((output / "hsr-srmi.zip").read_bytes(), b"hsr bytes")
        self.assertTrue((output / "zzz-zzmi.zip").is_file())
        self.assertTrue((output / "zzz-zzmi.manifest.json").is_file())

    def test_zzz_ignores_user_directories_but_keeps_allowed_shader_fixes(self):
        write(self.root / "payload" / "Mods" / "private.ini", b"user mod\n")
        write(self.root / "payload" / "ShaderCache" / "cache.bin", b"cache\n")
        write(self.root / "payload" / "d3dx_user.ini", b"user settings\n")
        manifest = self.fixture.build(self.root / "out")
        paths = [entry["path"] for entry in manifest["files"]]
        self.assertFalse(any(path.startswith("payload/Mods/") for path in paths))
        self.assertFalse(any(path.startswith("payload/ShaderCache/") for path in paths))
        self.assertNotIn("payload/d3dx_user.ini", paths)
        self.assertIn("payload/ShaderFixes/Sucrose.png", paths)


def rewrite_zzz_package(output: Path, transform) -> None:
    archive_path = output / "zzz-zzmi.zip"
    with zipfile.ZipFile(archive_path) as archive:
        entries = {info.filename: archive.read(info) for info in archive.infolist()}
    transform(entries)
    with zipfile.ZipFile(
        archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, date_time=xxmi_package.ZIP_DATE_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = xxmi_package.ZIP_CREATE_SYSTEM
            info.external_attr = xxmi_package.ZIP_FILE_MODE << 16
            archive.writestr(info, entries[name])
    manifest_path = output / "zzz-zzmi.manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["files"] = [
        {"path": name, "size": len(data), "sha256": sha(data)}
        for name, data in sorted(entries.items())
    ]
    manifest["archiveSize"] = archive_path.stat().st_size
    manifest["archiveSHA256"] = xxmi_package.sha256_file(archive_path)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


class ZzziAuthenticatedRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-zzz-authenticated-tests-")
        self.root = Path(self.temp.name)
        self.fixture = ZzziFixture(self.root)
        self.output = self.root / "out"
        self.fixture.build(self.output)

    def tearDown(self):
        self.temp.cleanup()

    def verify(self) -> None:
        xxmi_package.verify_package(self.output, pins_path=self.fixture.pins_path)

    def test_build_rejects_changed_slotfix(self):
        self.fixture.slotfix.write_bytes(
            self.fixture.slotfix.read_bytes() + b"; unauthenticated change\n"
        )
        with self.assertRaisesRegex(
            xxmi_package.PackageError, "authenticated ZZMI runtime file"
        ):
            self.fixture.build(self.root / "rebuilt")

    def test_build_rejects_extra_runtime_file(self):
        write(
            self.root / "payload" / "Core" / "ZZMI" / "Libraries" / "Extra.ini",
            b"[Extra]\n",
        )
        with self.assertRaisesRegex(
            xxmi_package.PackageError, "unexpected Core/ZZMI/Libraries/Extra.ini"
        ):
            self.fixture.build(self.root / "rebuilt")

    def test_build_rejects_missing_runtime_file(self):
        self.fixture.notification.unlink()
        with self.assertRaisesRegex(
            xxmi_package.PackageError, "missing Core/ZZMI/Notifications/UserGuide.md"
        ):
            self.fixture.build(self.root / "rebuilt")

    def test_verify_rejects_self_consistent_changed_slotfix(self):
        def transform(entries):
            name = "payload/Core/ZZMI/Libraries/SlotFix/SlotFix.ini"
            entries[name] += b"; self-consistent but unauthenticated\n"

        rewrite_zzz_package(self.output, transform)
        with self.assertRaisesRegex(
            xxmi_package.PackageError, "authenticated runtime file does not match"
        ):
            self.verify()

    def test_verify_rejects_self_consistent_extra_file(self):
        def transform(entries):
            entries["payload/Core/ZZMI/Libraries/Extra.ini"] = b"[Extra]\n"

        rewrite_zzz_package(self.output, transform)
        with self.assertRaisesRegex(
            xxmi_package.PackageError, "unexpected payload/Core/ZZMI/Libraries/Extra.ini"
        ):
            self.verify()

    def test_verify_rejects_self_consistent_missing_file(self):
        def transform(entries):
            del entries["payload/Core/ZZMI/Notifications/UserGuide.md"]

        rewrite_zzz_package(self.output, transform)
        with self.assertRaisesRegex(
            xxmi_package.PackageError,
            "missing payload/Core/ZZMI/Notifications/UserGuide.md",
        ):
            self.verify()

    def test_verify_rejects_self_consistent_normalized_config_change(self):
        def transform(entries):
            entries["payload/d3dx.ini"] += b"; normalized config change\n"

        rewrite_zzz_package(self.output, transform)
        with self.assertRaisesRegex(
            xxmi_package.PackageError, "exact normalized hash"
        ):
            self.verify()

    def test_verify_rejects_provenance_mutation(self):
        manifest_path = self.output / "zzz-zzmi.manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["sources"]["fixture-zzmi.repository"] = "https://example.invalid/other"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(
            xxmi_package.PackageError, "pinned provenance"
        ):
            self.verify()


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
            self.assertIn("target = StarRail.exe", ini)
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
        self.assertEqual(manifest["version"], xxmi_package._load_pins(pins)["package"]["version"])
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

    def test_verify_rejects_consistently_rewritten_runner_bytes(self):
        output = self.root / "out"
        self.fixture.build(output)
        archive_path = output / "hsr-srmi.zip"
        with zipfile.ZipFile(archive_path) as archive:
            entries = {info.filename: archive.read(info) for info in archive.infolist()}
        entries["hook-runner.exe"] = entries["hook-runner.exe"] + b"\x00"
        with zipfile.ZipFile(
            archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as archive:
            for name in sorted(entries):
                info = zipfile.ZipInfo(name, date_time=xxmi_package.ZIP_DATE_TIME)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = xxmi_package.ZIP_CREATE_SYSTEM
                info.external_attr = xxmi_package.ZIP_FILE_MODE << 16
                archive.writestr(info, entries[name])
        manifest_path = output / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for entry in manifest["files"]:
            if entry["path"] == "hook-runner.exe":
                entry["size"] = len(entries["hook-runner.exe"])
                entry["sha256"] = sha(entries["hook-runner.exe"])
        manifest["archiveSize"] = archive_path.stat().st_size
        manifest["archiveSHA256"] = xxmi_package.sha256_file(archive_path)
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(xxmi_package.PackageError, "runner SHA-256"):
            xxmi_package.verify_package(output, pins_path=self.fixture.pins_path)

    def test_output_directory_preserves_unrelated_entries(self):
        output = self.root / "out"
        output.mkdir()
        (output / "keep.txt").write_text("keep me", encoding="utf-8")
        manifest = self.fixture.build(output)
        self.assertEqual((output / "keep.txt").read_text(encoding="utf-8"), "keep me")
        self.assertEqual(manifest["id"], "hsr-srmi")

    def test_build_refuses_to_overwrite_a_different_package_manifest(self):
        output = self.root / "out"
        output.mkdir()
        (output / "manifest.json").write_text('{"id": "zzz-zzmi"}\n', encoding="utf-8")
        with self.assertRaisesRegex(xxmi_package.PackageError, "different package"):
            self.fixture.build(output)
        self.assertEqual(
            (output / "manifest.json").read_text(encoding="utf-8"),
            '{"id": "zzz-zzmi"}\n',
        )
        self.assertFalse((output / "hsr-srmi.zip").exists())

    def test_hsr_build_preserves_zzz_sibling_files(self):
        output = self.root / "resources"
        output.mkdir()
        (output / "zzz-zzmi.manifest.json").write_text("{}\n", encoding="utf-8")
        (output / "zzz-zzmi.zip").write_bytes(b"zzz bytes")
        self.fixture.build(output)
        self.assertEqual(
            (output / "zzz-zzmi.manifest.json").read_text(encoding="utf-8"), "{}\n"
        )
        self.assertEqual((output / "zzz-zzmi.zip").read_bytes(), b"zzz bytes")
        self.assertTrue((output / "hsr-srmi.zip").is_file())

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
        for patch in plan.get("stage3", {}).get("patches", []):
            self.assertEqual(pinned[Path(patch["path"]).name], patch["sha256"])
        self.assertEqual(
            pinned[Path(plan["textPrinter"]["patch"]["path"]).name],
            plan["textPrinter"]["patch"]["sha256"],
        )

    def test_zzz_pins_are_consistent_with_shared_core_and_runner_source(self):
        root = Path(__file__).resolve().parents[2]
        pins = json.loads((root / "compat" / "xxmi" / "zzz-source-pins.json").read_text(encoding="utf-8"))
        hsr = json.loads((root / "compat" / "xxmi" / "source-pins.json").read_text(encoding="utf-8"))
        package = pins["package"]
        self.assertEqual(package["id"], "zzz-zzmi")
        self.assertEqual(package["gameID"], "zzz")
        self.assertEqual(package["targetExe"], "ZenlessZoneZero.exe")
        self.assertEqual(package["archiveName"], "zzz-zzmi.zip")
        self.assertEqual(package["manifestName"], "zzz-zzmi.manifest.json")
        self.assertNotEqual(
            package["manifestName"], hsr["package"]["manifestName"]
        )
        self.assertEqual(
            package["shaderPath"],
            pins["verifiedBinaries"]["textPrinterShader"]["path"],
        )
        self.assertEqual(
            package["supportedRuntimeBundleIDs"],
            hsr["package"]["supportedRuntimeBundleIDs"],
        )
        self.assertEqual(
            pins["verifiedBinaries"]["payload"]["sha256"],
            hsr["verifiedBinaries"]["payload"]["sha256"],
        )
        runner = pins["verifiedBinaries"]["runner"]
        source = root / runner["sourcePath"]
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), runner["sourceSHA256"])
        self.assertEqual(runner["sha256"], "98c202f777848bb4811aac1bd86703db89e1a78fbfcd40653f4ffbcfcc730172")
        self.assertEqual(runner["size"], 12800)
        self.assertEqual(pins["package"]["upstreamVersion"], "1.5.2")
        self.assertEqual(pins["coreCompatibility"]["minimumVersion"], "1.2.0")
        self.assertEqual(pins["coreCompatibility"]["pinnedVersion"], "1.2.3")
        self.assertEqual(
            pins["sourcePins"]["zzmiPackage"]["sourceTreeFileCount"], 49
        )
        self.assertEqual(pins["runtimeSource"]["runtimeFileCount"], 47)
        self.assertEqual(len(pins["runtimeFiles"]), 47)
        self.assertIn("d3dx.ini", pins["runtimeFiles"])
        for relative, entry in pins["runtimeFiles"].items():
            self.assertRegex(relative, r"^(Core|ShaderFixes)/|^d3dx\.ini$")
            self.assertGreaterEqual(entry["size"], 0)
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(
            pins["package"]["normalizedD3dxIni"]["sha256"],
            "1f2e0c14df4eabf8b82e5f1731f28d4d00d0c23e78eb25c0c82cf76eafa933aa",
        )
        self.assertEqual(pins["package"]["normalizedD3dxIni"]["size"], 56797)
        self.assertEqual(
            pins["sourcePins"]["zzmiPackage"]["releaseAsset"]["sha256"],
            "dce62cee6fb83eda25c29ac5e0dbd37055efeae0c6e5d90fa0133a4b52a57edc",
        )
        self.assertEqual(
            pins["sources"]["zzmi-package"]["archiveSHA256"],
            pins["sourcePins"]["zzmiPackage"]["archiveSHA256"],
        )
        self.assertEqual(pins["sourcePins"]["zzmiPackage"]["sourceTreeFileCount"], 49)

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
