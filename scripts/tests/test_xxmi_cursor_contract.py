#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline regression tests for the SRMI cursor coordinate contract.

The core tests are self-contained: they authenticate the checked-in minimal
source excerpts under ``fixtures/xxmi-cursor`` against fixed SHA-256 metadata,
apply ``0009-srmi-cursor-coordinate-contract.patch`` to those excerpts, and
compile the real ``CommandListState`` constructor, window/cursor helpers,
heuristic helpers and ``CURSOR_*`` operand cases against WinAPI stubs. The
excerpts contain only the verbatim regions the harness needs.

``XXMI_LIBS_SOURCE`` may point at the full pinned clean tree. When set, the
tree is authenticated against the build plan's clean-tree digest before use
and a wrong override fails closed. The full tree is optional and only enables
an extra parity test: patches 0001-0007 and 0009 must apply with ``--fuzz=0``
and the resulting relevant regions must match the minimal fixture. Without an
override, the recorded build-machine path is used only if it is present and
authentic; otherwise that optional parity test is skipped.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any

REPO = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "xxmi-cursor"
BUILD_PLAN = REPO / "compat" / "xxmi" / "build" / "payload-build-plan.json"
SOURCE_PINS = REPO / "compat" / "xxmi" / "source-pins.json"
PATCH_DIR = REPO / "compat" / "xxmi" / "patches"
CURSOR_PATCH = PATCH_DIR / "0009-srmi-cursor-coordinate-contract.patch"
REBUILD_SCRIPT = REPO / "scripts" / "xxmi-rebuild-payload.py"

DEFAULT_SOURCE = Path(
    "/private/tmp/xxmi-libs-v1.2.3-source/"
    "XXMI-Libs-Package-065dc746c21c71ef48bbc93cb6b90b3dcdf766e6"
)

CONFIG_KEYS = (
    "hwnd",
    "cursor_ok",
    "cursor_x",
    "cursor_y",
    "cursor_flags",
    "s2c_ok",
    "rect_ok",
    "client_w",
    "client_h",
    "origin_x",
    "origin_y",
    "res_w",
    "res_h",
    "rt_w",
    "rt_h",
    "fallback_w",
    "fallback_h",
)

NEW_STATE_FIELDS = (
    "cursor_info_queried",
    "cursor_info_valid",
    "cursor_window_coords_valid",
    "window_rect_queried",
    "window_rect_valid",
)

HARNESS_PREAMBLE = r"""
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <new>
#include <vector>

using std::abs;
using std::memcpy;
using std::memset;

typedef int BOOL;
typedef unsigned int DWORD;
typedef void *HWND;
typedef void *HCURSOR;
typedef void *HBITMAP;

#define TRUE 1
#define FALSE 0
#define CURSOR_SHOWING 0x00000001

struct POINT {
    int x;
    int y;
};

struct RECT {
    int left;
    int top;
    int right;
    int bottom;
};

struct CURSORINFO {
    DWORD cbSize;
    DWORD flags;
    POINT ptScreenPos;
    HCURSOR hCursor;
};

struct ICONINFO {
    BOOL fIcon;
    DWORD xHotspot;
    DWORD yHotspot;
    HBITMAP hbmMask;
    HBITMAP hbmColor;
};

struct HackerDevice;
struct HackerContext;
struct ID3D11Device1;
struct ID3D11DeviceContext1;
struct DrawCallInfo;
struct ResourceCopyTarget;
struct ID3D11Resource;
struct ID3D11View;
struct ID3D11Texture2D;
struct ID3D11ShaderResourceView;

struct D3D11_RECT {
    long left;
    long top;
    long right;
    long bottom;
};

#define D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE 1

struct InputLayoutElementOverride {
};

typedef long long LARGE_INTEGER;

struct FakeWin32 {
    int hwnd_present;
    int cursor_ok;
    int cursor_x;
    int cursor_y;
    int cursor_flags;
    int s2c_ok;
    int rect_ok;
    int client_w;
    int client_h;
    int origin_x;
    int origin_y;
    int res_w;
    int res_h;
    int rt_w;
    int rt_h;
    int fallback_w;
    int fallback_h;
    int get_cursor_info_calls;
    int screen_to_client_calls;
    int get_client_rect_calls;
    int process_rt_calls;
    int get_icon_info_calls;
};

static FakeWin32 fake;

struct FakeGlobal {
    HWND hWnd;
    struct {
        int width;
        int height;
    } mResolutionInfo;
    unsigned gFallbackScreenWidth;
    unsigned gFallbackScreenHeight;
};

static FakeGlobal fake_global;
static FakeGlobal *G = &fake_global;

static BOOL CursorUpscalingBypass_GetCursorInfo(CURSORINFO *pci)
{
    ++fake.get_cursor_info_calls;
    if (!fake.cursor_ok)
        return FALSE;
    pci->flags = (DWORD)fake.cursor_flags;
    pci->ptScreenPos.x = fake.cursor_x;
    pci->ptScreenPos.y = fake.cursor_y;
    return TRUE;
}

static BOOL CursorUpscalingBypass_ScreenToClient(HWND hWnd, POINT *pt)
{
    (void)hWnd;
    ++fake.screen_to_client_calls;
    if (!fake.s2c_ok)
        return FALSE;
    pt->x -= fake.origin_x;
    pt->y -= fake.origin_y;
    return TRUE;
}

static BOOL CursorUpscalingBypass_GetClientRect(HWND hWnd, RECT *rect)
{
    (void)hWnd;
    ++fake.get_client_rect_calls;
    if (!fake.rect_ok)
        return FALSE;
    rect->left = 0;
    rect->top = 0;
    rect->right = fake.client_w;
    rect->bottom = fake.client_h;
    return TRUE;
}

static BOOL GetIconInfo(HCURSOR hCursor, ICONINFO *info)
{
    (void)hCursor;
    ++fake.get_icon_info_calls;
    info->xHotspot = 5;
    info->yHotspot = 7;
    info->hbmMask = reinterpret_cast<HBITMAP>(static_cast<std::uintptr_t>(1));
    return TRUE;
}

static void LogDebug(const char *fmt, ...)
{
    (void)fmt;
}
"""

HARNESS_POST_CLASS = r"""
static void ProcessParamRTSize(CommandListState *state)
{
    ++fake.process_rt_calls;
    state->rt_width = (float)fake.rt_w;
    state->rt_height = (float)fake.rt_h;
}
"""

HARNESS_MAIN = r"""
static float EvaluateCursor(CommandListState *state, ParamOverrideType type)
{
    float ftemp = 0.0f;
    float fret = 0.0f;
    (void)ftemp;
    (void)fret;

    switch (type) {
@CASES@
    default:
        break;
    }
    return -12345.0f;
}

static CommandListState *ConstructState(unsigned char *storage)
{
    memset(storage, 0x01, sizeof(CommandListState));
    return new (storage) CommandListState();
}

static FakeWin32 MakeFake(const int *values)
{
    FakeWin32 result = FakeWin32{};
    result.hwnd_present = values[0];
    result.cursor_ok = values[1];
    result.cursor_x = values[2];
    result.cursor_y = values[3];
    result.cursor_flags = values[4];
    result.s2c_ok = values[5];
    result.rect_ok = values[6];
    result.client_w = values[7];
    result.client_h = values[8];
    result.origin_x = values[9];
    result.origin_y = values[10];
    result.res_w = values[11];
    result.res_h = values[12];
    result.rt_w = values[13];
    result.rt_h = values[14];
    result.fallback_w = values[15];
    result.fallback_h = values[16];
    return result;
}

static void SetGlobal(const int *values)
{
    fake_global = FakeGlobal{};
    fake_global.hWnd = values[0] ? reinterpret_cast<HWND>(
        static_cast<std::uintptr_t>(values[0])) : nullptr;
    fake_global.mResolutionInfo.width = values[11];
    fake_global.mResolutionInfo.height = values[12];
    fake_global.gFallbackScreenWidth = (unsigned)values[15];
    fake_global.gFallbackScreenHeight = (unsigned)values[16];
}

static void PrintValues(const char *prefix, CommandListState *state)
{
    printf("%sCURSOR_VISIBLE=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_VISIBLE));
    printf("%sCURSOR_SCREEN_X=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_SCREEN_X));
    printf("%sCURSOR_SCREEN_Y=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_SCREEN_Y));
    printf("%sCURSOR_WINDOW_X=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_WINDOW_X));
    printf("%sCURSOR_WINDOW_Y=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_WINDOW_Y));
    printf("%sCURSOR_X=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_X));
    printf("%sCURSOR_Y=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_Y));
    printf("%sCURSOR_HOTSPOT_X=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_HOTSPOT_X));
    printf("%sCURSOR_HOTSPOT_Y=%.9g\n",
           prefix, (double)EvaluateCursor(state, ParamOverrideType::CURSOR_HOTSPOT_Y));
    printf("%sWINDOW_WIDTH=%.9g\n", prefix, (double)HeuristicGetWindowWidth(state));
    printf("%sWINDOW_HEIGHT=%.9g\n", prefix, (double)HeuristicGetWindowHeight(state));

    printf("%sGetCursorInfoCalls=%d\n", prefix, fake.get_cursor_info_calls);
    printf("%sScreenToClientCalls=%d\n", prefix, fake.screen_to_client_calls);
    printf("%sGetClientRectCalls=%d\n", prefix, fake.get_client_rect_calls);
    printf("%sProcessParamRTSizeCalls=%d\n", prefix, fake.process_rt_calls);
    printf("%sGetIconInfoCalls=%d\n", prefix, fake.get_icon_info_calls);
}

int main()
{
    int values[34];
    int count = 0;

    while (count < 34 && scanf("%d", &values[count]) == 1)
        ++count;
    if (count != 17 && count != 34)
        return 2;

    alignas(CommandListState) unsigned char ctor_storage[sizeof(CommandListState)];
    CommandListState *ctor = ConstructState(ctor_storage);
#ifdef NEW_CONTRACT
    printf("CTOR_cursor_info_queried=%d\n", (int)ctor->cursor_info_queried);
    printf("CTOR_cursor_info_valid=%d\n", (int)ctor->cursor_info_valid);
    printf("CTOR_cursor_window_coords_valid=%d\n",
           (int)ctor->cursor_window_coords_valid);
    printf("CTOR_window_rect_queried=%d\n", (int)ctor->window_rect_queried);
    printf("CTOR_window_rect_valid=%d\n", (int)ctor->window_rect_valid);
#endif
    printf("CTOR_mHackerDevice_null=%d\n", ctor->mHackerDevice == nullptr);
    printf("CTOR_mHackerContext_null=%d\n", ctor->mHackerContext == nullptr);
    printf("CTOR_mOrigDevice1_null=%d\n", ctor->mOrigDevice1 == nullptr);
    printf("CTOR_mOrigContext1_null=%d\n", ctor->mOrigContext1 == nullptr);
    printf("CTOR_rt_width=%.9g\n", (double)ctor->rt_width);
    printf("CTOR_rt_height=%.9g\n", (double)ctor->rt_height);
    printf("CTOR_post=%d\n", (int)ctor->post);
    printf("CTOR_aborted=%d\n", (int)ctor->aborted);
    printf("CTOR_scissor_valid=%d\n", (int)ctor->scissor_valid);
    printf("CTOR_update_params=%d\n", (int)ctor->update_params);
    printf("CTOR_recursion=%d\n", ctor->recursion);
    printf("CTOR_extra_indent=%d\n", ctor->extra_indent);
    printf("CTOR_cursor_info_cbSize=%u\n", (unsigned)ctor->cursor_info.cbSize);
    printf("CTOR_cursor_info_ex_hbmMask=%d\n", ctor->cursor_info_ex.hbmMask != nullptr);
    printf("CTOR_window_rect_right=%d\n", (int)ctor->window_rect.right);
    ctor->~CommandListState();

    alignas(CommandListState) unsigned char storage1[sizeof(CommandListState)];
    fake = MakeFake(values);
    SetGlobal(values);
    CommandListState *state1 = ConstructState(storage1);
    PrintValues("", state1);
    state1->~CommandListState();

    if (count == 34) {
        alignas(CommandListState) unsigned char storage2[sizeof(CommandListState)];
        fake = MakeFake(values + 17);
        SetGlobal(values + 17);
        CommandListState *state2 = ConstructState(storage2);
        PrintValues("S2_", state2);
        state2->~CommandListState();
    }
    return 0;
}
"""

CASE_START = "case ParamOverrideType::CURSOR_VISIBLE:"
CASE_END = "case ParamOverrideType::SCISSOR_LEFT:"


def load_rebuild_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("xxmi_rebuild_payload", REBUILD_SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {REBUILD_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


REBUILD = load_rebuild_module()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AssertionError(f"cannot read JSON metadata {path}: {exc}") from exc


def load_build_plan() -> dict[str, Any]:
    plan = load_json(BUILD_PLAN)
    if plan.get("schemaVersion") != 1:
        raise AssertionError("payload build plan schemaVersion must be 1")
    for key in ("sourcePin", "basePatches", "stage1", "stage2"):
        if key not in plan:
            raise AssertionError(f"payload build plan is missing {key}")
    return plan


def plan_patch_paths(plan: dict[str, Any]) -> list[Path]:
    paths = [REBUILD.resolve_plan_path(entry["path"]) for entry in plan["basePatches"]]
    paths.append(REBUILD.resolve_plan_path(plan["stage2"]["patch"]["path"]))
    return paths


def verify_fixture(root: Path = FIXTURE, plan: dict[str, Any] | None = None) -> dict[str, Any]:
    """Authenticate the checked-in excerpts and their source-pin metadata."""

    plan = plan or load_build_plan()
    source_pin = plan["sourcePin"]
    pins = load_json(SOURCE_PINS)["sourcePins"]["xxmiLibsPackage"]
    metadata = load_json(root / "PROVENANCE.json")
    if metadata.get("schemaVersion") != 1:
        raise AssertionError("fixture PROVENANCE schemaVersion must be 1")

    source = metadata.get("source", {})
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
        if source.get(key) != value:
            raise AssertionError(
                f"fixture source metadata {key} mismatch: "
                f"got {source.get(key)!r}, expected {value!r}"
            )

    excerpts = metadata.get("excerpts")
    if not isinstance(excerpts, list) or not excerpts:
        raise AssertionError("fixture PROVENANCE has no excerpts")

    for excerpt in excerpts:
        path = root / excerpt["path"]
        if not path.is_file():
            raise AssertionError(f"fixture excerpt is missing: {path}")
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines(keepends=True)
        if len(lines) != excerpt["fixtureLineCount"]:
            raise AssertionError(
                f"fixture line count mismatch for {excerpt['path']}: "
                f"got {len(lines)}, expected {excerpt['fixtureLineCount']}"
            )
        actual_hash = sha256_text(text)
        if actual_hash != excerpt["fixtureSHA256"]:
            raise AssertionError(
                f"fixture SHA-256 mismatch for {excerpt['path']}: "
                f"got {actual_hash}, expected {excerpt['fixtureSHA256']}"
            )

        banner_count = excerpt["bannerLineCount"]
        banner = "".join(lines[:banner_count])
        for required in (
            "SPDX-License-Identifier: GPL-3.0-only",
            "MacGacha — https://github.com/deruta74/MacGacha",
            source_pin["commit"],
            pins["license"],
            "XXMI-Libs-Package",
        ):
            if required not in banner:
                raise AssertionError(
                    f"fixture banner for {excerpt['path']} is missing {required!r}"
                )

        index = banner_count
        segments = excerpt["segments"]
        separator = excerpt["segmentSeparator"]
        separator_lines = separator.splitlines(keepends=True)
        if len(separator_lines) != excerpt["segmentSeparatorLineCount"]:
            raise AssertionError("fixture segment separator metadata is inconsistent")
        for position, segment in enumerate(segments):
            if segment["sourceEnd"] - segment["sourceStart"] + 1 != segment["lineCount"]:
                raise AssertionError("fixture source line range is inconsistent")
            chunk = "".join(lines[index : index + segment["lineCount"]])
            if sha256_text(chunk) != segment["sha256"]:
                raise AssertionError(
                    f"source excerpt SHA-256 mismatch for {excerpt['path']} "
                    f"lines {segment['sourceStart']}-{segment['sourceEnd']}"
                )
            index += segment["lineCount"]
            if position + 1 < len(segments):
                found = "".join(lines[index : index + len(separator_lines)])
                if found != separator:
                    raise AssertionError(
                        f"fixture segment separator mismatch in {excerpt['path']}"
                    )
                index += len(separator_lines)
        if index != len(lines):
            raise AssertionError(
                f"fixture {excerpt['path']} has unauthenticated trailing lines"
            )
    return metadata


def require_source_pin_match(path: Path, source_pin: dict[str, Any]) -> dict[str, Any]:
    """Authenticate a full clean tree against the build plan, without exclusions."""

    if not path.is_dir():
        raise AssertionError(f"XXMI source override is not a directory: {path}")
    manifest = REBUILD.tree_manifest(path)
    if manifest["fileCount"] != source_pin["cleanFileCount"]:
        raise AssertionError(
            "source override file count mismatch: "
            f"got {manifest['fileCount']}, expected {source_pin['cleanFileCount']}"
        )
    if manifest["sha256"] != source_pin["cleanTreeSHA256"]:
        raise AssertionError(
            "source override is not the pinned clean tree: "
            f"got {manifest['sha256']}, expected {source_pin['cleanTreeSHA256']}"
        )
    return manifest


def resolve_optional_full_source(
    override: str | None,
    default_path: Path,
    source_pin: dict[str, Any],
) -> Path | None:
    """Return an authenticated full source tree, or None when none is present.

    A non-empty override is authoritative: it must exist and match the source
    pin. An absent recorded path is optional. A present recorded path is also
    authenticated so a stale build-machine tree cannot silently poison tests.
    """

    if override:
        path = Path(override)
        require_source_pin_match(path, source_pin)
        return path
    if default_path.is_dir():
        require_source_pin_match(default_path, source_pin)
        return default_path
    return None


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
    rejects = sorted(tree.rglob("*.rej"))
    if rejects:
        raise AssertionError(f"{patch.name} left rejects: {rejects}")
    return output


def find_closing_brace(text: str, open_index: int) -> int:
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    raise AssertionError("unbalanced braces in extracted source")


def extract_block(text: str, marker: str) -> str:
    pattern = re.compile(rf"^{re.escape(marker)}\s*$", re.MULTILINE)
    match = pattern.search(text)
    if match is None:
        raise AssertionError(f"source block not found: {marker}")
    open_index = text.index("{", match.start())
    close_index = find_closing_brace(text, open_index)
    end = text.index(";", close_index) + 1
    return text[match.start() : end]


def extract_function(text: str, name: str, required: bool = True) -> str | None:
    pattern = re.compile(
        rf"^static\s+(?:void|bool|float)\s+{name}\s*\([^)]*\)\s*$", re.MULTILINE
    )
    match = pattern.search(text)
    if match is None:
        if required:
            raise AssertionError(f"production function {name} not found")
        return None

    open_index = text.index("{", match.end())
    return text[match.start() : find_closing_brace(text, open_index) + 1]


def extract_constructor(text: str) -> str:
    pattern = re.compile(r"^CommandListState::CommandListState\(\)\s*:\s*$", re.MULTILINE)
    match = pattern.search(text)
    if match is None:
        raise AssertionError("production CommandListState constructor not found")
    open_index = text.index("{", match.end())
    return text[match.start() : find_closing_brace(text, open_index) + 1]


def extract_cursor_cases(text: str) -> str:
    if text.count(CASE_START) != 1 or text.count(CASE_END) != 1:
        raise AssertionError("cursor operand cases not found exactly once")
    start = text.index(CASE_START)
    start = text.rindex("\n", 0, start) + 1
    end = text.index(CASE_END)
    end = text.rindex("\n", 0, end) + 1
    return text[start:end]


def build_harness(
    header_text: str,
    source_text: str,
    *,
    include_client_extent: bool,
) -> str:
    parts = [
        HARNESS_PREAMBLE,
        extract_block(header_text, "class CommandListState {"),
        extract_block(header_text, "enum class ParamOverrideType {"),
        "CommandListState::~CommandListState() {}",
        extract_constructor(source_text),
        HARNESS_POST_CLASS,
        extract_function(source_text, "UpdateWindowInfo"),
    ]
    if include_client_extent:
        parts.append(extract_function(source_text, "GetClientExtent"))
    parts.extend(
        [
            extract_function(source_text, "UpdateCursorInfo"),
            extract_function(source_text, "UpdateCursorInfoEx"),
            extract_function(source_text, "HeuristicGetWindowWidth"),
            extract_function(source_text, "HeuristicGetWindowHeight"),
            HARNESS_MAIN.replace("@CASES@", extract_cursor_cases(source_text)),
        ]
    )
    return "\n\n".join(parts) + "\n"


def scenario(**overrides: int) -> dict[str, int]:
    base = {
        "hwnd": 1,
        "cursor_ok": 1,
        "cursor_x": 0,
        "cursor_y": 0,
        "cursor_flags": 1,
        "s2c_ok": 1,
        "rect_ok": 1,
        "client_w": 1280,
        "client_h": 720,
        "origin_x": 0,
        "origin_y": 0,
        "res_w": 1920,
        "res_h": 1080,
        "rt_w": 1600,
        "rt_h": 900,
        "fallback_w": 1024,
        "fallback_h": 768,
    }
    base.update(overrides)
    return base


# Each case carries the documented old (pre-patch) and new (patched) outputs.
# A case is marked bug=True when the old output violates the coordinate
# contract; those are the reproduced failures.
SCENARIOS = {
    "offset_window_zero_edge": {
        "config": scenario(cursor_x=100, cursor_y=350, origin_x=100, origin_y=50),
        "bug": True,
        # client (0, 300): old CURSOR_X substitutes desktop 100/1280.
        "old": {"CURSOR_X": 100 / 1280, "CURSOR_Y": 300 / 720},
        "new": {"CURSOR_X": 0.0, "CURSOR_Y": 300 / 720},
        "shared": {
            "CURSOR_VISIBLE": 1.0,
            "CURSOR_SCREEN_X": 100.0,
            "CURSOR_SCREEN_Y": 350.0,
            "CURSOR_WINDOW_X": 0.0,
            "CURSOR_WINDOW_Y": 300.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1280.0,
            "WINDOW_HEIGHT": 720.0,
        },
    },
    "small_client_scaled_target": {
        "config": scenario(cursor_x=250, cursor_y=200, client_w=500, client_h=400),
        "bug": True,
        # client (250, 200) divided by RES 1920x1080 instead of 500x400.
        "old": {"CURSOR_X": 250 / 1920, "CURSOR_Y": 200 / 1080},
        "new": {"CURSOR_X": 0.5, "CURSOR_Y": 0.5},
        "shared": {
            "CURSOR_WINDOW_X": 250.0,
            "CURSOR_WINDOW_Y": 200.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1920.0,
            "WINDOW_HEIGHT": 1080.0,
        },
    },
    "small_client_rt_scaled": {
        "config": scenario(
            cursor_x=250,
            cursor_y=200,
            client_w=500,
            client_h=400,
            res_w=320,
            res_h=200,
            rt_w=1600,
            rt_h=900,
        ),
        "bug": True,
        # Small client and small RES: the old heuristic reaches RT_WIDTH/HEIGHT.
        "old": {"CURSOR_X": 250 / 1600, "CURSOR_Y": 200 / 900},
        "new": {"CURSOR_X": 0.5, "CURSOR_Y": 0.5},
        "shared": {
            "CURSOR_WINDOW_X": 250.0,
            "CURSOR_WINDOW_Y": 200.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1600.0,
            "WINDOW_HEIGHT": 900.0,
        },
    },
    "negative_outside_small_client": {
        "config": scenario(cursor_x=-10, cursor_y=410, client_w=500, client_h=400),
        "bug": True,
        # Client pixels preserved, but old normalizes with RES/fallback sizes.
        "old": {"CURSOR_X": -10 / 1920, "CURSOR_Y": 410 / 1080},
        "new": {"CURSOR_X": -10 / 500, "CURSOR_Y": 410 / 400},
        "shared": {
            "CURSOR_WINDOW_X": -10.0,
            "CURSOR_WINDOW_Y": 410.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1920.0,
            "WINDOW_HEIGHT": 1080.0,
        },
    },
    "mixed_axis_heuristic": {
        "config": scenario(cursor_x=640, cursor_y=200, client_w=1280, client_h=400),
        "bug": True,
        # Width uses the real client; height (< 480) falls back to RES height.
        "old": {"CURSOR_X": 640 / 1280, "CURSOR_Y": 200 / 1080},
        "new": {"CURSOR_X": 0.5, "CURSOR_Y": 0.5},
        "shared": {
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1280.0,
            "WINDOW_HEIGHT": 1080.0,
        },
    },
    "right_bottom_edge": {
        "config": scenario(cursor_x=1279, cursor_y=719),
        "bug": False,
        # Healthy window: values stay identical for backwards compatibility.
        "old": {"CURSOR_X": 1279 / 1280, "CURSOR_Y": 719 / 720},
        "new": {"CURSOR_X": 1279 / 1280, "CURSOR_Y": 719 / 720},
        "shared": {
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1280.0,
            "WINDOW_HEIGHT": 720.0,
        },
    },
    "negative_desktop_origin_small_client": {
        "config": scenario(
            cursor_x=-1720,
            cursor_y=30,
            origin_x=-1920,
            origin_y=-120,
            client_w=400,
            client_h=300,
            res_w=2560,
            res_h=1440,
        ),
        "bug": True,
        # Window on a negative-origin desktop: client (200, 150).
        "old": {"CURSOR_X": 200 / 2560, "CURSOR_Y": 150 / 1440},
        "new": {"CURSOR_X": 0.5, "CURSOR_Y": 0.5},
        "shared": {
            "CURSOR_WINDOW_X": 200.0,
            "CURSOR_WINDOW_Y": 150.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 2560.0,
            "WINDOW_HEIGHT": 1440.0,
        },
    },
    "get_cursor_info_failure": {
        "config": scenario(cursor_ok=0, origin_x=100, origin_y=50),
        "bug": True,
        # The failed query is cached as (0, 0) and translated anyway.
        "old": {
            "CURSOR_VISIBLE": 0.0,
            "CURSOR_SCREEN_X": 0.0,
            "CURSOR_SCREEN_Y": 0.0,
            "CURSOR_WINDOW_X": -100.0,
            "CURSOR_WINDOW_Y": -50.0,
            "CURSOR_X": -100 / 1280,
            "CURSOR_Y": -50 / 720,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
        },
        "new": {
            "CURSOR_VISIBLE": 0.0,
            "CURSOR_SCREEN_X": 0.0,
            "CURSOR_SCREEN_Y": 0.0,
            "CURSOR_WINDOW_X": 0.0,
            "CURSOR_WINDOW_Y": 0.0,
            "CURSOR_X": 0.0,
            "CURSOR_Y": 0.0,
            "CURSOR_HOTSPOT_X": 0.0,
            "CURSOR_HOTSPOT_Y": 0.0,
        },
        "shared": {"WINDOW_WIDTH": 1280.0, "WINDOW_HEIGHT": 720.0},
    },
    "get_client_rect_failure": {
        "config": scenario(cursor_x=640, cursor_y=360, rect_ok=0),
        "bug": True,
        # Client pixels normalized by RES because the failed rect is zero.
        "old": {"CURSOR_X": 640 / 1920, "CURSOR_Y": 360 / 1080},
        "new": {"CURSOR_X": 0.0, "CURSOR_Y": 0.0},
        "shared": {
            "CURSOR_WINDOW_X": 640.0,
            "CURSOR_WINDOW_Y": 360.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1920.0,
            "WINDOW_HEIGHT": 1080.0,
        },
    },
    "rect_failure_rt_fallback": {
        "config": scenario(cursor_x=640, cursor_y=360, rect_ok=0, res_w=0, res_h=0),
        "bug": True,
        # With no rect and no RES size, the heuristic falls back to RT.
        "old": {"CURSOR_X": 640 / 1600, "CURSOR_Y": 360 / 900},
        "new": {"CURSOR_X": 0.0, "CURSOR_Y": 0.0},
        "shared": {
            "CURSOR_WINDOW_X": 640.0,
            "CURSOR_WINDOW_Y": 360.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1600.0,
            "WINDOW_HEIGHT": 900.0,
        },
    },
    "screen_to_client_failure": {
        "config": scenario(
            cursor_x=800, cursor_y=450, origin_x=100, origin_y=50, s2c_ok=0
        ),
        "bug": True,
        # Untranslated screen pixels are reported as client pixels.
        "old": {
            "CURSOR_WINDOW_X": 800.0,
            "CURSOR_WINDOW_Y": 450.0,
            "CURSOR_X": 800 / 1280,
            "CURSOR_Y": 450 / 720,
        },
        "new": {
            "CURSOR_WINDOW_X": 0.0,
            "CURSOR_WINDOW_Y": 0.0,
            "CURSOR_X": 0.0,
            "CURSOR_Y": 0.0,
        },
        "shared": {
            "CURSOR_SCREEN_X": 800.0,
            "CURSOR_SCREEN_Y": 450.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1280.0,
            "WINDOW_HEIGHT": 720.0,
        },
    },
    "zero_sized_minimized": {
        "config": scenario(
            cursor_x=300, cursor_y=200, client_w=0, client_h=0
        ),
        "bug": True,
        # A minimized client falls back to RES sizes for normalization.
        "old": {"CURSOR_X": 300 / 1920, "CURSOR_Y": 200 / 1080},
        "new": {"CURSOR_X": 0.0, "CURSOR_Y": 0.0},
        "shared": {
            "CURSOR_WINDOW_X": 300.0,
            "CURSOR_WINDOW_Y": 200.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1920.0,
            "WINDOW_HEIGHT": 1080.0,
        },
    },
    "no_hwnd": {
        "config": scenario(hwnd=0, cursor_x=500, cursor_y=400),
        "bug": True,
        # Without a window, screen pixels are reported as client pixels.
        "old": {
            "CURSOR_WINDOW_X": 500.0,
            "CURSOR_WINDOW_Y": 400.0,
            "CURSOR_X": 500 / 1920,
            "CURSOR_Y": 400 / 1080,
        },
        "new": {
            "CURSOR_WINDOW_X": 0.0,
            "CURSOR_WINDOW_Y": 0.0,
            "CURSOR_X": 0.0,
            "CURSOR_Y": 0.0,
        },
        "shared": {
            "CURSOR_SCREEN_X": 500.0,
            "CURSOR_SCREEN_Y": 400.0,
            "CURSOR_HOTSPOT_X": 5.0,
            "CURSOR_HOTSPOT_Y": 7.0,
            "WINDOW_WIDTH": 1920.0,
            "WINDOW_HEIGHT": 1080.0,
        },
    },
}


class CursorContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = load_build_plan()
        cls.pin = cls.plan["sourcePin"]
        cls.provenance = verify_fixture(FIXTURE, cls.plan)

        cls.cxx = shutil.which("clang++") or shutil.which("c++")
        if cls.cxx is None:
            raise unittest.SkipTest("a C++ compiler is required for the cursor harness")
        if shutil.which("patch") is None:
            raise unittest.SkipTest("patch(1) is required for the cursor harness")
        if not CURSOR_PATCH.is_file():
            raise AssertionError(f"missing patch {CURSOR_PATCH}")

        cls._temp = tempfile.TemporaryDirectory(prefix="macgacha-cursor-")
        cls.temp = Path(cls._temp.name)
        cls.old_tree = cls.temp / "fixture-old"
        cls.new_tree = cls.temp / "fixture-new"

        shutil.copytree(FIXTURE, cls.old_tree)
        shutil.copytree(FIXTURE, cls.new_tree)
        cls.fixture_patch_output = apply_fixture_patch(cls.new_tree, CURSOR_PATCH)

        cls.old_source = (cls.old_tree / "DirectX11" / "CommandList.cpp").read_text(
            encoding="utf-8"
        )
        cls.new_source = (cls.new_tree / "DirectX11" / "CommandList.cpp").read_text(
            encoding="utf-8"
        )
        cls.old_header = (cls.old_tree / "DirectX11" / "CommandList.h").read_text(
            encoding="utf-8"
        )
        cls.new_header = (cls.new_tree / "DirectX11" / "CommandList.h").read_text(
            encoding="utf-8"
        )

        cls.old_harness = cls._compile(
            "old", cls.old_header, cls.old_source, include_client_extent=False
        )
        cls.new_harness = cls._compile(
            "new", cls.new_header, cls.new_source, include_client_extent=True
        )

        cls.full_source = resolve_optional_full_source(
            os.environ.get("XXMI_LIBS_SOURCE"), DEFAULT_SOURCE, cls.pin
        )
        cls.full_new_source: str | None = None
        cls.full_new_header: str | None = None
        if cls.full_source is not None:
            full_tree = cls.temp / "full"
            shutil.copytree(cls.full_source, full_tree)
            logs = cls.temp / "full-logs"
            logs.mkdir()
            for patch_path in plan_patch_paths(cls.plan):
                REBUILD.apply_patch(full_tree, patch_path, logs)
            REBUILD.apply_patch(full_tree, CURSOR_PATCH, logs)
            cls.full_new_source = (full_tree / "DirectX11" / "CommandList.cpp").read_text(
                encoding="utf-8"
            )
            cls.full_new_header = (full_tree / "DirectX11" / "CommandList.h").read_text(
                encoding="utf-8"
            )

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "_temp"):
            cls._temp.cleanup()

    @classmethod
    def _compile(
        cls,
        name: str,
        header_text: str,
        source_text: str,
        *,
        include_client_extent: bool,
    ) -> Path:
        cpp = cls.temp / f"cursor_harness_{name}.cpp"
        exe = cls.temp / f"cursor_harness_{name}"
        cpp.write_text(
            build_harness(
                header_text, source_text, include_client_extent=include_client_extent
            ),
            encoding="utf-8",
        )
        command = [
            cls.cxx,
            "-std=c++17",
            "-O0",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wno-unused-parameter",
            "-Wno-reorder",
        ]
        if include_client_extent:
            command.append("-DNEW_CONTRACT")
        command.extend(["-o", str(exe), str(cpp)])
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode != 0:
            raise AssertionError(
                f"harness compilation failed for {name}:\n"
                f"{result.stdout}{result.stderr}"
            )
        return exe

    @staticmethod
    def _run(
        harness: Path,
        config: dict[str, int],
        *,
        next_config: dict[str, int] | None = None,
    ) -> dict[str, float]:
        line = " ".join(str(config[key]) for key in CONFIG_KEYS)
        if next_config is not None:
            line += " " + " ".join(str(next_config[key]) for key in CONFIG_KEYS)
        result = subprocess.run(
            [str(harness)],
            input=line,
            text=True,
            capture_output=True,
            check=True,
        )
        values: dict[str, float] = {}
        for output in result.stdout.splitlines():
            key, raw = output.split("=", 1)
            values[key] = int(raw) if key.endswith("Calls") else float(raw)
        return values

    def test_fixture_metadata_is_authenticated(self) -> None:
        self.assertEqual(self.provenance["source"]["commit"], self.pin["commit"])
        self.assertTrue(self.provenance["excerpts"])
        for excerpt in self.provenance["excerpts"]:
            self.assertTrue((FIXTURE / excerpt["path"]).is_file())

    def test_tampered_fixture_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macgacha-cursor-tamper-") as raw:
            copy = Path(raw)
            shutil.copytree(FIXTURE, copy / "fixture")
            target = copy / "fixture" / "DirectX11" / "CommandList.cpp"
            text = target.read_text(encoding="utf-8")
            tampered = text.replace(
                "static void UpdateWindowInfo", "static void TamperedUpdateWindowInfo", 1
            )
            self.assertNotEqual(tampered, text)
            target.write_text(tampered, encoding="utf-8")
            with self.assertRaises(AssertionError):
                verify_fixture(copy / "fixture", self.plan)

    def test_patch_applies_to_minimal_fixture_with_zero_fuzz(self) -> None:
        self.assertNotIn("fuzz", self.fixture_patch_output.lower())
        for name in ("UpdateWindowInfo", "GetClientExtent", "UpdateCursorInfo"):
            self.assertIsNotNone(
                extract_function(self.new_source, name),
                f"{name} missing after applying 0009",
            )
        self.assertIsNone(
            extract_function(self.old_source, "GetClientExtent", required=False)
        )
        self.assertNotIn("cursor_info_valid", self.old_source)
        for field in NEW_STATE_FIELDS:
            self.assertIn(f"bool {field};", self.new_header)
            self.assertIn(f"{field}(false)", self.new_source)
        self.assertNotIn("cursor_info_queried", self.old_header)

    def test_constructor_initializes_new_fields_from_production(self) -> None:
        values = self._run(self.new_harness, scenario())
        for field in NEW_STATE_FIELDS:
            self.assertEqual(
                values[f"CTOR_{field}"],
                0,
                f"production constructor did not initialize {field} to false",
            )
        self.assertEqual(values["CTOR_mHackerDevice_null"], 1)
        self.assertEqual(values["CTOR_mHackerContext_null"], 1)
        self.assertEqual(values["CTOR_mOrigDevice1_null"], 1)
        self.assertEqual(values["CTOR_mOrigContext1_null"], 1)
        self.assertAlmostEqual(values["CTOR_rt_width"], -1.0, places=6)
        self.assertAlmostEqual(values["CTOR_rt_height"], -1.0, places=6)
        self.assertEqual(values["CTOR_post"], 0)
        self.assertEqual(values["CTOR_aborted"], 0)
        self.assertEqual(values["CTOR_scissor_valid"], 0)
        self.assertEqual(values["CTOR_update_params"], 0)
        self.assertEqual(values["CTOR_recursion"], 0)
        self.assertEqual(values["CTOR_extra_indent"], 0)
        self.assertEqual(values["CTOR_cursor_info_cbSize"], 0)
        self.assertEqual(values["CTOR_cursor_info_ex_hbmMask"], 0)
        self.assertEqual(values["CTOR_window_rect_right"], 0)

    def test_old_failure_reproduced_then_new_contract_passes(self) -> None:
        reproduced = 0
        for name, case in SCENARIOS.items():
            with self.subTest(scenario=name, variant="old"):
                old = self._run(self.old_harness, case["config"])
                for operand, expected in {**case["shared"], **case["old"]}.items():
                    self.assertAlmostEqual(
                        old[operand], expected, places=6, msg=f"old {operand}"
                    )
                if case["bug"]:
                    reproduced += 1
                    different = [
                        operand
                        for operand, expected in case["new"].items()
                        if abs(old[operand] - expected) > 1e-6
                    ]
                    self.assertTrue(different, f"old output unexpectedly matches new: {name}")

            with self.subTest(scenario=name, variant="new"):
                new = self._run(self.new_harness, case["config"])
                for operand, expected in {**case["shared"], **case["new"]}.items():
                    self.assertAlmostEqual(
                        new[operand], expected, places=6, msg=f"new {operand}"
                    )
        self.assertGreater(reproduced, 0)

    def test_heuristic_text_unchanged_but_cache_semantics_changed(self) -> None:
        for name in ("HeuristicGetWindowWidth", "HeuristicGetWindowHeight"):
            self.assertEqual(
                extract_function(self.old_source, name),
                extract_function(self.new_source, name),
                f"{name} text must stay backwards compatible",
            )

        minimized = SCENARIOS["zero_sized_minimized"]["config"]
        old_minimized = self._run(self.old_harness, minimized)
        new_minimized = self._run(self.new_harness, minimized)
        self.assertEqual(old_minimized["GetClientRectCalls"], 4)
        self.assertEqual(new_minimized["GetClientRectCalls"], 1)
        for operand in ("WINDOW_WIDTH", "WINDOW_HEIGHT"):
            self.assertAlmostEqual(
                old_minimized[operand], new_minimized[operand], places=6
            )

        rect_failure = SCENARIOS["rect_failure_rt_fallback"]["config"]
        old_failure = self._run(self.old_harness, rect_failure)
        new_failure = self._run(self.new_harness, rect_failure)
        self.assertEqual(old_failure["GetClientRectCalls"], 4)
        self.assertEqual(new_failure["GetClientRectCalls"], 1)
        for operand in ("WINDOW_WIDTH", "WINDOW_HEIGHT"):
            self.assertAlmostEqual(
                old_failure[operand], new_failure[operand], places=6
            )

    def test_per_command_list_query_caching(self) -> None:
        success = self._run(self.new_harness, SCENARIOS["offset_window_zero_edge"]["config"])
        self.assertEqual(success["GetCursorInfoCalls"], 1)
        self.assertEqual(success["ScreenToClientCalls"], 1)
        self.assertEqual(success["GetClientRectCalls"], 1)
        self.assertEqual(success["ProcessParamRTSizeCalls"], 0)

        # A successful zero-sized query is cached, not retried per operand.
        minimized = self._run(self.new_harness, SCENARIOS["zero_sized_minimized"]["config"])
        self.assertEqual(minimized["GetClientRectCalls"], 1)
        old_minimized = self._run(
            self.old_harness, SCENARIOS["zero_sized_minimized"]["config"]
        )
        self.assertEqual(old_minimized["GetClientRectCalls"], 4)

        # Failed queries are cached for this command list but stay invalid.
        cursor_failure = self._run(
            self.new_harness, SCENARIOS["get_cursor_info_failure"]["config"]
        )
        self.assertEqual(cursor_failure["GetCursorInfoCalls"], 1)
        self.assertEqual(cursor_failure["ScreenToClientCalls"], 0)
        self.assertEqual(cursor_failure["GetIconInfoCalls"], 0)

        old_cursor_failure = self._run(
            self.old_harness, SCENARIOS["get_cursor_info_failure"]["config"]
        )
        self.assertEqual(old_cursor_failure["GetCursorInfoCalls"], 1)
        self.assertEqual(old_cursor_failure["GetIconInfoCalls"], 1)

        rect_failure = self._run(
            self.new_harness, SCENARIOS["rect_failure_rt_fallback"]["config"]
        )
        self.assertEqual(rect_failure["GetClientRectCalls"], 1)
        self.assertEqual(rect_failure["ProcessParamRTSizeCalls"], 2)
        old_rect_failure = self._run(
            self.old_harness, SCENARIOS["rect_failure_rt_fallback"]["config"]
        )
        self.assertEqual(old_rect_failure["GetClientRectCalls"], 4)

    def test_next_state_retries_cached_failures(self) -> None:
        # A failed GetCursorInfo is cached for its command list, then retried
        # by the next command-list state.
        failure = scenario(cursor_ok=0, origin_x=100, origin_y=50)
        recovered = scenario(cursor_x=100, cursor_y=350, origin_x=100, origin_y=50)
        cursor_retry = self._run(self.new_harness, failure, next_config=recovered)
        self.assertEqual(cursor_retry["GetCursorInfoCalls"], 1)
        self.assertEqual(cursor_retry["ScreenToClientCalls"], 0)
        self.assertEqual(cursor_retry["CURSOR_X"], 0.0)
        self.assertEqual(cursor_retry["S2_GetCursorInfoCalls"], 1)
        self.assertEqual(cursor_retry["S2_ScreenToClientCalls"], 1)
        self.assertAlmostEqual(cursor_retry["S2_CURSOR_WINDOW_X"], 0.0, places=6)
        self.assertAlmostEqual(cursor_retry["S2_CURSOR_X"], 0.0, places=6)

        # A failed GetClientRect is cached as invalid for its command list,
        # then a fresh state retries it and recovers.
        rect_failure = scenario(cursor_x=640, cursor_y=360, rect_ok=0)
        rect_recovered = scenario(cursor_x=640, cursor_y=360)
        rect_retry = self._run(
            self.new_harness, rect_failure, next_config=rect_recovered
        )
        self.assertEqual(rect_retry["GetClientRectCalls"], 1)
        self.assertEqual(rect_retry["CURSOR_X"], 0.0)
        self.assertEqual(rect_retry["S2_GetClientRectCalls"], 1)
        self.assertAlmostEqual(rect_retry["S2_CURSOR_X"], 0.5, places=6)
        self.assertAlmostEqual(rect_retry["S2_CURSOR_Y"], 0.5, places=6)

        # A successful but zero-sized rect is cached as a valid zero and is
        # not usable, so the next state must retry and recover.
        zero_sized = scenario(cursor_x=300, cursor_y=200, client_w=0, client_h=0)
        positive = scenario(cursor_x=640, cursor_y=360)
        zero_retry = self._run(self.new_harness, zero_sized, next_config=positive)
        self.assertEqual(zero_retry["GetClientRectCalls"], 1)
        self.assertEqual(zero_retry["CURSOR_X"], 0.0)
        self.assertEqual(zero_retry["S2_GetClientRectCalls"], 1)
        self.assertAlmostEqual(zero_retry["S2_CURSOR_X"], 0.5, places=6)
        self.assertAlmostEqual(zero_retry["S2_CURSOR_Y"], 0.5, places=6)

    def test_get_icon_info_call_counts(self) -> None:
        success = self._run(self.new_harness, scenario())
        self.assertEqual(success["GetIconInfoCalls"], 1)
        self.assertAlmostEqual(success["CURSOR_HOTSPOT_X"], 5.0, places=6)
        self.assertAlmostEqual(success["CURSOR_HOTSPOT_Y"], 7.0, places=6)

        failure = self._run(self.new_harness, scenario(cursor_ok=0))
        self.assertEqual(failure["GetIconInfoCalls"], 0)
        self.assertEqual(failure["CURSOR_HOTSPOT_X"], 0.0)
        self.assertEqual(failure["CURSOR_HOTSPOT_Y"], 0.0)

        old_success = self._run(self.old_harness, scenario())
        self.assertEqual(old_success["GetIconInfoCalls"], 1)
        old_failure = self._run(self.old_harness, scenario(cursor_ok=0))
        self.assertEqual(old_failure["GetIconInfoCalls"], 1)
        self.assertAlmostEqual(old_failure["CURSOR_HOTSPOT_X"], 5.0, places=6)

    def test_absent_full_source_is_optional(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macgacha-cursor-source-") as raw:
            root = Path(raw)
            self.assertIsNone(
                resolve_optional_full_source(None, root / "missing", self.pin)
            )
            self.assertIsNone(
                resolve_optional_full_source("", root / "missing", self.pin)
            )

    def test_wrong_full_source_override_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macgacha-cursor-source-") as raw:
            root = Path(raw)
            wrong = root / "wrong"
            wrong.mkdir()
            (wrong / "unexpected.txt").write_text("not the pinned tree\n", encoding="utf-8")
            with self.assertRaises(AssertionError):
                resolve_optional_full_source(str(wrong), root / "unused", self.pin)
            with self.assertRaises(AssertionError):
                resolve_optional_full_source(
                    str(root / "absent"), root / "unused", self.pin
                )
            with self.assertRaises(AssertionError):
                require_source_pin_match(wrong, self.pin)

    def test_authenticated_full_source_tree_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macgacha-cursor-source-") as raw:
            root = Path(raw)
            tree = root / "tree"
            tree.mkdir()
            (tree / "a.txt").write_text("pinned\n", encoding="utf-8")
            (tree / "DirectX11").mkdir()
            (tree / "DirectX11" / "CommandList.cpp").write_text(
                "// source\n", encoding="utf-8"
            )
            manifest = REBUILD.tree_manifest(tree)
            fake_pin = {
                "cleanTreeSHA256": manifest["sha256"],
                "cleanFileCount": manifest["fileCount"],
            }
            selected = resolve_optional_full_source(str(tree), root / "unused", fake_pin)
            self.assertEqual(selected, tree)

            (tree / "a.txt").write_text("tampered\n", encoding="utf-8")
            with self.assertRaises(AssertionError):
                resolve_optional_full_source(str(tree), root / "unused", fake_pin)

    def test_full_source_patch_chain_matches_fixture(self) -> None:
        if self.full_new_source is None or self.full_new_header is None:
            self.skipTest("pinned full XXMI Libraries source is absent")

        for name in (
            "UpdateWindowInfo",
            "GetClientExtent",
            "UpdateCursorInfo",
            "UpdateCursorInfoEx",
            "HeuristicGetWindowWidth",
            "HeuristicGetWindowHeight",
        ):
            self.assertEqual(
                extract_function(self.full_new_source, name),
                extract_function(self.new_source, name),
                f"{name} differs between the full patched tree and the fixture",
            )
        self.assertEqual(
            extract_constructor(self.full_new_source),
            extract_constructor(self.new_source),
        )
        self.assertEqual(
            extract_cursor_cases(self.full_new_source),
            extract_cursor_cases(self.new_source),
        )
        self.assertEqual(
            extract_block(self.full_new_header, "class CommandListState {"),
            extract_block(self.new_header, "class CommandListState {"),
        )
        self.assertEqual(
            extract_block(self.full_new_header, "enum class ParamOverrideType {"),
            extract_block(self.new_header, "enum class ParamOverrideType {"),
        )


if __name__ == "__main__":
    unittest.main()
