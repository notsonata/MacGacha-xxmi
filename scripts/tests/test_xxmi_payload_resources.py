#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline tests for the payload's Overlay SPRITEFONT and VERSIONINFO resources.

The DirectX11 Overlay constructor loads three embedded SPRITEFONT resources; a
payload with an empty PE resource directory fails before any text is drawn.
These tests use synthetic trees, fonts, archives and PE images only. They run
no compiler, linker, Windows executable, Wine, game or injector.
"""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import struct
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "xxmi-resources"
PLAN_PATH = ROOT / "compat" / "xxmi" / "build" / "payload-build-plan.json"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


RES = load("xxmi_payload_resources", ROOT / "scripts" / "xxmi-payload-resources.py")
REBUILD = load("xxmi_rebuild_payload", ROOT / "scripts" / "xxmi-rebuild-payload.py")
PACKAGE = load("xxmi_package", ROOT / "scripts" / "xxmi-package.py")
STAGE3 = load("xxmi_rebuild_stage3_tests", Path(__file__).resolve().parent / "test_xxmi_rebuild_stage3.py")
FAKE_PE = load("xxmi_fake_pe", FIXTURES / "fake_pe.py")

COMMIT = "c" * 40

RC_TEXT = r"""// Synthetic resource script mirroring the pinned DirectX11.rc statements.
#include "..\version.h"
#include "windows.h"

LANGUAGE LANG_ENGLISH, SUBLANG_ENGLISH_US

IDR_COURIERBOLD		SPRITEFONT		"..\\courierbold.spritefont"
IDR_COURIERSMALL	SPRITEFONT		"..\\couriersmall.spritefont"
IDR_ARIAL		SPRITEFONT		"..\\arial.spritefont"

LANGUAGE LANG_GERMAN, SUBLANG_GERMAN_SWISS

VS_VERSION_INFO VERSIONINFO
 FILEVERSION        VER_FILE_VERSION
 PRODUCTVERSION     VER_PRODUCT_VERSION
 FILEFLAGSMASK      0x3fL
 FILEFLAGS          VER_FILEFLAGS
 FILEOS             VER_FILEOS
 FILETYPE           VER_FILETYPE
 FILESUBTYPE        0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "FileDescription",  "XXMI DLL (3Dmigoto) - d3d11.dll\0"
            VALUE "FileVersion",      VER_FILE_VERSION_STR "\0"
            VALUE "ProductName",      VER_PRODUCTNAME_STR "\0"
            VALUE "CompanyName",      VER_COMPANYNAME_STR "\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"""

VERSION_H = r"""#include "version.generated.h"
#ifndef VERSION_MAJOR
#define VERSION_MAJOR               0
#endif
#ifndef VERSION_MINOR
#define VERSION_MINOR               0
#endif
#ifndef VERSION_REVISION
#define VERSION_REVISION            0
#endif
#ifndef VERSION_BUILD
#define VERSION_BUILD               0
#endif
#ifndef VER_COMPANYNAME_STR
#define VER_COMPANYNAME_STR            ""
#endif
#define STRINGIZE2(s) #s
#define STRINGIZE(s) STRINGIZE2(s)
#define VER_FILE_VERSION \
    VERSION_MAJOR, VERSION_MINOR, VERSION_REVISION, VERSION_BUILD
#define VER_FILE_VERSION_STR \
    STRINGIZE(VERSION_MAJOR) "." \
    STRINGIZE(VERSION_MINOR) "." \
    STRINGIZE(VERSION_REVISION) "." \
    STRINGIZE(VERSION_BUILD)
#define VER_PRODUCTNAME_STR         "XXMI DLL (3Dmigoto)"
#define VER_PRODUCT_VERSION         VER_FILE_VERSION
#ifdef _DEBUG
  #define VER_VER_DEBUG             VS_FF_DEBUG
#else
  #define VER_VER_DEBUG             0
#endif
#define VER_FILEOS                  VOS_NT_WINDOWS32
#define VER_FILEFLAGS               VER_VER_DEBUG
#define VER_FILETYPE                VFT_DLL
#define SPRITEFONT					256
#define IDR_COURIERBOLD				101
#define IDR_COURIERSMALL			102
#define IDR_ARIAL				103
"""

OVERLAY_CPP = """\
HRSRC a = FindResource(h, MAKEINTRESOURCE(IDR_COURIERBOLD), MAKEINTRESOURCE(SPRITEFONT));
HRSRC b = FindResource(h, MAKEINTRESOURCE(IDR_ARIAL), MAKEINTRESOURCE(SPRITEFONT));
HRSRC c = FindResource(h, MAKEINTRESOURCE(IDR_COURIERSMALL), MAKEINTRESOURCE(SPRITEFONT));
"""


def spritefont(seed: int, glyphs: int = 4, *, trailing: bytes = b"") -> bytes:
    """A structurally valid DirectXTK MakeSpriteFont blob."""
    body = bytearray(b"DXTKfont" + struct.pack("<I", glyphs))
    for index in range(glyphs):
        body += struct.pack("<I", 32 + index) + bytes([seed]) * 28
    stride, rows = 8, 2
    body += struct.pack("<fI", 14.0, 63) + struct.pack("<5I", 2, 2, 28, stride, rows)
    body += bytes([seed ^ 0x5A]) * (stride * rows)
    return bytes(body) + trailing


def write(path: Path, data: bytes | str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
    return path


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def repin(entry: dict, path: Path) -> None:
    """Accept an edited input so a test reaches the semantic check behind the pin."""
    data = path.read_bytes()
    entry.update(sha256=sha(data), size=len(data), gitBlobSHA1=RES.git_blob_sha1(data))


class ResourceTree:
    """Synthetic source tree, resource inputs and upstream archive."""

    FONTS = {"courierbold.spritefont": 1, "couriersmall.spritefont": 2, "arial.spritefont": 3}

    def __init__(self, root: Path):
        self.root = root
        self.source = root / "source"
        self.assets = root / "assets"
        write(self.source / "DirectX11" / "DirectX11.rc", RC_TEXT)
        write(self.source / "version.h", VERSION_H)
        write(self.source / "version.generated.h", b"")
        write(self.source / "DirectX11" / "Overlay.cpp", OVERLAY_CPP)
        self.fonts = {name: spritefont(seed) for name, seed in self.FONTS.items()}
        for name, data in self.fonts.items():
            write(self.assets / name, data)
        self.archive = root / "upstream.tar.gz"
        self.write_archive()

    def write_archive(self, overrides: dict[str, bytes] | None = None) -> None:
        members = {
            "DirectX11/DirectX11.rc": (self.source / "DirectX11" / "DirectX11.rc").read_bytes(),
            "version.h": (self.source / "version.h").read_bytes(),
            "DirectX11/Overlay.cpp": OVERLAY_CPP.encode(),
            **self.fonts,
            **(overrides or {}),
        }
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
            for name, data in members.items():
                info = tarfile.TarInfo(f"Pkg-{COMMIT}/{name}")
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        self.archive.write_bytes(buffer.getvalue())

    def describe(self) -> dict:
        return RES.describe(
            self.source, self.assets, archive=self.archive,
            archive_sha256=sha(self.archive.read_bytes()),
            archive_url="https://example.invalid/archive.tar.gz", commit=COMMIT,
            template=RES.DEFAULT_TEMPLATE,
        )


class ResContainerTests(unittest.TestCase):
    def test_round_trip_and_alignment(self):
        entries = [RES.ResEntry(256, 101, 0x409, 0x30, b"abc"), RES.ResEntry(16, 1, 0x807, 0x30, b"12345")]
        blob = RES.build_res(entries)
        self.assertEqual(blob[:32], struct.pack("<II", 0, 32) + b"\xff\xff\0\0\xff\xff\0\0" + b"\0" * 16)
        self.assertEqual(len(blob) % 4, 0)
        self.assertEqual([(e.type, e.name, e.lang, e.data) for e in RES.parse_res(blob)],
                         [(e.type, e.name, e.lang, e.data) for e in entries])

    def test_rejects_malformed_containers(self):
        blob = RES.build_res([RES.ResEntry(256, 101, 0x409, 0x30, b"abcde")])
        cases = {
            "signature": b"\1" + blob[1:],
            "padding": blob[:-1],
            "exceeds": blob[:40],
            "header size": blob[:36] + struct.pack("<I", 30) + blob[40:],
        }
        for label, data in cases.items():
            with self.subTest(label), self.assertRaises(RES.ResourceError):
                RES.parse_res(data)


class VersionInfoTests(unittest.TestCase):
    def test_round_trip(self):
        blob = RES.build_version_info(
            [("FileDescription", "d3d11"), ("CompanyName", "")], string_table_key="040904b0",
            translation=(0x409, 1200), file_version=(1, 2, 3, 4), product_version=(1, 2, 3, 4),
            file_flags_mask=0x3F, file_flags=0, file_os=0x40004, file_type=2, file_subtype=0,
        )
        parsed = RES.parse_version_info(blob)
        self.assertEqual(parsed["strings"], {"FileDescription": "d3d11", "CompanyName": ""})
        self.assertEqual(parsed["translation"], [0x409, 1200])
        self.assertEqual(parsed["stringTableKey"], "040904b0")
        self.assertEqual(parsed["fixed"][2:4], [(1 << 16) | 2, (3 << 16) | 4])
        with self.assertRaises(RES.ResourceError):
            RES.parse_version_info(blob + b"\0\0\0\0")
        with self.assertRaises(RES.ResourceError):
            RES.parse_version_info(blob[:40])


class SpriteFontTests(unittest.TestCase):
    def test_accepts_layout_and_reports_trailing_bytes(self):
        info = RES.parse_spritefont(spritefont(1, trailing=b"\0" * 8))
        self.assertEqual((info["glyphCount"], info["firstCharacter"], info["trailingBytes"]), (4, 32, 8))

    def test_rejects_corrupt_fonts(self):
        good = spritefont(1)
        unordered = bytearray(good)
        struct.pack_into("<I", unordered, 12 + 32, 31)
        cases = {
            "magic": b"DXTKfonX" + good[8:],
            "truncated texture": good[:-1],
            "unordered": bytes(unordered),
            "no glyphs": b"DXTKfont" + struct.pack("<I", 0) + good[12:],
            "empty": b"",
        }
        for label, data in cases.items():
            with self.subTest(label), self.assertRaises(RES.ResourceError):
                RES.parse_spritefont(data)


class CompileResourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-resources-")
        self.tree = ResourceTree(Path(self.temp.name))
        self.spec = self.tree.describe()

    def tearDown(self):
        self.temp.cleanup()

    def test_describe_reads_ids_from_header_and_authenticates_fonts(self):
        fonts = {font["macro"]: font for font in self.spec["fonts"]}
        self.assertEqual({k: v["id"] for k, v in fonts.items()},
                         {"IDR_COURIERBOLD": 101, "IDR_COURIERSMALL": 102, "IDR_ARIAL": 103})
        self.assertEqual(self.spec["spriteFontType"], 256)
        for font in self.spec["fonts"]:
            data = self.tree.fonts[font["path"]]
            self.assertEqual(font["sha256"], sha(data))
            self.assertEqual(font["gitBlobSHA1"], hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest())
            self.assertEqual(font["upstreamMember"], f"Pkg-{COMMIT}/{font['path']}")
        self.assertEqual(self.spec["version"]["strings"], {
            "FileDescription": "XXMI DLL (3Dmigoto) - d3d11.dll", "FileVersion": "0.0.0.0",
            "ProductName": "XXMI DLL (3Dmigoto)", "CompanyName": "",
        })
        self.assertEqual(self.spec["version"]["fixed"],
                         {"FILEFLAGSMASK": 0x3F, "FILEFLAGS": 0, "FILEOS": 0x40004,
                          "FILETYPE": 2, "FILESUBTYPE": 0})

    def test_res_holds_exact_fonts_and_version(self):
        res, record = RES.compile_resources(self.tree.source, self.tree.assets, self.spec)
        self.assertEqual(sha(res), self.spec["res"]["sha256"])
        entries = RES.parse_res(res)
        self.assertEqual([(e.type, e.name, e.lang) for e in entries],
                         [(256, 101, 0x409), (256, 102, 0x409), (256, 103, 0x409), (16, 1, 0x807)])
        self.assertEqual([e.data for e in entries[:3]],
                         [self.tree.fonts[n] for n in ("courierbold.spritefont", "couriersmall.spritefont", "arial.spritefont")])
        self.assertEqual(RES.parse_version_info(entries[3].data)["strings"]["FileVersion"], "0.0.0.0")
        self.assertEqual(record["version"]["sha256"], sha(entries[3].data))

    def test_build_writes_once_per_stage_directory(self):
        build = Path(self.temp.name) / "stage1" / "build"
        output = RES.build_stage_resources(self.tree.source, self.tree.assets, self.spec, build)
        self.assertEqual(sha(output.read_bytes()), self.spec["res"]["sha256"])
        with self.assertRaisesRegex(RES.ResourceError, "reuse"):
            RES.build_stage_resources(self.tree.source, self.tree.assets, self.spec, build)

    def assert_compile_fails(self, pattern: str):
        with self.assertRaisesRegex(RES.ResourceError, pattern):
            RES.compile_resources(self.tree.source, self.tree.assets, self.spec)

    def test_rejects_altered_or_missing_font(self):
        write(self.tree.assets / "arial.spritefont", spritefont(9))
        self.assert_compile_fails("IDR_ARIAL font SHA-256 mismatch")
        (self.tree.assets / "arial.spritefont").unlink()
        self.assert_compile_fails("missing IDR_ARIAL font")

    def test_rejects_changed_resource_id(self):
        path = self.tree.source / "version.h"
        path.write_text(VERSION_H.replace("IDR_ARIAL				103", "IDR_ARIAL				104"))
        repin(self.spec["headers"][0], path)
        self.assert_compile_fails("IDR_ARIAL resource ID differs")

    def test_rejects_changed_rc_declarations(self):
        path = self.tree.source / "DirectX11" / "DirectX11.rc"
        path.write_text(RC_TEXT.replace('IDR_ARIAL		SPRITEFONT		"..\\\\arial.spritefont"\n', ""))
        repin(self.spec["script"], path)
        self.assert_compile_fails("SPRITEFONT declarations differ")
        path.write_text(RC_TEXT.replace("..\\\\arial.spritefont", "..\\\\..\\\\arial.spritefont"))
        repin(self.spec["script"], path)
        self.assert_compile_fails("escapes the source tree")
        path.write_text(RC_TEXT.replace("SUBLANG_ENGLISH_US", "SUBLANG_GERMAN_SWISS", 1))
        repin(self.spec["script"], path)
        self.assert_compile_fails("language differs")

    def test_rejects_unpinned_rc_or_header(self):
        write(self.tree.source / "DirectX11" / "DirectX11.rc", RC_TEXT + "\n")
        self.assert_compile_fails("resource script SHA-256 mismatch")

    def test_rejects_overlay_that_no_longer_loads_a_font(self):
        write(self.tree.source / "DirectX11" / "Overlay.cpp", OVERLAY_CPP.replace("IDR_ARIAL", "IDR_OTHER"))
        self.assert_compile_fails("no longer loads IDR_ARIAL")

    def test_rejects_plan_res_digest_mismatch(self):
        self.spec["res"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(RES.ResourceError, "does not match the plan"):
            RES.build_stage_resources(self.tree.source, self.tree.assets, self.spec,
                                      Path(self.temp.name) / "b")

    def test_describe_requires_authentic_archive(self):
        with self.assertRaisesRegex(RES.ResourceError, "archive SHA-256"):
            RES.describe(self.tree.source, self.tree.assets, archive=self.tree.archive,
                         archive_sha256="0" * 64, archive_url="u", commit=COMMIT,
                         template=RES.DEFAULT_TEMPLATE)
        self.tree.write_archive({"arial.spritefont": spritefont(7)})
        with self.assertRaisesRegex(RES.ResourceError, "differs from the upstream archive"):
            self.tree.describe()
        self.tree.write_archive()
        with self.assertRaisesRegex(RES.ResourceError, "pinned commit"):
            RES.describe(self.tree.source, self.tree.assets, archive=self.tree.archive,
                         archive_sha256=sha(self.tree.archive.read_bytes()), archive_url="u",
                         commit="d" * 40, template=RES.DEFAULT_TEMPLATE)


class DllResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-dll-resources-")
        self.tree = ResourceTree(Path(self.temp.name))
        self.spec = self.tree.describe()
        res, _ = RES.compile_resources(self.tree.source, self.tree.assets, self.spec)
        self.entries = [(e.type, e.name, e.lang, e.data) for e in RES.parse_res(res)]
        self.expected = RES.expected_dll_resources(self.spec)

    def tearDown(self):
        self.temp.cleanup()

    def test_accepts_exact_resources_and_parses_every_font(self):
        result = RES.verify_dll_resources(FAKE_PE.build_dll(self.entries), self.expected)
        self.assertEqual(result["entryCount"], 4)
        fonts = [e for e in result["entries"] if "spritefont" in e]
        self.assertEqual([e["name"] for e in fonts], [101, 102, 103])
        self.assertTrue(all(e["spritefont"]["glyphCount"] == 4 for e in fonts))

    def test_rejects_resource_less_payload(self):
        with self.assertRaisesRegex(RES.ResourceError, "resource directory is empty"):
            RES.verify_dll_resources(FAKE_PE.build_dll(None), self.expected)

    def test_rejects_corrupt_missing_extra_or_relabelled_font(self):
        corrupt = list(self.entries)
        data = bytearray(corrupt[2][3])
        data[-1] ^= 1
        corrupt[2] = (*corrupt[2][:3], bytes(data))
        cases = {
            "bytes do not match": corrupt,
            "missing PE resources": self.entries[1:],
            "unexpected PE resources": self.entries + [(256, 104, 0x409, b"x")],
            "missing PE resources: \\(256, 101, 1033\\)": [(256, 101, 0x407, self.entries[0][3])] + self.entries[1:],
        }
        for pattern, entries in cases.items():
            with self.subTest(pattern), self.assertRaisesRegex(RES.ResourceError, pattern):
                RES.verify_dll_resources(FAKE_PE.build_dll(entries), self.expected)

    def test_rejects_out_of_bounds_directory_and_duplicates(self):
        dll = bytearray(FAKE_PE.build_dll(self.entries))
        pe = struct.unpack_from("<I", dll, 0x3C)[0]
        directory = pe + 24 + 112 + 16
        shrunk = bytearray(dll)
        struct.pack_into("<I", shrunk, directory + 4, 16)
        with self.assertRaisesRegex(RES.ResourceError, "bounds"):
            RES.verify_dll_resources(bytes(shrunk), self.expected)
        rva = struct.unpack_from("<I", dll, directory)[0]
        root = RES._pe_layout(bytes(dll))[1][1][2] + (rva - RES._pe_layout(bytes(dll))[1][1][0])
        named, ids = struct.unpack_from("<HH", dll, root + 12)
        self.assertEqual(ids, 2)
        dll[root + 24:root + 32] = dll[root + 16:root + 24]
        with self.assertRaisesRegex(RES.ResourceError, "duplicate"):
            RES.verify_dll_resources(bytes(dll), self.expected)


    def test_rejects_named_count_for_integer_entries(self):
        dll = bytearray(FAKE_PE.build_dll(self.entries))
        (_, _), sections = RES._pe_layout(bytes(dll))
        root = sections[1][2]
        struct.pack_into("<HH", dll, root + 12, 2, 0)
        with self.assertRaisesRegex(RES.ResourceError, "partition"):
            RES.verify_dll_resources(bytes(dll), self.expected)

    def test_rejects_reversed_entries_at_root_and_nested_directory(self):
        original = FAKE_PE.build_dll(self.entries)
        (_, _), sections = RES._pe_layout(original)
        root = sections[1][2]
        # Type 256 owns the three font identifiers in a second-level table.
        child = struct.unpack_from("<I", original, root + 28)[0] & 0x7FFFFFFF
        for directory in (root, root + child):
            with self.subTest(directory=directory):
                dll = bytearray(original)
                first = bytes(dll[directory + 16:directory + 24])
                dll[directory + 16:directory + 24] = dll[directory + 24:directory + 32]
                dll[directory + 24:directory + 32] = first
                with self.assertRaisesRegex(RES.ResourceError, "order"):
                    RES.verify_dll_resources(bytes(dll), self.expected)

    def test_truncated_optional_headers_raise_domain_errors(self):
        dll = FAKE_PE.build_dll(self.entries)
        for length in range(88, 240):
            with self.subTest(length=length), self.assertRaises(RES.ResourceError):
                RES.parse_pe_resources(dll[:length])


FAKE_RES_LINKER = """#!{interpreter}
import hashlib
import importlib.util
import os
import sys

sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

res_module = load("res", {resources!r})
fake_pe = load("fake_pe", {fake_pe!r})
rsp = sys.argv[1][1:]
lines = open(rsp, encoding="utf-8").read().splitlines()
digest = hashlib.sha256()
for path in (line for line in lines if line.endswith(".obj")):
    digest.update(open(path, "rb").read())
entries = []
for path in (line for line in lines if line.endswith(".res")):
    entries += [(e.type, e.name, e.lang, e.data) for e in res_module.parse_res(open(path, "rb").read())]
open(os.path.join(os.getcwd(), "d3d11.dll"), "wb").write(fake_pe.build_dll(entries or None, digest.digest()))
"""


class RebuildResourceStageTests(unittest.TestCase):
    """Every stage compiles, links and verifies its own DirectX11.res."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-rebuild-resources-")
        self.root = Path(self.temp.name)
        self.fixture = STAGE3.Stage3Fixture(self.root / "stage3")
        tree = ResourceTree(self.root / "resources")
        self.spec = tree.describe()
        for relative in ("DirectX11/DirectX11.rc", "version.h", "version.generated.h", "DirectX11/Overlay.cpp"):
            data = (tree.source / relative).read_bytes()
            write(self.fixture.source / relative, data)
            for name in ("expected-stage1", "expected-stage2", "expected-stage3"):
                write(self.fixture.root / name / relative, data)
        for name, data in tree.fonts.items():
            write(self.fixture.generated / name, data)
        plan = self.fixture.plan
        plan["sourcePin"]["cleanTreeSHA256"] = REBUILD.tree_manifest(self.fixture.source)["sha256"]
        plan["sourcePin"]["cleanFileCount"] += 4
        plan["resources"] = self.spec
        res, _ = RES.compile_resources(tree.source, tree.assets, self.spec)
        entries = [(e.type, e.name, e.lang, e.data) for e in RES.parse_res(res)]
        objects = {"stage1": self.fixture.objects1, "stage2": self.fixture.objects2, "stage3": self.fixture.objects3}
        for index, name in enumerate(("stage1", "stage2", "stage3"), start=1):
            plan[name]["patchedTreeSHA256"] = REBUILD.tree_manifest(self.fixture.root / f"expected-{name}")["sha256"]
            plan[name]["link"]["rspLines"].append(RES.RES_LINK_LINE)
            text = hashlib.sha256(b"".join(objects[name][n] for n in ("a.cpp", "b.cpp", "c.c"))).digest()
            plan[name]["candidateSHA256"] = sha(FAKE_PE.build_dll(entries, text))
        linker = self.fixture.toolchain["lld_link"]
        linker.write_text(FAKE_RES_LINKER.replace("{interpreter}", sys.executable).format(
            resources=str(ROOT / "scripts" / "xxmi-payload-resources.py"),
            fake_pe=str(FIXTURES / "fake_pe.py"),
        ))

    def tearDown(self):
        self.temp.cleanup()

    def build(self, name: str = "out") -> dict:
        return REBUILD.build(self.fixture.plan, source=self.fixture.source,
                             generated_assets=self.fixture.generated,
                             third_party_objects=self.fixture.third_party,
                             toolchain=self.fixture.toolchain, output_dir=self.root / name)

    def test_each_stage_compiles_links_and_verifies_its_own_resources(self):
        manifest = self.build()
        self.assertEqual(manifest["candidate"]["sha256"], self.fixture.plan["stage3"]["candidateSHA256"])
        self.assertEqual([e["name"] for e in manifest["resources"]["entries"]], [101, 102, 103, 1])
        res_files = [self.root / "out" / "work" / name / "build" / RES.RES_NAME for name in ("stage1", "stage2", "stage3")]
        self.assertEqual({sha(path.read_bytes()) for path in res_files}, {self.spec["res"]["sha256"]})
        self.assertEqual(len({path.stat().st_ino for path in res_files}), 3)
        for name in ("stage1", "stage2", "stage3"):
            rsp = (self.root / "out" / "work" / name / "build" / f"{name}.rsp").read_text().splitlines()
            self.assertEqual(Path(rsp[-1]).resolve(),
                             (self.root / "out" / "work" / name / "build" / RES.RES_NAME).resolve())

    def test_rejects_plan_that_does_not_link_the_resources(self):
        self.fixture.plan["stage2"]["link"]["rspLines"].remove(RES.RES_LINK_LINE)
        with self.assertRaisesRegex(REBUILD.BuildError, "stage2 link must name"):
            self.build()

    def test_rejects_resource_link_without_resources_record(self):
        del self.fixture.plan["resources"]
        with self.assertRaisesRegex(REBUILD.BuildError, "no resources record"):
            self.build()

    def test_rejects_altered_resource_input_before_any_output(self):
        write(self.fixture.generated / "arial.spritefont", spritefont(8))
        with self.assertRaisesRegex(REBUILD.BuildError, "resource input does not match"):
            self.build()
        self.assertFalse((self.root / "out" / "work" / "stage1" / "objects").exists())

    def test_rejects_linked_dll_missing_resources(self):
        linker = self.fixture.toolchain["lld_link"]
        linker.write_text(linker.read_text().replace("entries or None", "None"))
        with self.assertRaisesRegex(REBUILD.BuildError, "stage1 candidate resources: PE resource directory is empty"):
            self.build()


class PackageResourceGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-package-resources-")
        tree = ResourceTree(Path(self.temp.name))
        spec = tree.describe()
        res, _ = RES.compile_resources(tree.source, tree.assets, spec)
        self.entries = [(e.type, e.name, e.lang, e.data) for e in RES.parse_res(res)]
        self.pin = {"resources": [{**item} for item in RES.expected_dll_resources(spec)]}

    def tearDown(self):
        self.temp.cleanup()

    def test_accepts_declared_resources(self):
        PACKAGE.verify_payload_resources(FAKE_PE.build_dll(self.entries), self.pin, "payload")
        PACKAGE.verify_payload_resources(FAKE_PE.build_dll(None), {}, "payload")

    def test_rejects_resource_less_or_corrupt_payload(self):
        with self.assertRaisesRegex(PACKAGE.PackageError, "resource directory is empty"):
            PACKAGE.verify_payload_resources(FAKE_PE.build_dll(None), self.pin, "payload")
        corrupt = list(self.entries)
        corrupt[0] = (*corrupt[0][:3], corrupt[0][3][:-1] + b"\x7f")
        with self.assertRaisesRegex(PACKAGE.PackageError, "IDR_COURIERBOLD bytes"):
            PACKAGE.verify_payload_resources(FAKE_PE.build_dll(corrupt), self.pin, "payload")

    def test_rejects_malformed_resource_pins(self):
        for pin in ({"resources": []}, {"resources": [{"type": 256}]},
                    {"resources": [{**self.pin["resources"][0], "kind": "icon"}]}):
            with self.subTest(pin), self.assertRaises(PACKAGE.PackageError):
                PACKAGE.verify_payload_resources(FAKE_PE.build_dll(self.entries), pin, "payload")


class CheckedInResourcePinTests(unittest.TestCase):
    """The checked-in plan and both package pins name the authenticated resources."""

    AUTHENTIC = {
        "IDR_COURIERBOLD": (101, "courierbold.spritefont", 38920,
                            "f0131ed252c19ed07af5e725e9fba6586993762d3aee7c3cfd9aeb59aa13bc17",
                            "093158d295c706c2e52043da2de5b57fe4735dd3"),
        "IDR_COURIERSMALL": (102, "couriersmall.spritefont", 11272,
                             "e8da26db1ed85cdf40d0cb8ba4084ab1def7579b51dd01d8877d9e6090b3d1b6",
                             "1e7a3a98f9eb9e26171218172189256aa28f113f"),
        "IDR_ARIAL": (103, "arial.spritefont", 23048,
                      "f1282f6ec6008029ee95455678c871c739b1e573f409a8c20692d9b445098017",
                      "aa768be847249f58540be9228ab6551b540f0a6c"),
    }

    def setUp(self):
        self.plan = json.loads(PLAN_PATH.read_text(encoding="utf-8"))
        self.resources = self.plan["resources"]

    def test_plan_records_authenticated_fonts_and_version(self):
        RES.validate_spec(self.resources)
        self.assertEqual(self.resources["spriteFontType"], 256)
        for font in self.resources["fonts"]:
            self.assertEqual((font["id"], font["path"], font["size"], font["sha256"], font["gitBlobSHA1"]),
                             self.AUTHENTIC[font["macro"]])
            self.assertEqual(font["language"], 0x409)
            self.assertEqual(font["glyphCount"], 95)
        self.assertEqual(self.resources["version"]["language"], 0x807)
        self.assertEqual(self.resources["version"]["fileVersion"], [0, 0, 0, 0])
        self.assertEqual(self.resources["res"]["sha256"],
                         "5325eb502e18e4f0bb899af22c75d7c164fe0d99f467526f2e7ba13bf004b6ca")
        auth = self.resources["authentication"]
        self.assertEqual(auth["sourceArchiveSHA256"], self.plan["provenance"]["upstream"]["sourceArchiveSHA256"])
        self.assertEqual(auth["commit"], self.plan["sourcePin"]["commit"])

    def test_every_stage_links_its_resources_last_and_trees_stay_pinned(self):
        for name in ("stage1", "stage2", "stage3"):
            lines = self.plan[name]["link"]["rspLines"]
            self.assertEqual(lines[-1], RES.RES_LINK_LINE)
            self.assertEqual(lines.count(RES.RES_LINK_LINE), 1)
        self.assertEqual(self.plan["sourcePin"]["cleanTreeSHA256"],
                         "9981b207512f4190192ab5151472fcd76a398855659b14eb74ebfb00828b73aa")
        self.assertEqual(self.plan["stage3"]["patchedTreeSHA256"],
                         "40a10ae8123026dd1b34faea7c079a5a464d770a3abb541bb892edfc07e68a65")

    def test_package_pins_require_the_same_resources_as_the_plan(self):
        expected = RES.expected_dll_resources(self.resources)
        for pins_name in ("source-pins.json", "zzz-source-pins.json"):
            pins = json.loads((ROOT / "compat" / "xxmi" / pins_name).read_text(encoding="utf-8"))
            payload = pins["verifiedBinaries"]["payload"]
            with self.subTest(pins_name):
                self.assertEqual(payload["sha256"], self.plan["stage3"]["candidateSHA256"])
                self.assertEqual(payload["size"], self.plan["stage3"]["candidateSize"])
                self.assertEqual(payload["resources"], expected)
                self.assertEqual(pins["build"]["finalCandidateSHA256"], self.plan["stage3"]["candidateSHA256"])
                self.assertEqual(pins["build"]["baseCandidateSHA256"], self.plan["stage1"]["candidateSHA256"])

    def test_source_release_archives_the_resource_tool(self):
        release = (ROOT / "scripts" / "xxmi-source-release.py").read_text(encoding="utf-8")
        self.assertIn('"scripts/xxmi-payload-resources.py"', release)


SOURCE_RELEASE_TESTS = load("xxmi_source_release_tests",
                            Path(__file__).resolve().parent / "test_xxmi_source_release.py")


class SourceReleaseResourceTests(unittest.TestCase):
    """The GPL source bundle carries the fonts, their pins and the resource tool."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xxmi-source-release-resources-")
        self.root = Path(self.temp.name)
        fixture = SOURCE_RELEASE_TESTS.Fixture(self.root / "release")
        tree = ResourceTree(self.root / "resources")
        release = SOURCE_RELEASE_TESTS.xxmi_source_release
        for relative in ("DirectX11/DirectX11.rc", "version.h", "version.generated.h", "DirectX11/Overlay.cpp"):
            data = (tree.source / relative).read_bytes()
            for root in (fixture.source, fixture.root / "expected-stage1", fixture.root / "expected-stage2"):
                write(root / relative, data)
        for name, data in tree.fonts.items():
            write(fixture.generated_root / name, data)
        clean = release.REBUILD.tree_manifest(fixture.source)
        fixture.plan["sourcePin"].update(cleanTreeSHA256=clean["sha256"], cleanFileCount=clean["fileCount"])
        for name in ("stage1", "stage2"):
            fixture.plan[name]["patchedTreeSHA256"] = release.REBUILD.tree_manifest(
                fixture.root / f"expected-{name}")["sha256"]
        fixture.plan["resources"] = tree.describe()
        fixture.plan_path.write_text(json.dumps(fixture.plan, indent=2) + "\n", encoding="utf-8")
        self.fixture, self.tree = fixture, tree

    def tearDown(self):
        self.temp.cleanup()

    def test_archive_contains_fonts_pins_and_tool(self):
        output = self.root / "out"
        self.assertEqual(self.fixture.run(output), 0)
        with tarfile.open(self.fixture.archive(output)) as archive:
            names = {member.name.split("/", 1)[1]: member for member in archive.getmembers() if "/" in member.name}
            for font, data in self.tree.fonts.items():
                self.assertEqual(archive.extractfile(names[f"generated/{font}"]).read(), data)
                self.assertNotIn(f"upstream/{SOURCE_RELEASE_TESTS.SOURCE_NAME}/{font}", names)
                self.assertNotIn(f"patched/{SOURCE_RELEASE_TESTS.SOURCE_NAME}/{font}", names)
            self.assertIn("scripts/xxmi-payload-resources.py", names)
            metadata = json.loads(archive.extractfile(names["SOURCE-RELEASE.json"]).read())
            readme = archive.extractfile(names["README.md"]).read().decode()
        resources = metadata["resources"]
        self.assertEqual(resources["res"], self.fixture.plan["resources"]["res"])
        self.assertEqual([entry["id"] for entry in resources["inputs"]], [101, 102, 103])
        self.assertEqual({entry["path"] for entry in resources["inputs"]},
                         {f"generated/{font}" for font in self.tree.fonts})
        self.assertIn("SPRITEFONT", readme)
        self.assertIn(self.fixture.plan["resources"]["res"]["sha256"], readme)

    def test_rejects_altered_or_missing_font(self):
        font = self.fixture.generated_root / "arial.spritefont"
        font.write_bytes(spritefont(5))
        self.assertEqual(self.fixture.run(self.root / "out-a"), 1)
        font.unlink()
        self.assertEqual(self.fixture.run(self.root / "out-b"), 1)
        font.write_bytes(self.tree.fonts["arial.spritefont"])
        self.assertEqual(self.fixture.run(self.root / "out-c"), 0)


@unittest.skipUnless(os.environ.get("MACGACHA_XXMI_PAYLOAD"), "set MACGACHA_XXMI_PAYLOAD to a built d3d11.dll")
class BuiltPayloadResourceTests(unittest.TestCase):
    def test_built_payload_embeds_the_planned_resources(self):
        plan = json.loads(PLAN_PATH.read_text(encoding="utf-8"))
        data = Path(os.environ["MACGACHA_XXMI_PAYLOAD"]).read_bytes()
        result = RES.verify_dll_resources(data, RES.expected_dll_resources(plan["resources"]))
        self.assertEqual([e["spritefont"]["glyphCount"] for e in result["entries"] if "spritefont" in e], [95, 95, 95])
        resource_less = os.environ.get("MACGACHA_XXMI_RESOURCELESS_PAYLOAD")
        if resource_less:
            with self.assertRaisesRegex(RES.ResourceError, "resource directory is empty"):
                RES.verify_dll_resources(Path(resource_less).read_bytes(),
                                         RES.expected_dll_resources(plan["resources"]))


if __name__ == "__main__":
    unittest.main()
