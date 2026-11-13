#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Compile and verify the XXMI payload's DirectX11.rc resources.

``DirectX11/Overlay.cpp`` loads three embedded DirectXTK SPRITEFONT resources
(``IDR_COURIERBOLD``, ``IDR_ARIAL`` and ``IDR_COURIERSMALL``) with
``FindResource``. A payload linked without them has an empty PE resource
directory, ``LockResource`` returns NULL and the Overlay constructor throws.
This tool turns the pinned ``DirectX11/DirectX11.rc`` into a standard Windows
``.res`` container for ``lld-link`` and fail-closed verifies the linked DLL.

* ``describe`` authenticates the resource inputs against the pinned upstream
  source archive (by digest, without extracting it) and prints the plan's
  ``resources`` record: the ``.rc`` and header hashes, the font IDs read from
  ``version.h``, every font's SHA-256, size, git blob SHA-1 and SpriteFont
  structure, the VERSIONINFO values and the resulting ``.res`` digest.
* ``build`` compiles one stage tree's ``.rc`` into a ``.res`` and requires the
  plan's recorded digest.
* ``verify`` checks that a linked DLL has a non-empty resource directory with
  exactly the planned entries, byte for byte, and that every font parses.

The ``.res`` writer is a dependency-free implementation of the documented
Microsoft resource-file and VS_VERSIONINFO layouts; no rc.exe, llvm-rc,
Windows executable or Wine is run, and nothing is downloaded.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PLAN = REPO_ROOT / "compat" / "xxmi" / "build" / "payload-build-plan.json"

RES_NAME = "DirectX11.res"
RES_LINK_LINE = "{BUILD}/" + RES_NAME

# rc.exe / llvm-rc default memory flags for user-defined and version resources.
DEFAULT_MEMORY_FLAGS = 0x0030  # MOVEABLE | PURE
RT_VERSION = 16
VS_FIXEDFILEINFO_SIGNATURE = 0xFEEF04BD

LANGUAGE_CONSTANTS = {
    "LANG_ENGLISH": 0x09,
    "SUBLANG_ENGLISH_US": 0x01,
    "LANG_GERMAN": 0x07,
    "SUBLANG_GERMAN_SWISS": 0x02,
}
# Windows SDK values for the symbolic constants the pinned version.h uses.
VERSION_CONSTANTS = {
    "VOS_NT_WINDOWS32": 0x00040004,
    "VFT_DLL": 0x00000002,
}

SPRITEFONT_MAGIC = b"DXTKfont"
SPRITEFONT_GLYPH_SIZE = 32
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


class ResourceError(RuntimeError):
    """Expected, user-facing resource failure."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob_sha1(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode("ascii") + data).hexdigest()


# ---------------------------------------------------------------------------
# .res container
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ResEntry:
    type: int | str
    name: int | str
    lang: int
    memflags: int
    data: bytes
    data_version: int = 0
    version: int = 0
    characteristics: int = 0


def _res_ident(value: int | str) -> bytes:
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ResourceError(f"unsupported resource identifier: {value!r}")
    if isinstance(value, int):
        if not 0 <= value <= 0xFFFF:
            raise ResourceError(f"resource ordinal out of range: {value}")
        return struct.pack("<HH", 0xFFFF, value)
    return (value.upper() + "\0").encode("utf-16-le")


def _pad4(length: int) -> int:
    return (4 - length % 4) % 4


def _null_entry() -> bytes:
    return struct.pack("<II", 0, 32) + _res_ident(0) + _res_ident(0) + struct.pack("<IHHII", 0, 0, 0, 0, 0)


def build_res(entries: Iterable[ResEntry]) -> bytes:
    """Serialise entries after the leading null resource that marks a .res."""
    output = bytearray(_null_entry())
    for entry in entries:
        header = bytearray(_res_ident(entry.type) + _res_ident(entry.name))
        header += b"\0" * _pad4(8 + len(header))
        header += struct.pack(
            "<IHHII", entry.data_version, entry.memflags, entry.lang,
            entry.version, entry.characteristics,
        )
        output += struct.pack("<II", len(entry.data), 8 + len(header))
        output += header + entry.data + b"\0" * _pad4(len(entry.data))
    return bytes(output)


def _read_res_ident(blob: bytes, offset: int, limit: int) -> tuple[int | str, int]:
    if offset + 2 > limit:
        raise ResourceError("truncated resource identifier")
    (flag,) = struct.unpack_from("<H", blob, offset)
    if flag == 0xFFFF:
        if offset + 4 > limit:
            raise ResourceError("truncated ordinal identifier")
        return struct.unpack_from("<H", blob, offset + 2)[0], offset + 4
    end = offset
    while True:
        if end + 2 > limit:
            raise ResourceError("unterminated string identifier")
        if blob[end:end + 2] == b"\0\0":
            return blob[offset:end].decode("utf-16-le"), end + 2
        end += 2


def parse_res(blob: bytes) -> list[ResEntry]:
    """Parse a .res container with strict bounds and alignment checks."""
    null = _null_entry()
    if len(blob) < len(null) or blob[:len(null)] != null:
        raise ResourceError("invalid .res null-entry signature")
    entries: list[ResEntry] = []
    offset = len(null)
    while offset < len(blob):
        if offset + 8 > len(blob):
            raise ResourceError("truncated resource header")
        data_size, header_size = struct.unpack_from("<II", blob, offset)
        header_end = offset + header_size
        if header_size < 32 or header_size % 4 or header_end > len(blob):
            raise ResourceError(f"invalid resource header size at {offset:#x}")
        rtype, cursor = _read_res_ident(blob, offset + 8, header_end)
        rname, cursor = _read_res_ident(blob, cursor, header_end)
        cursor += _pad4(cursor - offset)
        if cursor + 16 != header_end:
            raise ResourceError(f"resource header size mismatch at {offset:#x}")
        data_version, memflags, lang, version, characteristics = struct.unpack_from(
            "<IHHII", blob, cursor
        )
        data_end = header_end + data_size
        if data_end > len(blob):
            raise ResourceError("resource data exceeds file")
        entries.append(ResEntry(rtype, rname, lang, memflags, blob[header_end:data_end],
                                data_version, version, characteristics))
        offset = data_end + _pad4(data_size)
        if offset > len(blob):
            raise ResourceError("truncated resource alignment padding")
    return entries


# ---------------------------------------------------------------------------
# VS_VERSIONINFO
# ---------------------------------------------------------------------------


def _align4(data: bytes) -> bytes:
    return data + b"\0" * _pad4(len(data))


def _vblock(key: str, value: bytes = b"", *, wtype: int, value_length: int = 0,
            children: bytes = b"") -> bytes:
    body = _align4(struct.pack("<HHH", 0, value_length, wtype) + (key + "\0").encode("utf-16-le"))
    body = _align4(_align4(body + value) + children)
    if len(body) > 0xFFFF:
        raise ResourceError(f"version block too large: {key}")
    return struct.pack("<H", len(body)) + body[2:]


def build_version_info(
    strings: list[tuple[str, str]],
    *,
    string_table_key: str,
    translation: tuple[int, int],
    file_version: tuple[int, int, int, int],
    product_version: tuple[int, int, int, int],
    file_flags_mask: int,
    file_flags: int,
    file_os: int,
    file_type: int,
    file_subtype: int,
) -> bytes:
    def string_value(key: str, value: str) -> bytes:
        encoded = (value + "\0").encode("utf-16-le")
        return _vblock(key, encoded, wtype=1, value_length=len(encoded) // 2)

    table = _vblock(string_table_key, wtype=1,
                    children=b"".join(string_value(k, v) for k, v in strings))
    string_file_info = _vblock("StringFileInfo", wtype=1, children=table)
    var = _vblock("Translation", struct.pack("<HH", *translation), wtype=0, value_length=4)
    var_file_info = _vblock("VarFileInfo", wtype=1, children=var)
    fixed = struct.pack(
        "<13I", VS_FIXEDFILEINFO_SIGNATURE, 0x00010000,
        (file_version[0] << 16) | file_version[1], (file_version[2] << 16) | file_version[3],
        (product_version[0] << 16) | product_version[1],
        (product_version[2] << 16) | product_version[3],
        file_flags_mask, file_flags, file_os, file_type, file_subtype, 0, 0,
    )
    return _vblock("VS_VERSION_INFO", fixed, wtype=0, value_length=len(fixed),
                   children=string_file_info + var_file_info)


def parse_version_info(blob: bytes) -> dict[str, Any]:
    """Parse VS_VERSIONINFO into fixed info, strings and translation."""
    strings: dict[str, str] = {}
    result: dict[str, Any] = {"strings": strings}

    def read_key(offset: int, end: int) -> tuple[str, int]:
        cursor = offset
        while cursor + 2 <= end:
            if blob[cursor:cursor + 2] == b"\0\0":
                return blob[offset:cursor].decode("utf-16-le"), cursor + 2
            cursor += 2
        raise ResourceError("unterminated version-info key")

    def block(offset: int, depth: int) -> int:
        if offset + 6 > len(blob):
            raise ResourceError("truncated version block")
        length, value_length, wtype = struct.unpack_from("<HHH", blob, offset)
        end = offset + length
        if length < 6 or end > len(blob) or depth > 4:
            raise ResourceError(f"invalid version block at {offset:#x}")
        key, cursor = read_key(offset + 6, end)
        cursor += _pad4(cursor)
        if key == "VS_VERSION_INFO":
            if depth != 0 or value_length != 52 or cursor + 52 > end:
                raise ResourceError("VS_FIXEDFILEINFO has an unexpected size")
            fixed = struct.unpack_from("<13I", blob, cursor)
            if fixed[0] != VS_FIXEDFILEINFO_SIGNATURE:
                raise ResourceError("VS_FIXEDFILEINFO signature mismatch")
            result["fixed"] = list(fixed)
            cursor += 52
        elif key == "Translation":
            if value_length != 4 or cursor + 4 > end:
                raise ResourceError("invalid Translation value")
            result["translation"] = list(struct.unpack_from("<HH", blob, cursor))
            cursor += 4
        elif depth == 3 and wtype == 1:
            value_end = cursor + value_length * 2
            if value_end > end:
                raise ResourceError(f"version string {key} exceeds its block")
            strings[key] = blob[cursor:value_end].decode("utf-16-le").rstrip("\0")
            cursor = value_end
        elif depth == 2 and wtype == 1:
            result["stringTableKey"] = key
        cursor += _pad4(cursor)
        while cursor + 6 <= end:
            cursor = block(cursor, depth + 1)
            cursor += _pad4(cursor)
        return end

    if block(0, 0) != len(blob):
        raise ResourceError("version info has trailing bytes")
    if "fixed" not in result:
        raise ResourceError("version info has no VS_FIXEDFILEINFO")
    return result


# ---------------------------------------------------------------------------
# DirectXTK SpriteFont
# ---------------------------------------------------------------------------


def parse_spritefont(blob: bytes) -> dict[str, Any]:
    """Validate a DirectXTK MakeSpriteFont binary the way SpriteFont reads it."""
    if not blob.startswith(SPRITEFONT_MAGIC):
        raise ResourceError("spritefont magic mismatch")
    offset = len(SPRITEFONT_MAGIC)
    if offset + 4 > len(blob):
        raise ResourceError("spritefont truncated before glyph count")
    (glyph_count,) = struct.unpack_from("<I", blob, offset)
    offset += 4
    if glyph_count == 0 or glyph_count > 0x10000:
        raise ResourceError("spritefont glyph count is invalid")
    glyph_end = offset + glyph_count * SPRITEFONT_GLYPH_SIZE
    if glyph_end + 28 > len(blob):
        raise ResourceError("spritefont truncated in glyph or property table")
    characters = [struct.unpack_from("<I", blob, offset + i * SPRITEFONT_GLYPH_SIZE)[0]
                  for i in range(glyph_count)]
    if any(a >= b for a, b in zip(characters, characters[1:])):
        raise ResourceError("spritefont glyphs are not in ascending order")
    line_spacing, default_character = struct.unpack_from("<fI", blob, glyph_end)
    width, height, texture_format, stride, rows = struct.unpack_from("<5I", blob, glyph_end + 8)
    if 0 in (width, height, stride, rows):
        raise ResourceError("spritefont texture dimensions are invalid")
    texture_end = glyph_end + 28 + stride * rows
    if texture_end > len(blob):
        raise ResourceError("spritefont texture data is truncated")
    return {
        "glyphCount": glyph_count,
        "firstCharacter": characters[0],
        "lastCharacter": characters[-1],
        "lineSpacing": line_spacing,
        "defaultCharacter": default_character,
        "textureWidth": width,
        "textureHeight": height,
        "textureFormat": texture_format,
        "textureStride": stride,
        "textureRows": rows,
        "trailingBytes": len(blob) - texture_end,
    }


# ---------------------------------------------------------------------------
# PE resource directory (read only)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PeResource:
    type: int | str
    name: int | str
    lang: int | str
    data: bytes
    rva: int
    codepage: int


def _pe_layout(blob: bytes) -> tuple[tuple[int, int], list[tuple[int, int, int, int]]]:
    if len(blob) < 0x40 or blob[:2] != b"MZ":
        raise ResourceError("not a PE image (missing MZ)")
    pe = struct.unpack_from("<I", blob, 0x3C)[0]
    if pe + 24 > len(blob) or blob[pe:pe + 4] != b"PE\0\0":
        raise ResourceError("not a PE image (missing PE signature)")
    sections, optional_size = struct.unpack_from("<H", blob, pe + 6)[0], struct.unpack_from("<H", blob, pe + 20)[0]
    optional = pe + 24
    optional_end = optional + optional_size
    if optional_size < 2 or optional_end > len(blob):
        raise ResourceError("PE optional header exceeds declared or available bounds")
    magic = struct.unpack_from("<H", blob, optional)[0]
    if magic == 0x20B:
        directories, count_offset = optional + 112, optional + 108
    elif magic == 0x10B:
        directories, count_offset = optional + 96, optional + 92
    else:
        raise ResourceError(f"unsupported PE optional header magic {magic:#x}")
    if count_offset + 4 > optional_end or directories + 24 > optional_end:
        raise ResourceError("PE optional header is too short for the resource directory")
    directory_count = struct.unpack_from("<I", blob, count_offset)[0]
    if directory_count < 3:
        raise ResourceError("PE image has no resource data directory")
    if directories + directory_count * 8 > optional_end:
        raise ResourceError("PE data directories exceed the optional header bounds")
    directory = struct.unpack_from("<II", blob, directories + 16)
    table = optional + optional_size
    if table + sections * 40 > len(blob):
        raise ResourceError("PE section table exceeds file")
    layout = []
    for index in range(sections):
        virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from(
            "<IIII", blob, table + index * 40 + 8
        )
        layout.append((virtual_address, virtual_size, raw_pointer, raw_size))
    return directory, layout


def pe_resource_directory(blob: bytes) -> tuple[int, int]:
    return _pe_layout(blob)[0]


def parse_pe_resources(blob: bytes) -> list[PeResource]:
    (root_rva, root_size), sections = _pe_layout(blob)
    if root_rva == 0 or root_size == 0:
        return []

    def file_range(rva: int, size: int) -> int:
        if rva < root_rva or rva + size > root_rva + root_size:
            raise ResourceError("resource range exceeds the declared PE directory bounds")
        for va, _, raw, raw_size in sections:
            delta = rva - va
            if 0 <= delta and delta + size <= raw_size:
                if raw + delta + size > len(blob):
                    raise ResourceError("resource range exceeds file bounds")
                return raw + delta
        raise ResourceError("resource range is not file-backed")

    def data_range(rva: int, size: int) -> int:
        for va, _, raw, raw_size in sections:
            delta = rva - va
            if 0 <= delta and delta + size <= raw_size and raw + delta + size <= len(blob):
                return raw + delta
        raise ResourceError("resource payload is not file-backed")

    def name_of(value: int) -> int | str:
        if value & 0x80000000:
            offset = file_range(root_rva + (value & 0x7FFFFFFF), 2)
            length = struct.unpack_from("<H", blob, offset)[0]
            file_range(root_rva + (value & 0x7FFFFFFF), 2 + length * 2)
            try:
                return blob[offset + 2:offset + 2 + length * 2].decode("utf-16-le")
            except UnicodeDecodeError as error:
                raise ResourceError("invalid UTF-16 resource directory name") from error
        return value

    resources: list[PeResource] = []
    seen: set[tuple[Any, Any, Any]] = set()

    def walk(rva: int, path: list[int | str]) -> None:
        offset = file_range(rva, 16)
        named, ids = struct.unpack_from("<HH", blob, offset + 12)
        file_range(rva, 16 + (named + ids) * 8)
        previous = None
        for index in range(named + ids):
            name_value, target = struct.unpack_from("<II", blob, offset + 16 + index * 8)
            if bool(name_value & 0x80000000) != (index < named):
                raise ResourceError("resource directory named/ordinal partition is invalid")
            if index == named:
                previous = None
            name = name_of(name_value)
            # PE names sort case-sensitively by UTF-16 units, then numeric IDs.
            key = tuple(struct.unpack("<" + "H" * (len(name.encode("utf-16-le")) // 2),
                                      name.encode("utf-16-le"))) if isinstance(name, str) else name
            if previous is not None and key <= previous:
                if key == previous:
                    raise ResourceError("duplicate PE resource directory identifier")
                raise ResourceError("resource directory identifiers are not in ascending order")
            previous = key
            if target & 0x80000000:
                if len(path) >= 2:
                    raise ResourceError("unexpected PE resource tree depth")
                walk(root_rva + (target & 0x7FFFFFFF), path + [name])
                continue
            if len(path) != 2:
                raise ResourceError("unexpected PE resource tree depth")
            key = (path[0], path[1], name)
            if key in seen:
                raise ResourceError(f"duplicate PE resource key: {key!r}")
            seen.add(key)
            entry = file_range(root_rva + target, 16)
            data_rva, data_size, codepage, _ = struct.unpack_from("<IIII", blob, entry)
            start = data_range(data_rva, data_size)
            resources.append(PeResource(path[0], path[1], name, blob[start:start + data_size],
                                        data_rva, codepage))

    walk(root_rva, [])
    return resources


# ---------------------------------------------------------------------------
# DirectX11.rc and version.h
# ---------------------------------------------------------------------------


def _relative(value: str, label: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(p in ("", ".", "..") for p in path.parts):
        raise ResourceError(f"{label} must be a safe relative path: {value}")
    return path


def _read_pinned(root: Path, entry: dict[str, Any], label: str) -> bytes:
    path = root / _relative(entry["path"], label)
    if path.is_symlink() or not path.is_file():
        raise ResourceError(f"missing {label}: {path}")
    data = path.read_bytes()
    if sha256_bytes(data) != entry["sha256"]:
        raise ResourceError(f"{label} SHA-256 mismatch: {path}")
    if "size" in entry and len(data) != entry["size"]:
        raise ResourceError(f"{label} size mismatch: {path}")
    if "gitBlobSHA1" in entry and git_blob_sha1(data) != entry["gitBlobSHA1"]:
        raise ResourceError(f"{label} git blob SHA-1 mismatch: {path}")
    return data


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def parse_header_defines(*texts: str) -> dict[str, str]:
    """First definition wins, mirroring the #ifndef fallbacks in version.h."""
    defines: dict[str, str] = {}
    for text in texts:
        for line in _strip_comments(text.replace("\\\n", " ")).splitlines():
            match = re.match(r"\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)(?!\()\s*(.*?)\s*$", line)
            if match:
                defines.setdefault(match.group(1), match.group(2))
    return defines


def _language(primary: str, sub: str) -> int:
    try:
        return LANGUAGE_CONSTANTS[primary] | (LANGUAGE_CONSTANTS[sub] << 10)
    except KeyError as exc:
        raise ResourceError(f"unsupported .rc language constant: {exc}") from exc


def _rc_string(raw: str) -> str:
    match = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', raw.strip())
    if not match:
        raise ResourceError(f"unsupported .rc string literal: {raw!r}")
    escapes = {"0": "\0", "n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"'}
    return re.sub(r"\\(.)", lambda m: escapes.get(m.group(1), m.group(1)), match.group(1))


def parse_rc(text: str) -> dict[str, Any]:
    """Read the SPRITEFONT and VERSIONINFO statements from DirectX11.rc."""
    language: int | None = None
    fonts: list[dict[str, Any]] = []
    version: dict[str, Any] | None = None
    depth = 0
    for raw_line in _strip_comments(text).splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"LANGUAGE\s+([A-Z_0-9]+)\s*,\s*([A-Z_0-9]+)", line)
        if match:
            language = _language(match.group(1), match.group(2))
            continue
        match = re.fullmatch(r'(IDR_[A-Z0-9_]+)\s+SPRITEFONT\s+("(?:[^"\\]|\\.)*")', line)
        if match:
            if language is None:
                raise ResourceError("SPRITEFONT declared before any LANGUAGE statement")
            file_name = _rc_string(match.group(2)).replace("\\", "/")
            fonts.append({"macro": match.group(1), "file": file_name, "language": language})
            continue
        if re.fullmatch(r"VS_VERSION_INFO\s+VERSIONINFO", line):
            if version is not None:
                raise ResourceError("multiple VERSIONINFO statements")
            version = {"language": language, "fixed": {}, "values": [], "blocks": []}
            continue
        if version is None or "done" in version:
            continue
        if line == "BEGIN":
            depth += 1
            continue
        if line == "END":
            depth -= 1
            if depth == 0:
                version["done"] = True
            continue
        if depth == 0:
            parts = line.split(None, 1)
            if len(parts) != 2:
                raise ResourceError(f"cannot parse VERSIONINFO statement: {line!r}")
            version["fixed"][parts[0]] = parts[1].strip()
            continue
        match = re.fullmatch(r'BLOCK\s+"([^"]+)"', line)
        if match:
            version["blocks"].append(match.group(1))
            continue
        match = re.fullmatch(r'VALUE\s+"([^"]+)"\s*,\s*(.+)', line)
        if not match:
            raise ResourceError(f"cannot parse VERSIONINFO line: {line!r}")
        version["values"].append((match.group(1), match.group(2).strip()))
    if version is None or "done" not in version:
        raise ResourceError("DirectX11.rc has no complete VERSIONINFO statement")
    version.pop("done")
    return {"fonts": fonts, "version": version}


def _integer(expression: str, defines: dict[str, str], label: str, depth: int = 0) -> int:
    value = expression.strip()
    if depth > 8:
        raise ResourceError(f"macro recursion in {label}")
    if re.fullmatch(r"0[xX][0-9A-Fa-f]+[lL]?|\d+[lL]?", value):
        return int(value.rstrip("lL"), 0)
    if value in VERSION_CONSTANTS:
        return VERSION_CONSTANTS[value]
    if value in defines:
        return _integer(defines[value], defines, label, depth + 1)
    raise ResourceError(f"cannot resolve {label}: {expression!r}")


def _stringize(expression: str, defines: dict[str, str], label: str, depth: int = 0) -> str:
    """Expand adjacent literals, plain macros and STRINGIZE(VERSION_*)."""
    if depth > 8:
        raise ResourceError(f"macro recursion in {label}")
    result = []
    for token in re.findall(r'"(?:[^"\\]|\\.)*"|STRINGIZE\(\s*\w+\s*\)|\w+', expression):
        if token.startswith('"'):
            result.append(_rc_string(token))
        elif token.startswith("STRINGIZE("):
            name = token[len("STRINGIZE("):-1].strip()
            result.append(str(_integer(name, defines, label)))
        elif token in defines:
            result.append(_stringize(defines[token], defines, label, depth + 1))
        else:
            raise ResourceError(f"cannot resolve {label}: {token}")
    return "".join(result)


def _version_tuple(expression: str, defines: dict[str, str], label: str) -> tuple[int, int, int, int]:
    while expression.strip() in defines:
        expression = defines[expression.strip()]
    parts = [part.strip() for part in expression.split(",")]
    if len(parts) != 4:
        raise ResourceError(f"{label} must have four components")
    values = tuple(_integer(part, defines, label) for part in parts)
    if any(not 0 <= part <= 0xFFFF for part in values):
        raise ResourceError(f"{label} component out of range")
    return values  # type: ignore[return-value]


def _resource_inputs(source: Path, spec: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str]]:
    rc_data = _read_pinned(source, spec["script"], "resource script")
    header_texts = [
        _read_pinned(source, header, "resource header").decode("utf-8")
        for header in spec["headers"]
    ]
    parsed = parse_rc(rc_data.decode("utf-8"))
    # version.h includes version.generated.h first, so its values win.
    defines = parse_header_defines(*reversed(header_texts))
    return parsed, defines


def _font_entries(
    parsed: dict[str, Any], defines: dict[str, str], spec: dict[str, Any], assets: Path
) -> tuple[list[ResEntry], list[dict[str, Any]]]:
    script_dir = PurePosixPath(spec["script"]["path"]).parent
    declared = parsed["fonts"]
    planned = spec["fonts"]
    if [font["macro"] for font in declared] != [font["macro"] for font in planned]:
        raise ResourceError(
            "DirectX11.rc SPRITEFONT declarations differ from the plan: "
            + ", ".join(font["macro"] for font in declared)
        )
    type_id = _integer("SPRITEFONT", defines, "SPRITEFONT resource type")
    if type_id != spec["spriteFontType"]:
        raise ResourceError("SPRITEFONT resource type differs from the plan")
    entries, records = [], []
    for declaration, font in zip(declared, planned):
        resource_id = _integer(declaration["macro"], defines, declaration["macro"])
        if resource_id != font["id"]:
            raise ResourceError(f"{declaration['macro']} resource ID differs from the plan")
        if declaration["language"] != font["language"]:
            raise ResourceError(f"{declaration['macro']} language differs from the plan")
        parts: list[str] = []
        for part in (script_dir / declaration["file"]).parts:
            if part == "..":
                if not parts:
                    raise ResourceError(f"{declaration['macro']} file escapes the source tree")
                parts.pop()
            elif part != ".":
                parts.append(part)
        if "/".join(parts) != font["path"]:
            raise ResourceError(f"{declaration['macro']} file differs from the plan: {declaration['file']}")
        data = _read_pinned(assets, font, f"{declaration['macro']} font")
        structure = parse_spritefont(data)
        if structure["glyphCount"] != font["glyphCount"]:
            raise ResourceError(f"{declaration['macro']} glyph count differs from the plan")
        entries.append(ResEntry(type_id, resource_id, font["language"], DEFAULT_MEMORY_FLAGS, data))
        records.append({"macro": font["macro"], "id": resource_id, "sha256": sha256_bytes(data),
                        "size": len(data), "spritefont": structure})
    return entries, records


def _version_entry(parsed: dict[str, Any], defines: dict[str, str], spec: dict[str, Any]) -> tuple[ResEntry, dict[str, Any]]:
    version = parsed["version"]
    planned = spec["version"]
    if version["language"] != planned["language"]:
        raise ResourceError("VERSIONINFO language differs from the plan")
    fixed = version["fixed"]
    for key in ("FILEVERSION", "PRODUCTVERSION", "FILEFLAGSMASK", "FILEFLAGS", "FILEOS",
                "FILETYPE", "FILESUBTYPE"):
        if key not in fixed:
            raise ResourceError(f"VERSIONINFO is missing {key}")
    # version.h selects VER_VER_DEBUG=0 outside _DEBUG; a release build never
    # defines _DEBUG, so VS_FF_DEBUG is not set.
    release_defines = dict(defines)
    release_defines["VER_VER_DEBUG"] = "0"
    file_version = _version_tuple(fixed["FILEVERSION"], release_defines, "FILEVERSION")
    product_version = _version_tuple(fixed["PRODUCTVERSION"], release_defines, "PRODUCTVERSION")
    numbers = {key: _integer(fixed[key], release_defines, key)
               for key in ("FILEFLAGSMASK", "FILEFLAGS", "FILEOS", "FILETYPE", "FILESUBTYPE")}
    translation: tuple[int, int] | None = None
    strings: list[tuple[str, str]] = []
    for key, raw in version["values"]:
        if key == "Translation":
            values = [_integer(part, release_defines, "Translation") for part in raw.split(",")]
            if len(values) != 2:
                raise ResourceError("Translation must have two values")
            translation = (values[0], values[1])
        else:
            # The literal's explicit trailing "\0" is the value terminator.
            strings.append((key, _stringize(raw, release_defines, key).rstrip("\0")))
    tables = [block for block in version["blocks"] if re.fullmatch(r"[0-9A-Fa-f]{8}", block)]
    if translation is None or len(tables) != 1:
        raise ResourceError("VERSIONINFO needs one string table and a Translation")
    if dict(strings) != planned["strings"] or list(file_version) != planned["fileVersion"]:
        raise ResourceError("VERSIONINFO values differ from the plan")
    blob = build_version_info(
        strings, string_table_key=tables[0], translation=translation,
        file_version=file_version, product_version=product_version,
        file_flags_mask=numbers["FILEFLAGSMASK"], file_flags=numbers["FILEFLAGS"],
        file_os=numbers["FILEOS"], file_type=numbers["FILETYPE"],
        file_subtype=numbers["FILESUBTYPE"],
    )
    round_trip = parse_version_info(blob)
    if round_trip["strings"] != dict(strings):
        raise ResourceError("VERSIONINFO round-trip mismatch")
    record = {
        "type": RT_VERSION,
        "name": 1,
        "language": planned["language"],
        "fileVersion": list(file_version),
        "productVersion": list(product_version),
        "stringTableKey": tables[0],
        "translation": list(translation),
        "fixed": numbers,
        "strings": dict(strings),
        "sha256": sha256_bytes(blob),
        "size": len(blob),
    }
    return ResEntry(RT_VERSION, 1, planned["language"], DEFAULT_MEMORY_FLAGS, blob), record


def _check_consumer(source: Path, spec: dict[str, Any]) -> None:
    consumer = spec.get("consumer")
    if consumer is None:
        return
    path = source / _relative(consumer["path"], "resource consumer")
    if not path.is_file():
        raise ResourceError(f"missing resource consumer: {path}")
    text = path.read_text(encoding="utf-8", errors="replace")
    for macro in consumer["macros"]:
        if f"MAKEINTRESOURCE({macro})" not in text:
            raise ResourceError(f"{consumer['path']} no longer loads {macro}")


def compile_resources(source: Path, assets: Path, spec: dict[str, Any]) -> tuple[bytes, dict[str, Any]]:
    """Compile one stage tree's DirectX11.rc; returns the .res and its record."""
    validate_spec(spec)
    _check_consumer(source, spec)
    parsed, defines = _resource_inputs(source, spec)
    font_entries, font_records = _font_entries(parsed, defines, spec, assets)
    version_entry, version_record = _version_entry(parsed, defines, spec)
    res = build_res(font_entries + [version_entry])
    entries = parse_res(res)
    if [(e.type, e.name, e.lang, e.data) for e in entries] != [
        (e.type, e.name, e.lang, e.data) for e in font_entries + [version_entry]
    ]:
        raise ResourceError("generated .res does not round-trip")
    return res, {
        "resSHA256": sha256_bytes(res),
        "resSize": len(res),
        "fonts": font_records,
        "version": version_record,
    }


def build_stage_resources(source: Path, assets: Path, spec: dict[str, Any], build: Path) -> Path:
    """Write ``build/DirectX11.res`` and require the plan's recorded digest."""
    res, record = compile_resources(source, assets, spec)
    if record["resSHA256"] != spec["res"]["sha256"] or record["resSize"] != spec["res"]["size"]:
        raise ResourceError(
            f"compiled {RES_NAME} does not match the plan: got {record['resSHA256']}"
        )
    if record["version"]["sha256"] != spec["version"]["sha256"]:
        raise ResourceError("compiled VERSIONINFO does not match the plan")
    build.mkdir(parents=True, exist_ok=True)
    output = build / RES_NAME
    if output.exists():
        raise ResourceError(f"refusing to reuse an existing resource object: {output}")
    output.write_bytes(res)
    return output


# ---------------------------------------------------------------------------
# Plan record and DLL verification
# ---------------------------------------------------------------------------


def validate_spec(spec: Any) -> None:
    if not isinstance(spec, dict):
        raise ResourceError("plan resources must be an object")
    for key in ("script", "headers", "spriteFontType", "fonts", "version", "res"):
        if key not in spec:
            raise ResourceError(f"plan resources is missing {key}")
    entries = [spec["script"], *spec["headers"], *spec["fonts"]]
    for entry in entries:
        if not isinstance(entry, dict) or not _HEX64.fullmatch(str(entry.get("sha256", ""))):
            raise ResourceError("plan resource input needs a path and SHA-256")
        _relative(str(entry.get("path", "")), "plan resource input")
    if not spec["fonts"]:
        raise ResourceError("plan resources must list the SPRITEFONT inputs")
    for font in spec["fonts"]:
        for key in ("macro", "id", "language", "size", "gitBlobSHA1", "glyphCount"):
            if key not in font:
                raise ResourceError(f"plan font is missing {key}")
    for key in ("sha256", "size"):
        if key not in spec["res"] or key not in spec["version"]:
            raise ResourceError(f"plan resources res/version is missing {key}")


def expected_dll_resources(spec: dict[str, Any]) -> list[dict[str, Any]]:
    expected = [
        {"type": spec["spriteFontType"], "name": font["id"], "language": font["language"],
         "size": font["size"], "sha256": font["sha256"], "kind": "spritefont",
         "label": font["macro"]}
        for font in spec["fonts"]
    ]
    expected.append({"type": RT_VERSION, "name": 1, "language": spec["version"]["language"],
                     "size": spec["version"]["size"], "sha256": spec["version"]["sha256"],
                     "kind": "version", "label": "VS_VERSION_INFO"})
    return expected


def verify_dll_resources(dll: bytes, expected: list[dict[str, Any]]) -> dict[str, Any]:
    """Fail closed unless the DLL holds exactly the expected resources."""
    root_rva, root_size = pe_resource_directory(dll)
    if root_rva == 0 or root_size == 0:
        raise ResourceError("PE resource directory is empty; the Overlay fonts are missing")
    resources = parse_pe_resources(dll)
    actual = {(r.type, r.name, r.lang): r for r in resources}
    wanted = {(e["type"], e["name"], e["language"]): e for e in expected}
    missing = sorted(map(str, set(wanted) - set(actual)))
    extra = sorted(map(str, set(actual) - set(wanted)))
    if missing:
        raise ResourceError("missing PE resources: " + ", ".join(missing))
    if extra:
        raise ResourceError("unexpected PE resources: " + ", ".join(extra))
    observed = []
    for key, item in wanted.items():
        resource = actual[key]
        label = item.get("label", str(key))
        if len(resource.data) != item["size"] or sha256_bytes(resource.data) != item["sha256"]:
            raise ResourceError(f"PE resource {label} bytes do not match the pin")
        record: dict[str, Any] = {"label": label, "type": key[0], "name": key[1],
                                  "language": key[2], "rva": resource.rva,
                                  "size": len(resource.data), "sha256": item["sha256"]}
        if item.get("kind") == "spritefont":
            record["spritefont"] = parse_spritefont(resource.data)
        elif item.get("kind") == "version":
            record["versionStrings"] = parse_version_info(resource.data)["strings"]
        observed.append(record)
    return {"directoryRVA": root_rva, "directorySize": root_size,
            "entryCount": len(resources), "entries": observed}


def describe(
    source: Path,
    assets: Path,
    *,
    archive: Path,
    archive_sha256: str,
    archive_url: str,
    commit: str,
    template: dict[str, Any],
) -> dict[str, Any]:
    """Authenticate the inputs against the upstream archive and emit the record."""
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != archive_sha256:
        raise ResourceError("upstream source archive SHA-256 does not match the pin")
    prefix = None
    members: dict[str, bytes] = {}
    wanted = {template["script"]["path"], *(h["path"] for h in template["headers"]),
              *(f["path"] for f in template["fonts"])}
    with tarfile.open(archive, "r:gz") as tar:
        for info in tar:
            parts = info.name.split("/", 1)
            if prefix is None:
                prefix = parts[0]
            if parts[0] != prefix or len(parts) != 2:
                continue
            if parts[1] in wanted and info.isfile():
                stream = tar.extractfile(info)
                assert stream is not None
                members[parts[1]] = stream.read()
    if prefix is None or not prefix.endswith(commit):
        raise ResourceError("upstream archive root does not name the pinned commit")
    spec = json.loads(json.dumps(template))
    for entry in [spec["script"], *spec["headers"]]:
        data = (source / _relative(entry["path"], "resource script")).read_bytes()
        if entry["path"] in members and members[entry["path"]] != data:
            raise ResourceError(f"{entry['path']} differs from the upstream archive")
        if entry["path"] not in members and data:
            raise ResourceError(f"{entry['path']} is not in the upstream archive")
        entry["sha256"] = sha256_bytes(data)
        entry["size"] = len(data)
        entry["gitBlobSHA1"] = git_blob_sha1(data)
    for font in spec["fonts"]:
        data = (assets / _relative(font["path"], "font")).read_bytes()
        if members.get(font["path"]) != data:
            raise ResourceError(f"{font['path']} differs from the upstream archive")
        font["sha256"] = sha256_bytes(data)
        font["size"] = len(data)
        font["gitBlobSHA1"] = git_blob_sha1(data)
        font["glyphCount"] = parse_spritefont(data)["glyphCount"]
        font["upstreamMember"] = f"{prefix}/{font['path']}"
    spec["authentication"] = {
        "sourceArchive": archive_url,
        "sourceArchiveSHA256": archive_sha256,
        "commit": commit,
        "rule": "Each SPRITEFONT input is byte-identical to the member of the pinned upstream source archive; the clean-tree rule omits the .spritefont suffix, so the fonts are supplied beside the generated assets and are not part of any pinned tree hash.",
    }
    parsed, defines = _resource_inputs(source, spec)
    _check_consumer(source, spec)
    for font in spec["fonts"]:
        font["id"] = _integer(font["macro"], defines, font["macro"])
    spec["spriteFontType"] = _integer("SPRITEFONT", defines, "SPRITEFONT")
    # Learn the VERSIONINFO values from the .rc, then compile_resources below
    # re-derives them independently and must agree.
    strings = {}
    release = dict(defines)
    release["VER_VER_DEBUG"] = "0"
    for key, raw in parsed["version"]["values"]:
        if key != "Translation":
            strings[key] = _stringize(raw, release, key).rstrip("\0")
    spec["version"]["strings"] = strings
    spec["version"]["fileVersion"] = list(
        _version_tuple(parsed["version"]["fixed"]["FILEVERSION"], release, "FILEVERSION")
    )
    spec["version"]["sha256"] = "0" * 64
    spec["version"]["size"] = 0
    spec["res"] = {"name": RES_NAME, "sha256": "0" * 64, "size": 0}
    res, compiled = compile_resources(source, assets, spec)
    spec["version"]["sha256"] = compiled["version"]["sha256"]
    spec["version"]["size"] = compiled["version"]["size"]
    spec["version"]["translation"] = compiled["version"]["translation"]
    spec["version"]["stringTableKey"] = compiled["version"]["stringTableKey"]
    spec["version"]["fixed"] = compiled["version"]["fixed"]
    for font, record in zip(spec["fonts"], compiled["fonts"]):
        font["spritefont"] = record["spritefont"]
    spec["res"] = {"name": RES_NAME, "sha256": sha256_bytes(res), "size": len(res)}
    return spec


DEFAULT_TEMPLATE: dict[str, Any] = {
    "tool": "scripts/xxmi-payload-resources.py",
    "script": {"path": "DirectX11/DirectX11.rc"},
    "headers": [{"path": "version.h"}, {"path": "version.generated.h"}],
    "consumer": {
        "path": "DirectX11/Overlay.cpp",
        "macros": ["IDR_COURIERBOLD", "IDR_ARIAL", "IDR_COURIERSMALL"],
    },
    "spriteFontType": 256,
    "fonts": [
        {"macro": "IDR_COURIERBOLD", "path": "courierbold.spritefont", "language": 0x0409},
        {"macro": "IDR_COURIERSMALL", "path": "couriersmall.spritefont", "language": 0x0409},
        {"macro": "IDR_ARIAL", "path": "arial.spritefont", "language": 0x0409},
    ],
    "version": {"language": 0x0807},
    "linkInput": RES_LINK_LINE,
}


def _load_plan_resources(path: Path) -> dict[str, Any]:
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ResourceError(f"cannot read build plan: {path}") from exc
    spec = plan.get("resources")
    validate_spec(spec)
    return spec


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    describe_parser = commands.add_parser("describe", help="authenticate inputs and print the plan record")
    describe_parser.add_argument("--source", type=Path, required=True, help="pinned clean or stage source tree")
    describe_parser.add_argument("--generated-assets", type=Path, required=True)
    describe_parser.add_argument("--upstream-archive", type=Path, required=True)
    describe_parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    build_parser = commands.add_parser("build", help="compile one stage's DirectX11.res")
    build_parser.add_argument("--source", type=Path, required=True)
    build_parser.add_argument("--generated-assets", type=Path, required=True)
    build_parser.add_argument("--output-dir", type=Path, required=True)
    build_parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    verify_parser = commands.add_parser("verify", help="verify a linked payload DLL")
    verify_parser.add_argument("dll", type=Path)
    verify_parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    args = parser.parse_args(argv)
    try:
        if args.command == "describe":
            plan = json.loads(args.plan.read_text(encoding="utf-8"))
            upstream = plan["provenance"]["upstream"]
            spec = describe(
                args.source, args.generated_assets, archive=args.upstream_archive,
                archive_sha256=upstream["sourceArchiveSHA256"],
                archive_url=upstream["sourceArchive"], commit=plan["sourcePin"]["commit"],
                template=plan.get("resources") or DEFAULT_TEMPLATE,
            )
            print(json.dumps(spec, indent=2))
        elif args.command == "build":
            output = build_stage_resources(args.source, args.generated_assets,
                                           _load_plan_resources(args.plan), args.output_dir)
            print(f"{output}: {sha256_bytes(output.read_bytes())}")
        else:
            spec = _load_plan_resources(args.plan)
            result = verify_dll_resources(args.dll.read_bytes(), expected_dll_resources(spec))
            print(json.dumps({"status": "PASS", "dllSHA256": sha256_bytes(args.dll.read_bytes()),
                              **result}, indent=2))
    except (ResourceError, OSError, KeyError, ValueError, tarfile.TarError) as exc:
        print(f"xxmi-payload-resources: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
