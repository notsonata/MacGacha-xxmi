#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Build or verify the offline HSR XXMI resource package.

The package is a deterministic ZIP plus an external schema-version-1 manifest.
It contains only the verified runner, injector, SRMI payload, runtime
configuration and shader files. User mods, logs, caches, profile state and PoC
diagnostics are rejected rather than silently packaged.
"""

from __future__ import annotations

import argparse
import hashlib
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
REQUIRED_PAYLOAD_ROOT_FILES = {"d3d11.dll", "d3dcompiler_47.dll", "d3dx.ini"}
ALLOWED_PAYLOAD_ROOT_DIRS = {"Core"}
IGNORED_PAYLOAD_ROOT_NAMES = {
    "Mods",
    "ShaderCache",
    "ShaderFixes",
    "d3dx_user.ini",
    "d3d11_log.txt",
    ".DS_Store",
}
IGNORED_PAYLOAD_FILE_NAMES = {".DS_Store"}
TEXT_PRINTER_PATH = "payload/Core/SRMI/Shaders/TextPrinter.hlsl"
D3DCOMPILER_PATH = "payload/d3dcompiler_47.dll"
D3DX_INI_PATH = "payload/d3dx.ini"
FORBIDDEN_SOURCE_PATHS = ("/Users/", "Z:\\Users\\", "C:\\Users\\", "\\\\Users\\\\")


class PackageError(RuntimeError):
    """Expected, user-facing package failure."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


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


def normalize_d3dx_ini(path: Path) -> bytes:
    _regular_file(path, "d3dx.ini")
    try:
        text = path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError as exc:
        raise PackageError("d3dx.ini is not UTF-8") from exc
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    sections = _parse_ini(lines)
    if _section_value(sections, "loader", "target").casefold() != "starrail.exe":
        raise PackageError("d3dx.ini [Loader] target must be StarRail.exe")
    if _section_value(sections, "loader", "loader").casefold() != "hook-runner.exe":
        raise PackageError("d3dx.ini [Loader] loader must be hook-runner.exe")
    if _section_value(sections, "loader", "module").casefold() != "d3d11.dll":
        raise PackageError("d3dx.ini [Loader] module must be d3d11.dll")
    _section_value(sections, "system", "proxy_d3d11")
    proxy_lines = [
        index
        for index, name, _ in sections.get("system", [])
        if name == "proxy_d3d11"
    ]
    if len(proxy_lines) != 1:
        raise PackageError("d3dx.ini [System] requires one proxy_d3d11 entry")
    lines[proxy_lines[0]] = "proxy_d3d11 ="
    if "logging" not in sections:
        raise PackageError("d3dx.ini is missing the [Logging] section")
    for key in ("calls", "debug", "unbuffered"):
        _replace_section_value(lines, sections, "logging", key, "0")
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


def collect_payload_files(payload_dir: Path) -> dict[str, Path]:
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
        if name in IGNORED_PAYLOAD_ROOT_NAMES:
            continue
        if entry.is_symlink():
            raise PackageError(f"payload root contains a symlink: {name}")
        if entry.is_dir():
            if name not in ALLOWED_PAYLOAD_ROOT_DIRS:
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
        if name not in REQUIRED_PAYLOAD_ROOT_FILES:
            raise PackageError(
                "payload root contains an unexpected file; refusing to package user data: "
                + name
            )
        files[name] = entry
    missing = REQUIRED_PAYLOAD_ROOT_FILES - set(files)
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
    return pins


def _verify_verified_inputs(pins: dict[str, Any], payload_files: dict[str, Path]) -> None:
    verified = pins["verifiedBinaries"]
    for key in ("runner", "injector", "payload", "d3dcompiler", "textPrinterShader"):
        entry = verified.get(key)
        if not isinstance(entry, dict) or not isinstance(entry.get("sha256"), str):
            raise PackageError(f"source pins verifiedBinaries.{key} is missing its SHA-256")
    runner = verified["runner"]
    injector = verified["injector"]
    if sha256_file(Path(pins["_runner"])) != runner["sha256"]:
        raise PackageError("runner SHA-256 does not match the pinned verified runner")
    if Path(pins["_runner"]).stat().st_size != runner.get("size", 0):
        raise PackageError("runner size does not match the pinned verified runner")
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
    compiler_data = verify_pe(payload_files["d3dcompiler_47.dll"], dll=True, label="d3dcompiler_47.dll")
    if sha256_bytes(compiler_data) != verified["d3dcompiler"]["sha256"]:
        raise PackageError("d3dcompiler_47.dll SHA-256 does not match the pinned dependency")
    shader_path = payload_files.get("Core/SRMI/Shaders/TextPrinter.hlsl")
    if shader_path is None:
        raise PackageError("payload is missing Core/SRMI/Shaders/TextPrinter.hlsl")
    if sha256_file(shader_path) != verified["textPrinterShader"]["sha256"]:
        raise PackageError("TextPrinter.hlsl SHA-256 does not match the numeric-literal baseline")


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
    sources = dict(pins["sources"])
    if isinstance(pins.get("build"), dict):
        sources["build"] = pins["build"]
    flattened: dict[str, str] = {}
    def flatten(prefix: str, value: Any) -> None:
        if isinstance(value, dict):
            for key in sorted(value):
                flatten(f"{prefix}.{key}" if prefix else key, value[key])
        elif isinstance(value, str):
            flattened[prefix] = value
        else:
            flattened[prefix] = json.dumps(value, sort_keys=True, separators=(",", ":"))
    flatten("", sources)
    sources = flattened
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
        if _section_value(sections, "loader", "target").casefold() != "starrail.exe":
            raise PackageError("packaged d3dx.ini does not target StarRail.exe")
        if _section_value(sections, "loader", "loader").casefold() != "hook-runner.exe":
            raise PackageError("packaged d3dx.ini does not target hook-runner.exe")
        if _section_value(sections, "system", "proxy_d3d11") != "":
            raise PackageError("packaged d3dx.ini proxy_d3d11 must be neutral/empty")
        if _section_value(sections, "logging", "calls") != "0":
            raise PackageError("packaged d3dx.ini must not enable PoC API logging")
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
    package = pins["package"]
    for name in (package["runnerPath"], package["injectorPath"], package["payloadPath"]):
        _safe_archive_path(name)
    d3dx_ini = d3dx_ini or payload_dir / "d3dx.ini"
    d3dcompiler = d3dcompiler or payload_dir / "d3dcompiler_47.dll"
    payload_files = collect_payload_files(payload_dir)
    payload_files["d3dx.ini"] = d3dx_ini
    payload_files["d3dcompiler_47.dll"] = d3dcompiler
    pins["_runner"] = str(runner)
    pins["_injector"] = str(injector)
    _verify_verified_inputs(pins, payload_files)
    files: dict[str, bytes] = {
        package["runnerPath"]: _regular_file(runner, "runner").read_bytes(),
        package["injectorPath"]: _regular_file(injector, "injector").read_bytes(),
    }
    for relative, path in payload_files.items():
        _regular_file(path, relative)
        data = normalize_d3dx_ini(path) if relative == "d3dx.ini" else path.read_bytes()
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
    staging = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.tmp-", dir=output_dir.parent))
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
        backup = None
        if output_dir.exists():
            if not output_dir.is_dir():
                raise PackageError(f"package output is not a directory: {output_dir}")
            unexpected = sorted(
                entry.name
                for entry in output_dir.iterdir()
                if entry.name not in {package["archiveName"], package["manifestName"]}
            )
            if unexpected:
                raise PackageError(
                    "package output directory contains unrelated entries: " + ", ".join(unexpected)
                )
            backup = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.old-", dir=output_dir.parent))
            backup.rmdir()
            os.replace(output_dir, backup)
        try:
            os.replace(staging, output_dir)
        except Exception:
            if backup is not None:
                os.replace(backup, output_dir)
            raise
        if backup is not None:
            shutil.rmtree(backup)
        return verify_package(output_dir, pins_path=pins_path)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def verify_package(directory: Path, *, pins_path: Path | None = None) -> dict[str, Any]:
    pins = _load_pins(pins_path) if pins_path else None
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
