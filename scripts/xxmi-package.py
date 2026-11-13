#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Build or verify an offline XXMI resource package.

The package is a deterministic ZIP plus an external schema-version-1 manifest.
It contains only the verified runner, injector, game payload, runtime
configuration and shader files. The default pins build the HSR SRMI package;
the separate ZZMI pins build a ZZZ package from the shared XXMI core and the
pinned ZZMI configuration. User mods, logs, caches, profile state and PoC
diagnostics are rejected rather than silently packaged.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import struct
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
ZIP_DATE_TIME = (1980, 1, 1, 0, 0, 0)
ZIP_FILE_MODE = stat.S_IFREG | 0o644
ZIP_CREATE_SYSTEM = 3
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TARGET_EXE = "StarRail.exe"
GAME_TARGETS = {"starrail": "StarRail.exe", "zzz": "ZenlessZoneZero.exe"}
DEFAULT_REQUIRED_PAYLOAD_ROOT_FILES = {"d3d11.dll", "d3dcompiler_47.dll", "d3dx.ini"}
DEFAULT_ALLOWED_PAYLOAD_ROOT_DIRS = {"Core"}
DEFAULT_SHADER_PATH = "Core/SRMI/Shaders/TextPrinter.hlsl"
IGNORED_PAYLOAD_ROOT_NAMES = {
    "Mods",
    "ShaderCache",
    "ShaderFixes",
    "d3dx_user.ini",
    "d3d11_log.txt",
    ".DS_Store",
}
IGNORED_PAYLOAD_FILE_NAMES = {".DS_Store"}
D3DX_INI_PATH = "payload/d3dx.ini"
D3DX_INI_RELATIVE = "d3dx.ini"
ZZZ_RUNTIME_BINARY_FILES = {"d3d11.dll", "d3dcompiler_47.dll"}
FORBIDDEN_SOURCE_PATHS = ("/Users/", "Z:\\Users\\", "C:\\Users\\", "\\\\Users\\\\")


class PackageError(RuntimeError):
    """Expected, user-facing package failure."""


def _load_resources_module() -> Any:
    script = REPO_ROOT / "scripts" / "xxmi-payload-resources.py"
    spec = importlib.util.spec_from_file_location("xxmi_payload_resources", script)
    if spec is None or spec.loader is None:
        raise PackageError(f"cannot load {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    # Never leave a __pycache__ beside the archived source tools.
    previous, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


RESOURCES = _load_resources_module()
_RESOURCE_KEYS = ("label", "type", "name", "language", "size", "sha256", "kind")


def verify_payload_resources(data: bytes, entry: dict[str, Any], label: str) -> None:
    """Require the pinned PE resources (the Overlay SPRITEFONT fonts) when declared.

    The payload hash pin already fixes the bytes; this independent check names
    the actual defect instead of a bare hash mismatch, and rejects a pin set
    whose declared resources the pinned payload does not contain.
    """
    expected = entry.get("resources")
    if expected is None:
        return
    if not isinstance(expected, list) or not expected:
        raise PackageError(f"source pins {label} resources must be a non-empty list")
    for item in expected:
        if not isinstance(item, dict) or set(item) != set(_RESOURCE_KEYS):
            raise PackageError(f"source pins {label} resource entry is malformed")
        if item["kind"] not in ("spritefont", "version"):
            raise PackageError(f"source pins {label} resource kind is unsupported")
    try:
        RESOURCES.verify_dll_resources(data, expected)
    except RESOURCES.ResourceError as exc:
        raise PackageError(f"{label} PE resources do not match the pins: {exc}") from exc


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _version_tuple(value: Any, label: str) -> tuple[int, ...]:
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+)+", value):
        raise PackageError(f"{label} must be a dotted numeric version")
    parts = [int(part) for part in value.split(".")]
    while len(parts) < 3:
        parts.append(0)
    if len(parts) > 4:
        raise PackageError(f"{label} has too many version components")
    return tuple(parts)


def _version_at_least(actual: str, minimum: str) -> bool:
    left = _version_tuple(actual, "actual core version")
    right = _version_tuple(minimum, "minimum core version")
    width = max(len(left), len(right))
    return left + (0,) * (width - len(left)) >= right + (0,) * (width - len(right))


def _safe_package_relative(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise PackageError(f"{label} must be a non-empty relative path")
    if not value or "\\" in value or "\x00" in value:
        raise PackageError(f"unsafe {label}: {value!r}")
    if value.startswith("/") or re.match(r"^[A-Za-z]:", value):
        raise PackageError(f"absolute {label}: {value}")
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise PackageError(f"{label} has an unsafe path component: {value}")
    return value


def _package_target(package: dict[str, Any]) -> str:
    game_id = package.get("gameID")
    expected = GAME_TARGETS.get(game_id) if isinstance(game_id, str) else None
    if expected is None:
        raise PackageError(f"unsupported package gameID: {game_id!r}")
    target = package.get("targetExe", DEFAULT_TARGET_EXE)
    if not isinstance(target, str) or not target:
        raise PackageError("source pins package targetExe must be a non-empty string")
    if target.casefold() != expected.casefold():
        raise PackageError(
            f"source pins package gameID {game_id!r} requires targetExe {expected}"
        )
    return expected


def _package_shader_path(package: dict[str, Any]) -> str:
    return _safe_package_relative(
        package.get("shaderPath", DEFAULT_SHADER_PATH), "package shaderPath"
    )


def _package_payload_root_dirs(package: dict[str, Any]) -> set[str]:
    value = package.get("payloadRootDirs", sorted(DEFAULT_ALLOWED_PAYLOAD_ROOT_DIRS))
    if not isinstance(value, list) or not value:
        raise PackageError("source pins package payloadRootDirs must be a non-empty array")
    result = set()
    for entry in value:
        if not isinstance(entry, str) or not entry or "/" in entry or "\\" in entry:
            raise PackageError("source pins package payloadRootDirs must be directory names")
        if entry in result:
            raise PackageError(f"duplicate payload root directory: {entry}")
        result.add(entry)
    return result


def _runtime_file_pins(pins: dict[str, Any]) -> dict[str, tuple[int, str]]:
    runtime = pins.get("runtimeFiles")
    if not isinstance(runtime, dict) or not runtime:
        raise PackageError(
            "ZZZ source pins need a non-empty runtimeFiles file hash mapping"
        )
    mapping: dict[str, tuple[int, str]] = {}
    for relative, entry in runtime.items():
        name = _safe_package_relative(relative, "runtimeFiles path")
        if name in ZZZ_RUNTIME_BINARY_FILES:
            raise PackageError(
                f"runtimeFiles must not pin the shared core binary: {name}"
            )
        if not isinstance(entry, dict):
            raise PackageError(f"runtimeFiles entry {name} must be an object")
        size = entry.get("size")
        digest = entry.get("sha256")
        if not isinstance(size, int) or size < 0 or not isinstance(digest, str) or not re.fullmatch(
            r"[0-9a-f]{64}", digest
        ):
            raise PackageError(
                f"runtimeFiles entry {name} needs an exact size and SHA-256"
            )
        mapping[name] = (size, digest)
    if len({name.casefold() for name in mapping}) != len(mapping):
        raise PackageError("runtimeFiles paths have a case-insensitive collision")
    if D3DX_INI_RELATIVE not in mapping:
        raise PackageError("runtimeFiles is missing d3dx.ini")
    return mapping


def _normalized_d3dx_pin(pins: dict[str, Any]) -> tuple[str, int, str]:
    entry = pins["package"].get("normalizedD3dxIni")
    if not isinstance(entry, dict):
        raise PackageError(
            "ZZZ source pins package needs the exact normalized d3dxIni hash"
        )
    relative = _safe_package_relative(entry.get("path", D3DX_INI_RELATIVE), "normalizedD3dxIni path")
    if relative != D3DX_INI_RELATIVE:
        raise PackageError("normalizedD3dxIni path must be d3dx.ini")
    size = entry.get("size")
    digest = entry.get("sha256")
    if not isinstance(size, int) or size <= 0 or not isinstance(digest, str) or not re.fullmatch(
        r"[0-9a-f]{64}", digest
    ):
        raise PackageError(
            "normalizedD3dxIni needs an exact size and SHA-256"
        )
    return relative, size, digest


def _verify_runtime_files(pins: dict[str, Any], payload_files: dict[str, Path]) -> None:
    if pins["package"].get("gameID") != "zzz":
        return
    mapping = _runtime_file_pins(pins)
    expected = set(mapping) | ZZZ_RUNTIME_BINARY_FILES
    actual = set(payload_files)
    missing = expected - actual
    unexpected = actual - expected
    if missing or unexpected:
        details = []
        if missing:
            details.append("missing " + ", ".join(sorted(missing)))
        if unexpected:
            details.append("unexpected " + ", ".join(sorted(unexpected)))
        raise PackageError(
            "payload does not match the authenticated ZZMI runtime file set: "
            + "; ".join(details)
        )
    for relative, (size, digest) in mapping.items():
        path = payload_files[relative]
        if path.stat().st_size != size:
            raise PackageError(
                f"authenticated ZZMI runtime file size does not match: {relative}"
            )
        if sha256_file(path) != digest:
            raise PackageError(
                f"authenticated ZZMI runtime file SHA-256 does not match: {relative}"
            )


def _flatten_sources(value: Any) -> dict[str, str]:
    flattened: dict[str, str] = {}

    def flatten(prefix: str, item: Any) -> None:
        if isinstance(item, dict):
            for key in sorted(item):
                flatten(f"{prefix}.{key}" if prefix else key, item[key])
        elif isinstance(item, str):
            flattened[prefix] = item
        else:
            flattened[prefix] = json.dumps(item, sort_keys=True, separators=(",", ":"))

    flatten("", value)
    return flattened


def _expected_manifest_sources(pins: dict[str, Any]) -> dict[str, str]:
    sources = dict(pins["sources"])
    if isinstance(pins.get("build"), dict):
        sources["build"] = pins["build"]
    return _flatten_sources(sources)


def _regular_file(path: Path, label: str) -> Path:
    try:
        info = path.lstat()
    except OSError as exc:
        raise PackageError(f"missing {label}: {path}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise PackageError(f"{label} must be a regular non-symlink file: {path}")
    return path


def _load_json(path: Path, label: str) -> dict[str, Any]:
    _regular_file(path, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PackageError(f"{label} is not valid UTF-8 JSON: {path}") from exc
    if not isinstance(value, dict):
        raise PackageError(f"{label} must be a JSON object: {path}")
    return value


def _u16(data: bytes, offset: int) -> int:
    if offset + 2 > len(data):
        raise PackageError("truncated PE header")
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes, offset: int) -> int:
    if offset + 4 > len(data):
        raise PackageError("truncated PE header")
    return struct.unpack_from("<I", data, offset)[0]


def _cstring(data: bytes, offset: int) -> str:
    end = data.find(b"\0", offset, offset + 512)
    if end < 0:
        raise PackageError("unterminated PE export name")
    try:
        return data[offset:end].decode("ascii")
    except UnicodeDecodeError as exc:
        raise PackageError("non-ASCII PE export name") from exc


def pe_info(data: bytes) -> dict[str, Any]:
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise PackageError("file is not an MZ/PE image")
    pe_offset = _u32(data, 0x3C)
    if data[pe_offset:pe_offset + 4] != b"PE\0\0":
        raise PackageError("file has no PE signature")
    machine = _u16(data, pe_offset + 4)
    section_count = _u16(data, pe_offset + 6)
    optional_size = _u16(data, pe_offset + 20)
    characteristics = _u16(data, pe_offset + 22)
    optional = pe_offset + 24
    magic = _u16(data, optional)
    if magic == 0x20B:
        data_directories = optional + 0x70
    elif magic == 0x10B:
        data_directories = optional + 0x60
    else:
        raise PackageError(f"unsupported PE optional header magic 0x{magic:04x}")
    export_rva = _u32(data, data_directories)
    export_size = _u32(data, data_directories + 4)
    section_table = optional + optional_size
    sections = []
    for index in range(section_count):
        offset = section_table + index * 40
        virtual_size = _u32(data, offset + 8)
        virtual_address = _u32(data, offset + 12)
        raw_size = _u32(data, offset + 16)
        raw_pointer = _u32(data, offset + 20)
        sections.append((virtual_address, virtual_size, raw_size, raw_pointer))
    return {
        "machine": machine,
        "is_dll": bool(characteristics & 0x2000),
        "export_rva": export_rva,
        "export_size": export_size,
        "sections": sections,
    }


def pe_exports(data: bytes) -> list[str]:
    info = pe_info(data)
    if info["export_rva"] == 0 or info["export_size"] == 0:
        return []

    def rva_to_offset(rva: int) -> int:
        for virtual_address, virtual_size, raw_size, raw_pointer in info["sections"]:
            span = max(virtual_size, raw_size)
            if virtual_address <= rva < virtual_address + span:
                offset = raw_pointer + (rva - virtual_address)
                if offset >= len(data):
                    raise PackageError("PE export RVA points outside the file")
                return offset
        raise PackageError(f"PE export RVA 0x{rva:x} is not mapped by a section")

    export = rva_to_offset(info["export_rva"])
    name_count = _u32(data, export + 24)
    names_rva = _u32(data, export + 32)
    if name_count > 4096:
        raise PackageError("PE export name count is implausible")
    names_table = rva_to_offset(names_rva)
    names = []
    for index in range(name_count):
        name_rva = _u32(data, names_table + index * 4)
        names.append(_cstring(data, rva_to_offset(name_rva)))
    return names


def verify_pe(path: Path, *, dll: bool, label: str) -> bytes:
    data = path.read_bytes()
    info = pe_info(data)
    if info["machine"] != 0x8664:
        raise PackageError(f"{label} is not x86-64")
    if info["is_dll"] != dll:
        expected = "DLL" if dll else "executable"
        raise PackageError(f"{label} is not a PE {expected}")
    return data


def _parse_ini(lines: list[str]) -> dict[str, list[tuple[int, str, str]]]:
    sections: dict[str, list[tuple[int, str, str]]] = {}
    current: str | None = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            current = stripped[1:-1].strip().lower()
            sections.setdefault(current, [])
            continue
        if current is None or not stripped or stripped.startswith(";"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        sections[current].append((index, key.strip().lower(), value.strip()))
    return sections


def _section_value(
    sections: dict[str, list[tuple[int, str, str]]], section: str, key: str
) -> str:
    matches = [value for _, name, value in sections.get(section, []) if name == key]
    if len(matches) != 1:
        raise PackageError(f"d3dx.ini [{section}] requires exactly one active {key} entry")
    return matches[0]


def _optional_section_value(
    sections: dict[str, list[tuple[int, str, str]]], section: str, key: str
) -> str | None:
    matches = [value for _, name, value in sections.get(section, []) if name == key]
    if len(matches) > 1:
        raise PackageError(f"d3dx.ini [{section}] has duplicate {key} entries")
    return matches[0] if matches else None


def _replace_section_value(
    lines: list[str],
    sections: dict[str, list[tuple[int, str, str]]],
    section: str,
    key: str,
    value: str,
) -> None:
    matches = [index for index, name, _ in sections.get(section, []) if name == key]
    if len(matches) != 1:
        raise PackageError(f"d3dx.ini [{section}] requires exactly one {key} entry")
    lines[matches[0]] = f"{key} = {value}"


def normalize_d3dx_ini(path: Path, *, target_exe: str) -> bytes:
    _regular_file(path, "d3dx.ini")
    try:
        text = path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError as exc:
        raise PackageError("d3dx.ini is not UTF-8") from exc
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    sections = _parse_ini(lines)
    if _section_value(sections, "loader", "target").casefold() != target_exe.casefold():
        raise PackageError(f"d3dx.ini [Loader] target must be {target_exe}")
    loader_lines = [
        index for index, name, _ in sections.get("loader", []) if name == "loader"
    ]
    if len(loader_lines) != 1:
        raise PackageError("d3dx.ini [Loader] requires one loader entry")
    lines[loader_lines[0]] = "loader = hook-runner.exe"
    if _section_value(sections, "loader", "module").casefold() != "d3d11.dll":
        raise PackageError("d3dx.ini [Loader] module must be d3d11.dll")
    launch_lines = [
        index for index, name, value in sections.get("loader", []) if name == "launch" and value
    ]
    for index in launch_lines:
        lines[index] = ";launch ="
    proxy_lines = [
        index
        for index, name, _ in sections.get("system", [])
        if name == "proxy_d3d11"
    ]
    if len(proxy_lines) > 1:
        raise PackageError("d3dx.ini [System] has duplicate proxy_d3d11 entries")
    if proxy_lines:
        lines[proxy_lines[0]] = "proxy_d3d11 ="
    else:
        system_headers = [
            index for index, line in enumerate(lines) if line.strip().casefold() == "[system]"
        ]
        if len(system_headers) != 1:
            raise PackageError("d3dx.ini requires exactly one [System] section")
        lines.insert(system_headers[0] + 1, "proxy_d3d11 =")
    sections = _parse_ini(lines)
    if "logging" not in sections:
        raise PackageError("d3dx.ini is missing the [Logging] section")
    logging_keys = {name for _, name, _ in sections.get("logging", [])}
    for key in ("calls", "debug", "unbuffered"):
        if key in logging_keys:
            _replace_section_value(lines, sections, "logging", key, "0")
    if "log_level" in logging_keys:
        _replace_section_value(lines, sections, "logging", "log_level", "none")
    if "calls" not in logging_keys and "log_level" not in logging_keys:
        raise PackageError("d3dx.ini [Logging] has no calls or log_level switch")
    normalized = "\n".join(lines).rstrip("\n") + "\n"
    for forbidden in FORBIDDEN_SOURCE_PATHS:
        if forbidden in normalized:
            raise PackageError(f"d3dx.ini still contains a developer path: {forbidden}")
    if "proxy_d3d11 =" not in normalized:
        raise PackageError("d3dx.ini proxy_d3d11 was not neutralized")
    return normalized.encode("utf-8")


def _safe_archive_path(path: str) -> None:
    if not path or "\\" in path or "\x00" in path:
        raise PackageError(f"unsafe archive path: {path!r}")
    if path.startswith("/") or re.match(r"^[A-Za-z]:", path):
        raise PackageError(f"absolute archive path: {path}")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise PackageError(f"archive path has an empty, dot, or traversal component: {path}")


def collect_payload_files(
    payload_dir: Path,
    *,
    allowed_root_dirs: set[str] | None = None,
    required_root_files: set[str] | None = None,
    ignored_root_names: set[str] | None = None,
) -> dict[str, Path]:
    allowed_root_dirs = allowed_root_dirs or set(DEFAULT_ALLOWED_PAYLOAD_ROOT_DIRS)
    required_root_files = required_root_files or set(DEFAULT_REQUIRED_PAYLOAD_ROOT_FILES)
    ignored_root_names = (
        set(IGNORED_PAYLOAD_ROOT_NAMES) if ignored_root_names is None else set(ignored_root_names)
    ) - allowed_root_dirs
    _regular_file(payload_dir / "d3d11.dll", "payload d3d11.dll")
    try:
        root = payload_dir.resolve(strict=True)
    except OSError as exc:
        raise PackageError(f"payload directory is missing: {payload_dir}") from exc
    if not root.is_dir():
        raise PackageError(f"payload path is not a directory: {payload_dir}")
    files: dict[str, Path] = {}
    for entry in sorted(root.iterdir(), key=lambda item: item.name):
        name = entry.name
        if name in ignored_root_names:
            continue
        if entry.is_symlink():
            raise PackageError(f"payload root contains a symlink: {name}")
        if entry.is_dir():
            if name not in allowed_root_dirs:
                raise PackageError(f"payload root contains an unexpected directory: {name}")
            for child in sorted(entry.rglob("*"), key=lambda item: item.as_posix()):
                if child.is_symlink():
                    raise PackageError(f"payload contains a symlink: {child}")
                if not child.is_file():
                    continue
                if child.name in IGNORED_PAYLOAD_FILE_NAMES:
                    continue
                relative = child.relative_to(root).as_posix()
                _safe_archive_path(relative)
                files[relative] = child
            continue
        if not entry.is_file():
            raise PackageError(f"payload root contains a non-regular entry: {name}")
        if name in IGNORED_PAYLOAD_FILE_NAMES or name.endswith((".log", ".dmp")):
            continue
        if name not in required_root_files:
            raise PackageError(
                "payload root contains an unexpected file; refusing to package user data: "
                + name
            )
        files[name] = entry
    missing = required_root_files - set(files)
    if missing:
        raise PackageError("payload is missing required files: " + ", ".join(sorted(missing)))
    return files


def _load_pins(path: Path) -> dict[str, Any]:
    pins = _load_json(path, "source pins")
    package = pins.get("package")
    verified = pins.get("verifiedBinaries")
    sources = pins.get("sources")
    if not isinstance(package, dict) or not isinstance(verified, dict) or not isinstance(sources, dict):
        raise PackageError("source pins are missing package, verifiedBinaries or sources")
    for key in (
        "id",
        "version",
        "gameID",
        "runnerPath",
        "injectorPath",
        "payloadPath",
        "archiveName",
        "manifestName",
        "license",
    ):
        if not isinstance(package.get(key), str) or not package[key]:
            raise PackageError(f"source pins package is missing {key}")
    runtime_ids = package.get("supportedRuntimeBundleIDs")
    if not isinstance(runtime_ids, list) or not runtime_ids or not all(
        isinstance(item, str) and item for item in runtime_ids
    ):
        raise PackageError("source pins package needs supportedRuntimeBundleIDs")
    if package["gameID"] == "zzz":
        _runtime_file_pins(pins)
        _normalized_d3dx_pin(pins)
    return pins


def _verify_runner(pins: dict[str, Any]) -> None:
    runner = pins["verifiedBinaries"].get("runner")
    if not isinstance(runner, dict):
        raise PackageError("source pins verifiedBinaries.runner must be an object")
    runner_path = Path(pins["_runner"])
    runner_data = verify_pe(runner_path, dll=False, label="runner")
    pinned_sha = runner.get("sha256")
    pinned_size = runner.get("size")
    if not isinstance(pinned_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", pinned_sha):
        raise PackageError(
            "source pins verifiedBinaries.runner needs an exact SHA-256 pin"
        )
    if not isinstance(pinned_size, int) or pinned_size <= 0:
        raise PackageError(
            "source pins verifiedBinaries.runner needs an exact size pin"
        )
    if sha256_bytes(runner_data) != pinned_sha:
        raise PackageError("runner SHA-256 does not match the pinned verified runner")
    if len(runner_data) != pinned_size:
        raise PackageError("runner size does not match the pinned verified runner")
    source_path = runner.get("sourcePath")
    source_sha = runner.get("sourceSHA256")
    if source_path is not None or source_sha is not None:
        if not isinstance(source_path, str) or not isinstance(source_sha, str):
            raise PackageError(
                "runner source provenance needs both sourcePath and sourceSHA256"
            )
        source = Path(source_path)
        if not source.is_absolute():
            source = REPO_ROOT / source
        _regular_file(source, "runner source pin")
        if sha256_file(source) != source_sha:
            raise PackageError("runner source SHA-256 does not match the source pin")


def _verify_config_pins(pins: dict[str, Any], payload_files: dict[str, Path]) -> None:
    config = pins["verifiedBinaries"].get("config")
    if config is None:
        return
    if not isinstance(config, dict):
        raise PackageError("source pins verifiedBinaries.config must be an object")
    for name, entry in config.items():
        if not isinstance(entry, dict):
            raise PackageError(f"source pins config entry {name} must be an object")
        relative = _safe_package_relative(entry.get("path"), f"config entry {name}")
        path = payload_files.get(relative)
        if path is None:
            raise PackageError(f"payload is missing pinned config file: {relative}")
        if sha256_file(path) != entry.get("sha256"):
            raise PackageError(f"config file SHA-256 does not match the pin: {relative}")
        size = entry.get("size")
        if size is not None and path.stat().st_size != size:
            raise PackageError(f"config file size does not match the pin: {relative}")


def _shared_core_pins(pins: dict[str, Any], pins_path: Path) -> dict[str, Any]:
    shared = pins.get("sharedXxmiCore")
    if shared is None:
        shared = pins.get("sourcePins", {}).get("sharedXxmiCore")
    if shared is None:
        return {}
    if not isinstance(shared, dict):
        raise PackageError("source pins sharedXxmiCore must be an object")
    relative = shared.get("pins")
    if not isinstance(relative, str) or not relative:
        raise PackageError("source pins sharedXxmiCore.pins must be a path")
    path = Path(relative)
    if not path.is_absolute():
        path = REPO_ROOT / path
    return _load_json(path, "shared XXMI core pins")


def _verify_core_compatibility(pins: dict[str, Any], pins_path: Path) -> None:
    shared = pins.get("sharedXxmiCore")
    if shared is None:
        shared = pins.get("sourcePins", {}).get("sharedXxmiCore")
    compatibility = pins.get("coreCompatibility")
    if shared is None and compatibility is None:
        return
    if not isinstance(shared, dict) or not isinstance(compatibility, dict):
        raise PackageError(
            "ZZZ source pins need both sharedXxmiCore and coreCompatibility"
        )
    minimum = compatibility.get("minimumVersion")
    pinned = compatibility.get("pinnedVersion")
    if not isinstance(minimum, str) or not isinstance(pinned, str):
        raise PackageError(
            "coreCompatibility needs minimumVersion and pinnedVersion"
        )
    _version_tuple(minimum, "coreCompatibility.minimumVersion")
    _version_tuple(pinned, "coreCompatibility.pinnedVersion")
    if not isinstance(compatibility.get("basis"), str) or not compatibility["basis"].strip():
        raise PackageError("coreCompatibility needs an upstream basis")
    upstream_release = compatibility.get("upstreamRelease")
    if not isinstance(upstream_release, str) or not re.fullmatch(
        r"https://github\.com/SpectrumQT/XXMI-Libs-Package/releases/tag/v[0-9.]+",
        upstream_release,
    ):
        raise PackageError(
            "coreCompatibility.upstreamRelease must be a pinned XXMI Libraries release URL"
        )
    release_version = upstream_release.rsplit("/", 1)[-1][1:]
    if release_version != minimum:
        raise PackageError(
            "coreCompatibility.upstreamRelease must describe the declared minimum version"
        )
    checks = compatibility.get("featureChecks")
    if not isinstance(checks, list) or not checks:
        raise PackageError(
            "coreCompatibility needs at least one upstream feature check"
        )
    for entry in checks:
        if not isinstance(entry, dict):
            raise PackageError("coreCompatibility feature check must be an object")
        _safe_package_relative(entry.get("path"), "coreCompatibility feature path")
        if not isinstance(entry.get("contains"), str) or not entry["contains"]:
            raise PackageError("coreCompatibility feature check needs a marker")
        introduced = _version_tuple(entry.get("introducedIn"), "feature introducedIn")
        if introduced > _version_tuple(pinned, "coreCompatibility.pinnedVersion"):
            raise PackageError(
                "coreCompatibility feature is newer than the pinned core version"
            )
    shared_pins = _shared_core_pins(pins, pins_path)
    tag = shared_pins.get("sourcePins", {}).get("xxmiLibsPackage", {}).get("tag")
    if not isinstance(tag, str) or not re.fullmatch(r"v[0-9.]+", tag):
        raise PackageError("shared XXMI core pins do not declare an exact version tag")
    actual = tag[1:]
    declared = shared.get("version")
    if declared != actual:
        raise PackageError(
            "sharedXxmiCore.version does not match the shared XXMI core pins"
        )
    if actual != pinned:
        raise PackageError(
            "coreCompatibility.pinnedVersion does not match the shared XXMI core pins"
        )
    if not _version_at_least(actual, minimum):
        raise PackageError(
            "pinned XXMI core version is older than the compatibility requirement"
        )
    shared_verified = shared_pins.get("verifiedBinaries", {})
    if shared_verified.get("payload", {}).get("sha256") != shared.get(
        "verifiedPayloadSHA256"
    ):
        raise PackageError(
            "sharedXxmiCore.verifiedPayloadSHA256 does not match the shared core pins"
        )
    if shared_verified.get("d3dcompiler", {}).get("sha256") != shared.get(
        "verifiedCompilerSHA256"
    ):
        raise PackageError(
            "sharedXxmiCore.verifiedCompilerSHA256 does not match the shared core pins"
        )
    if shared_verified.get("injector", {}).get("sha256") != shared.get(
        "verifiedInjectorSHA256"
    ):
        raise PackageError(
            "sharedXxmiCore.verifiedInjectorSHA256 does not match the shared core pins"
        )


def _verify_zzmi_version(pins: dict[str, Any], files: dict[str, Path]) -> None:
    if pins["package"].get("gameID") != "zzz":
        return
    upstream = pins["package"].get("upstreamVersion")
    if not isinstance(upstream, str):
        raise PackageError("ZZMI source pins package needs upstreamVersion")
    _version_tuple(upstream, "package.upstreamVersion")
    main = files.get("Core/ZZMI/main.ini")
    if main is None:
        raise PackageError("ZZMI payload is missing Core/ZZMI/main.ini")
    text = main.read_text(encoding="utf-8-sig", errors="replace")
    if f"ZZMI {upstream}" not in text:
        raise PackageError(
            f"ZZMI main.ini does not declare version {upstream}"
        )
    compatibility = pins.get("coreCompatibility")
    if not isinstance(compatibility, dict):
        return
    for entry in compatibility.get("featureChecks", []):
        path = files.get(entry["path"])
        if path is None:
            raise PackageError(
                f"ZZMI payload is missing core-compatibility feature file: {entry['path']}"
            )
        data = path.read_text(encoding="utf-8-sig", errors="replace")
        if entry["contains"] not in data:
            raise PackageError(
                "ZZMI payload does not use the declared XXMI core feature: "
                + entry["contains"]
            )


def _verify_zzmi_archive(pins: dict[str, Any], archive: zipfile.ZipFile, names: list[str]) -> None:
    if pins["package"].get("gameID") != "zzz":
        return
    upstream = pins["package"].get("upstreamVersion")
    if not isinstance(upstream, str):
        raise PackageError("ZZMI source pins package needs upstreamVersion")
    main_name = "payload/Core/ZZMI/main.ini"
    if main_name not in names:
        raise PackageError("ZZMI archive is missing Core/ZZMI/main.ini")
    text = archive.read(main_name).decode("utf-8", "replace")
    if f"ZZMI {upstream}" not in text:
        raise PackageError(
            f"packaged ZZMI main.ini does not declare version {upstream}"
        )
    compatibility = pins.get("coreCompatibility")
    if not isinstance(compatibility, dict):
        return
    for entry in compatibility.get("featureChecks", []):
        name = f"payload/{entry['path']}"
        if name not in names:
            raise PackageError(
                f"archive is missing core-compatibility feature file: {entry['path']}"
            )
        if entry["contains"] not in archive.read(name).decode("utf-8", "replace"):
            raise PackageError(
                "packaged ZZMI payload does not use the declared XXMI core feature: "
                + entry["contains"]
            )


def _verify_verified_inputs(
    pins: dict[str, Any], payload_files: dict[str, Path], *, shader_path: str
) -> None:
    verified = pins["verifiedBinaries"]
    for key in ("injector", "payload", "d3dcompiler", "textPrinterShader"):
        entry = verified.get(key)
        if not isinstance(entry, dict) or not isinstance(entry.get("sha256"), str):
            raise PackageError(f"source pins verifiedBinaries.{key} is missing its SHA-256")
    _verify_runner(pins)
    _verify_core_compatibility(pins, Path(pins["_pins_path"]))
    _verify_config_pins(pins, payload_files)
    _verify_zzmi_version(pins, payload_files)
    _verify_runtime_files(pins, payload_files)
    injector = verified["injector"]
    injector_data = verify_pe(Path(pins["_injector"]), dll=True, label="injector")
    if sha256_bytes(injector_data) != injector["sha256"]:
        raise PackageError("injector SHA-256 does not match the pinned verified injector")
    if len(injector_data) != injector.get("size", 0):
        raise PackageError("injector size does not match the pinned verified injector")
    exports = set(pe_exports(injector_data))
    required = set(injector.get("requiredExports", []))
    missing = required - exports
    if missing:
        raise PackageError("injector is missing required exports: " + ", ".join(sorted(missing)))
    expected = injector.get("expectedExports")
    if isinstance(expected, list) and set(expected) != exports:
        raise PackageError(
            "injector exports do not exactly match the verified core API: "
            + ", ".join(sorted(exports))
        )
    payload_data = verify_pe(payload_files["d3d11.dll"], dll=True, label="payload")
    if sha256_bytes(payload_data) != verified["payload"]["sha256"]:
        raise PackageError("payload D3D11 SHA-256 does not match the verified baseline")
    if len(payload_data) != verified["payload"].get("size", 0):
        raise PackageError("payload D3D11 size does not match the verified baseline")
    verify_payload_resources(payload_data, verified["payload"], "payload")
    compiler_data = verify_pe(payload_files["d3dcompiler_47.dll"], dll=True, label="d3dcompiler_47.dll")
    if sha256_bytes(compiler_data) != verified["d3dcompiler"]["sha256"]:
        raise PackageError("d3dcompiler_47.dll SHA-256 does not match the pinned dependency")
    shader = payload_files.get(shader_path)
    if shader is None:
        raise PackageError(f"payload is missing {shader_path}")
    if sha256_file(shader) != verified["textPrinterShader"]["sha256"]:
        raise PackageError(f"{shader_path} SHA-256 does not match the pinned baseline")
    pinned_shader_path = verified["textPrinterShader"].get("path")
    if pinned_shader_path is not None and pinned_shader_path != shader_path:
        raise PackageError("source pins textPrinterShader.path does not match package shaderPath")


def _write_zip(path: Path, files: dict[str, bytes]) -> None:
    with zipfile.ZipFile(
        path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, allowZip64=False
    ) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=ZIP_DATE_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = ZIP_CREATE_SYSTEM
            info.external_attr = ZIP_FILE_MODE << 16
            info.internal_attr = 0
            info.extra = b""
            info.comment = b""
            archive.writestr(info, files[name])


def _build_manifest(
    pins: dict[str, Any], files: dict[str, bytes], archive_size: int, archive_sha256: str
) -> dict[str, Any]:
    package = pins["package"]
    entries = [
        {"path": name, "size": len(data), "sha256": sha256_bytes(data)}
        for name, data in sorted(files.items())
    ]
    sources = _expected_manifest_sources(pins)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "id": package["id"],
        "version": package["version"],
        "gameID": package["gameID"],
        "supportedRuntimeBundleIDs": list(package["supportedRuntimeBundleIDs"]),
        "runnerPath": package["runnerPath"],
        "injectorPath": package["injectorPath"],
        "payloadPath": package["payloadPath"],
        "archiveSize": archive_size,
        "archiveSHA256": archive_sha256,
        "files": entries,
        "sources": sources,
        "license": package["license"],
    }


def _validate_archive(
    archive_path: Path, manifest: dict[str, Any], pins: dict[str, Any] | None
) -> None:
    if pins is not None:
        target_exe = _package_target(pins["package"])
    else:
        target_exe = GAME_TARGETS.get(manifest.get("gameID"))
        if target_exe is None:
            raise PackageError(f"unsupported manifest gameID: {manifest.get('gameID')!r}")
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise PackageError("manifest files must be a non-empty array")
    expected: dict[str, tuple[int, str]] = {}
    for entry in files:
        if not isinstance(entry, dict):
            raise PackageError("manifest file entry must be an object")
        name = entry.get("path")
        size = entry.get("size")
        digest = entry.get("sha256")
        if not isinstance(name, str) or not isinstance(size, int) or size < 0 or not isinstance(digest, str):
            raise PackageError("manifest file entry is malformed")
        _safe_archive_path(name)
        if name in expected:
            raise PackageError(f"duplicate manifest path: {name}")
        if digest != sha256_bytes(b"") and not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise PackageError(f"invalid SHA-256 for {name}")
        expected[name] = (size, digest)
    if len({name.casefold() for name in expected}) != len(expected):
        raise PackageError("manifest paths have a case-insensitive collision")
    if list(expected) != sorted(expected):
        raise PackageError("manifest files are not sorted by path")
    try:
        archive_context = zipfile.ZipFile(archive_path)
    except (OSError, zipfile.BadZipFile) as exc:
        raise PackageError(f"archive is unreadable: {archive_path}") from exc
    with archive_context as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if names != list(expected):
            raise PackageError("archive entries do not exactly match the manifest files")
        try:
            if archive.testzip() is not None:
                raise PackageError("archive CRC check failed")
        except (OSError, zipfile.BadZipFile) as exc:
            raise PackageError("archive CRC check failed") from exc
        for info in infos:
            if info.is_dir():
                raise PackageError(f"archive contains a directory entry: {info.filename}")
            if info.create_system != ZIP_CREATE_SYSTEM:
                raise PackageError(f"archive entry has the wrong creator system: {info.filename}")
            if info.date_time != ZIP_DATE_TIME:
                raise PackageError(f"archive entry has a non-deterministic timestamp: {info.filename}")
            if (info.external_attr >> 16) != ZIP_FILE_MODE:
                raise PackageError(f"archive entry has the wrong mode: {info.filename}")
            if info.compress_type != zipfile.ZIP_DEFLATED:
                raise PackageError(f"archive entry is not DEFLATE: {info.filename}")
            if info.flag_bits & 0x1:
                raise PackageError(f"archive entry is encrypted: {info.filename}")
            if info.extra:
                raise PackageError(f"archive entry has extra metadata: {info.filename}")
            data = archive.read(info)
            size, digest = expected[info.filename]
            if len(data) != size or sha256_bytes(data) != digest:
                raise PackageError(f"archive bytes do not match the manifest: {info.filename}")
        if any(name.startswith(("Mods/", "ShaderFixes/", "ShaderCache/")) for name in names):
            raise PackageError("archive contains personal mods, shader fixes or caches")
        if any(name.endswith((".log", ".dmp")) or name == "payload/d3dx_user.ini" for name in names):
            raise PackageError("archive contains logs, dumps or user profile state")
        if D3DX_INI_PATH not in names:
            raise PackageError("archive is missing payload/d3dx.ini")
        ini = archive.read(D3DX_INI_PATH).decode("utf-8")
        sections = _parse_ini(ini.split("\n"))
        if _section_value(sections, "loader", "target").casefold() != target_exe.casefold():
            raise PackageError(f"packaged d3dx.ini does not target {target_exe}")
        if _section_value(sections, "loader", "loader").casefold() != "hook-runner.exe":
            raise PackageError("packaged d3dx.ini does not target hook-runner.exe")
        if any(
            name == "launch" and value
            for _, name, value in sections.get("loader", [])
        ):
            raise PackageError("packaged d3dx.ini must not contain an active launch path")
        if _section_value(sections, "system", "proxy_d3d11") != "":
            raise PackageError("packaged d3dx.ini proxy_d3d11 must be neutral/empty")
        calls = _optional_section_value(sections, "logging", "calls")
        debug = _optional_section_value(sections, "logging", "debug")
        log_level = _optional_section_value(sections, "logging", "log_level")
        if calls is not None and calls != "0":
            raise PackageError("packaged d3dx.ini must not enable PoC API logging")
        if debug is not None and debug != "0":
            raise PackageError("packaged d3dx.ini must not enable debug logging")
        if log_level is not None and log_level.casefold() != "none":
            raise PackageError("packaged d3dx.ini must disable log_level logging")
        if calls is None and log_level is None:
            raise PackageError("packaged d3dx.ini has no disabled logging switch")
        if pins is not None:
            _verify_zzmi_archive(pins, archive, names)
            verified = pins["verifiedBinaries"]
            for label, archive_name, entry, is_dll in (
                ("runner", manifest["runnerPath"], verified["runner"], False),
                ("injector", manifest["injectorPath"], verified["injector"], True),
                ("payload", manifest["payloadPath"], verified["payload"], True),
                ("d3dcompiler", "payload/d3dcompiler_47.dll", verified["d3dcompiler"], True),
            ):
                if archive_name not in expected:
                    raise PackageError(
                        f"archive is missing the pinned {label}: {archive_name}"
                    )
                data = archive.read(archive_name)
                info = pe_info(data)
                if info["machine"] != 0x8664 or info["is_dll"] != is_dll:
                    raise PackageError(f"packaged {label} is not an x86-64 PE")
                if sha256_bytes(data) != entry.get("sha256"):
                    raise PackageError(
                        f"packaged {label} SHA-256 does not match the pin"
                    )
                if len(data) != entry.get("size", 0):
                    raise PackageError(
                        f"packaged {label} size does not match the pin"
                    )
                if label == "payload":
                    verify_payload_resources(data, entry, "packaged payload")
            shader_path = f"payload/{_package_shader_path(pins['package'])}"
            if shader_path not in expected:
                raise PackageError(f"archive is missing declared shader: {shader_path}")
            if sha256_bytes(archive.read(shader_path)) != pins["verifiedBinaries"]["textPrinterShader"]["sha256"]:
                raise PackageError("packaged TextPrinter shader does not match the pin")
            config = pins["verifiedBinaries"].get("config")
            if isinstance(config, dict):
                for name, entry in config.items():
                    relative = _safe_package_relative(
                        entry.get("path"), f"config entry {name}"
                    )
                    if relative == "d3dx.ini":
                        continue
                    archive_name = f"payload/{relative}"
                    if archive_name not in expected:
                        raise PackageError(f"archive is missing pinned config file: {relative}")
                    if sha256_bytes(archive.read(archive_name)) != entry.get("sha256"):
                        raise PackageError(
                            f"packaged config file does not match the pin: {relative}"
                        )
            if pins["package"].get("gameID") == "zzz":
                mapping = _runtime_file_pins(pins)
                expected_payload = set(mapping) | ZZZ_RUNTIME_BINARY_FILES
                expected_names = {
                    manifest["runnerPath"],
                    manifest["injectorPath"],
                } | {f"payload/{relative}" for relative in expected_payload}
                actual_names = set(names)
                missing = expected_names - actual_names
                unexpected = actual_names - expected_names
                if missing or unexpected:
                    details = []
                    if missing:
                        details.append("missing " + ", ".join(sorted(missing)))
                    if unexpected:
                        details.append("unexpected " + ", ".join(sorted(unexpected)))
                    raise PackageError(
                        "archive does not match the authenticated ZZMI runtime file set: "
                        + "; ".join(details)
                    )
                _, normalized_size, normalized_digest = _normalized_d3dx_pin(pins)
                for relative, (size, digest) in mapping.items():
                    data = archive.read(f"payload/{relative}")
                    if relative == D3DX_INI_RELATIVE:
                        if len(data) != normalized_size or sha256_bytes(data) != normalized_digest:
                            raise PackageError(
                                "packaged d3dx.ini does not match the exact normalized hash"
                            )
                        continue
                    if len(data) != size or sha256_bytes(data) != digest:
                        raise PackageError(
                            f"packaged authenticated runtime file does not match the pin: {relative}"
                        )
        injector_name = manifest.get("injectorPath")
        if not isinstance(injector_name, str) or injector_name not in expected:
            raise PackageError("manifest injectorPath is not a declared file")
        injector_data = archive.read(injector_name)
        info = pe_info(injector_data)
        if info["machine"] != 0x8664 or not info["is_dll"]:
            raise PackageError("packaged injector is not an x86-64 DLL")
        required = set(
            pins["verifiedBinaries"]["injector"].get("requiredExports", [])
            if pins
            else ["DllMain", "HookLibrary", "Inject", "StartProcess", "UnhookLibrary", "WaitForInjection"]
        )
        packaged_exports = set(pe_exports(injector_data))
        missing = required - packaged_exports
        if missing:
            raise PackageError("packaged injector is missing exports: " + ", ".join(sorted(missing)))
        expected_exports = (
            pins["verifiedBinaries"]["injector"].get("expectedExports") if pins else None
        )
        if isinstance(expected_exports, list) and set(expected_exports) != packaged_exports:
            raise PackageError(
                "packaged injector exports do not exactly match the verified core API: "
                + ", ".join(sorted(packaged_exports))
            )
    archive_size = archive_path.stat().st_size
    if manifest.get("archiveSize") != archive_size:
        raise PackageError("manifest archiveSize does not match the archive")
    if manifest.get("archiveSHA256") != sha256_file(archive_path):
        raise PackageError("manifest archiveSHA256 does not match the archive")


def _validate_manifest_header(manifest: dict[str, Any], pins: dict[str, Any] | None) -> None:
    expected = {
        "schemaVersion": SCHEMA_VERSION,
        "id": "hsr-srmi",
        "gameID": "starrail",
        "runnerPath": "hook-runner.exe",
        "injectorPath": "3dmloader.dll",
        "payloadPath": "payload/d3d11.dll",
        "license": "GPL-3.0-only",
    }
    if pins:
        package = pins["package"]
        expected.update(
            {
                "id": package["id"],
                "version": package["version"],
                "gameID": package["gameID"],
                "runnerPath": package["runnerPath"],
                "injectorPath": package["injectorPath"],
                "payloadPath": package["payloadPath"],
                "license": package["license"],
            }
        )
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise PackageError(f"manifest {key} is {manifest.get(key)!r}, expected {value!r}")
    if not isinstance(manifest.get("version"), str) or not manifest["version"]:
        raise PackageError("manifest version must be a non-empty string")
    runtime_ids = manifest.get("supportedRuntimeBundleIDs")
    if pins:
        expected_runtime = list(pins["package"]["supportedRuntimeBundleIDs"])
    else:
        expected_runtime = ["d3dmetal-wine11.20-gptk4.0b3"]
    if runtime_ids != expected_runtime:
        raise PackageError("manifest supportedRuntimeBundleIDs does not match the approved runtime")
    if not isinstance(manifest.get("sources"), dict) or not manifest["sources"]:
        raise PackageError("manifest sources must be a non-empty dictionary")
    if not all(isinstance(key, str) and isinstance(value, str)
               for key, value in manifest["sources"].items()):
        raise PackageError("manifest source pins must be strings")
    if pins is not None and manifest["sources"] != _expected_manifest_sources(pins):
        raise PackageError("manifest sources do not match the pinned provenance")
    if not isinstance(manifest.get("archiveSize"), int) or manifest["archiveSize"] <= 0:
        raise PackageError("manifest archiveSize must be a positive Int64")
    if manifest["archiveSize"] > 2**63 - 1:
        raise PackageError("manifest archiveSize is outside Int64")
    if not isinstance(manifest.get("archiveSHA256"), str) or not re.fullmatch(
        r"[0-9a-f]{64}", manifest["archiveSHA256"]
    ):
        raise PackageError("manifest archiveSHA256 is invalid")


def build_package(
    *,
    runner: Path,
    injector: Path,
    payload_dir: Path,
    output_dir: Path,
    pins_path: Path,
    d3dx_ini: Path | None = None,
    d3dcompiler: Path | None = None,
) -> dict[str, Any]:
    pins = _load_pins(pins_path)
    pins["_pins_path"] = str(pins_path)
    package = pins["package"]
    target_exe = _package_target(package)
    shader_path = _package_shader_path(package)
    allowed_root_dirs = _package_payload_root_dirs(package)
    for name in (package["runnerPath"], package["injectorPath"], package["payloadPath"]):
        _safe_archive_path(name)
    d3dx_ini = d3dx_ini or payload_dir / "d3dx.ini"
    d3dcompiler = d3dcompiler or payload_dir / "d3dcompiler_47.dll"
    payload_files = collect_payload_files(
        payload_dir, allowed_root_dirs=allowed_root_dirs
    )
    payload_files["d3dx.ini"] = d3dx_ini
    payload_files["d3dcompiler_47.dll"] = d3dcompiler
    pins["_runner"] = str(runner)
    pins["_injector"] = str(injector)
    _verify_verified_inputs(pins, payload_files, shader_path=shader_path)
    files: dict[str, bytes] = {
        package["runnerPath"]: _regular_file(runner, "runner").read_bytes(),
        package["injectorPath"]: _regular_file(injector, "injector").read_bytes(),
    }
    for relative, path in payload_files.items():
        _regular_file(path, relative)
        data = (
            normalize_d3dx_ini(path, target_exe=target_exe)
            if relative == "d3dx.ini"
            else path.read_bytes()
        )
        files[f"payload/{relative}"] = data
    names = set(files)
    if len(names) != len(files):
        raise PackageError("package paths collide")
    if len({name.casefold() for name in names}) != len(names):
        raise PackageError("package paths have a case-insensitive collision")
    if not names <= set().union(
        {package["runnerPath"], package["injectorPath"], package["payloadPath"]},
        {f"payload/{name}" for name in payload_files},
    ):
        raise PackageError("package contains an unexpected path")
    for name in names:
        _safe_archive_path(name)
    output_dir = output_dir.resolve()
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    if output_dir.exists() and not output_dir.is_dir():
        raise PackageError(f"package output is not a directory: {output_dir}")
    created_output = not output_dir.exists()
    staging = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.tmp-", dir=output_dir.parent))
    backup = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.backup-", dir=output_dir.parent))
    package_names = (package["archiveName"], package["manifestName"])
    moved: list[str] = []
    try:
        archive_path = staging / package["archiveName"]
        _write_zip(archive_path, files)
        initial = _build_manifest(pins, files, 0, "0" * 64)
        initial["archiveSize"] = archive_path.stat().st_size
        initial["archiveSHA256"] = sha256_file(archive_path)
        (staging / package["manifestName"]).write_text(
            json.dumps(initial, indent=2) + "\n", encoding="utf-8"
        )
        verify_package(staging, pins_path=pins_path)
        existing_manifest = output_dir / package["manifestName"]
        if existing_manifest.exists() and not existing_manifest.is_symlink():
            existing = _load_json(existing_manifest, "existing package manifest")
            existing_id = existing.get("id")
            if not isinstance(existing_id, str) or not existing_id:
                raise PackageError(
                    f"existing package manifest has no package id: {existing_manifest}"
                )
            if existing_id != package["id"]:
                raise PackageError(
                    "package output already contains a different package: "
                    f"{existing_id}"
                )
        if created_output:
            output_dir.mkdir(parents=True)
        try:
            for name in package_names:
                destination = output_dir / name
                if destination.is_symlink() or (destination.exists() and not destination.is_file()):
                    raise PackageError(
                        f"package output entry is not a regular file: {destination}"
                    )
                if destination.exists():
                    os.replace(destination, backup / name)
                    moved.append(name)
                os.replace(staging / name, destination)
            return verify_package(output_dir, pins_path=pins_path)
        except Exception:
            for name in package_names:
                destination = output_dir / name
                if destination.exists() and not destination.is_symlink():
                    destination.unlink()
            for name in moved:
                os.replace(backup / name, output_dir / name)
            if created_output and output_dir.is_dir() and not any(output_dir.iterdir()):
                output_dir.rmdir()
            raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        shutil.rmtree(backup, ignore_errors=True)


def verify_package(directory: Path, *, pins_path: Path | None = None) -> dict[str, Any]:
    pins = _load_pins(pins_path) if pins_path else None
    if pins is not None and pins_path is not None:
        pins["_pins_path"] = str(pins_path)
        _verify_core_compatibility(pins, pins_path)
    directory = directory.resolve()
    manifest_name = pins["package"]["manifestName"] if pins else "manifest.json"
    archive_name = pins["package"]["archiveName"] if pins else "hsr-srmi.zip"
    manifest = _load_json(directory / manifest_name, "package manifest")
    _validate_manifest_header(manifest, pins)
    _validate_archive(directory / archive_name, manifest, pins)
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build", help="build the deterministic package")
    build.add_argument("--runner", type=Path, required=True)
    build.add_argument("--injector", type=Path, required=True)
    build.add_argument("--payload-dir", type=Path, required=True)
    build.add_argument("--output-dir", type=Path, required=True)
    build.add_argument("--pins", type=Path, default=Path("compat/xxmi/source-pins.json"))
    build.add_argument("--d3dx-ini", type=Path)
    build.add_argument("--d3dcompiler", type=Path)
    build.add_argument("--json", action="store_true", help="print the verified manifest as JSON")
    verify = subparsers.add_parser("verify", help="verify an existing package")
    verify.add_argument("--directory", type=Path, required=True)
    verify.add_argument("--pins", type=Path, default=Path("compat/xxmi/source-pins.json"))
    verify.add_argument("--json", action="store_true", help="print the verified manifest as JSON")
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            manifest = build_package(
                runner=args.runner,
                injector=args.injector,
                payload_dir=args.payload_dir,
                output_dir=args.output_dir,
                pins_path=args.pins,
                d3dx_ini=args.d3dx_ini,
                d3dcompiler=args.d3dcompiler,
            )
            output = args.output_dir.resolve()
        else:
            manifest = verify_package(args.directory, pins_path=args.pins)
            output = args.directory.resolve()
    except PackageError as exc:
        print(f"xxmi-package: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(manifest, indent=2))
    else:
        print(f"package: {output}")
        print(f"id: {manifest['id']}")
        print(f"version: {manifest['version']}")
        print(f"archive: {manifest.get('archiveSize')} bytes SHA-256 {manifest.get('archiveSHA256')}")
        print(f"files: {len(manifest['files'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
