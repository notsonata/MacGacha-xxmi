# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Synthetic PE32+ DLL writer with an optional PE resource directory.

Used by the offline resource tests and by the fake linker fixture; it never
produces runnable code. ``resources`` is a list of (type, name, language, data)
integer-identified entries laid out the way lld-link writes ``.rsrc``.
"""

from __future__ import annotations

import struct

FILE_ALIGNMENT = 0x200
SECTION_ALIGNMENT = 0x1000


def _align(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def resource_section(resources: list[tuple[int, int, int, bytes]], rva: int) -> bytes:
    tree: dict[int, dict[int, dict[int, bytes]]] = {}
    for rtype, name, lang, data in resources:
        tree.setdefault(rtype, {}).setdefault(name, {})[lang] = data

    # Breadth-first layout: root, type directories, name directories, data entries.
    def directory_size(count: int) -> int:
        return 16 + 8 * count

    offset = directory_size(len(tree))
    type_offsets = {}
    for rtype in sorted(tree):
        type_offsets[rtype] = offset
        offset += directory_size(len(tree[rtype]))
    name_offsets = {}
    for rtype in sorted(tree):
        for name in sorted(tree[rtype]):
            name_offsets[(rtype, name)] = offset
            offset += directory_size(len(tree[rtype][name]))
    data_entries = {}
    for rtype in sorted(tree):
        for name in sorted(tree[rtype]):
            for lang in sorted(tree[rtype][name]):
                data_entries[(rtype, name, lang)] = offset
                offset += 16
    payload_offsets = {}
    for key in sorted(data_entries):
        offset = _align(offset, 8)
        payload_offsets[key] = offset
        offset += len(tree[key[0]][key[1]][key[2]])
    blob = bytearray(offset)

    def write_directory(at: int, entries: list[tuple[int, int, bool]]) -> None:
        struct.pack_into("<IIHHHH", blob, at, 0, 0, 0, 0, 0, len(entries))
        for index, (ident, target, is_dir) in enumerate(entries):
            struct.pack_into("<II", blob, at + 16 + index * 8, ident,
                             target | (0x80000000 if is_dir else 0))

    write_directory(0, [(t, type_offsets[t], True) for t in sorted(tree)])
    for rtype in sorted(tree):
        write_directory(type_offsets[rtype],
                        [(n, name_offsets[(rtype, n)], True) for n in sorted(tree[rtype])])
        for name in sorted(tree[rtype]):
            write_directory(name_offsets[(rtype, name)],
                            [(l, data_entries[(rtype, name, l)], False)
                             for l in sorted(tree[rtype][name])])
    for key, at in data_entries.items():
        data = tree[key[0]][key[1]][key[2]]
        struct.pack_into("<IIII", blob, at, rva + payload_offsets[key], len(data), 0, 0)
        blob[payload_offsets[key]:payload_offsets[key] + len(data)] = data
    return bytes(blob)


def build_dll(resources: list[tuple[int, int, int, bytes]] | None = None, text: bytes = b"\xc3") -> bytes:
    """Return a two-section PE32+ DLL (.text plus optional .rsrc)."""
    sections = [(b".text\0\0\0", text)]
    rsrc_rva = SECTION_ALIGNMENT * 2
    if resources:
        sections.append((b".rsrc\0\0\0", resource_section(resources, rsrc_rva)))
    headers = 0x40 + 4 + 20 + 240 + 40 * len(sections)
    raw = _align(headers, FILE_ALIGNMENT)
    image = bytearray(raw)
    image[:2] = b"MZ"
    struct.pack_into("<I", image, 0x3C, 0x40)
    image[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", image, 0x44, 0x8664, len(sections), 0, 0, 0, 240, 0x2022)
    optional = 0x58
    struct.pack_into("<H", image, optional, 0x20B)
    struct.pack_into("<I", image, optional + 32, SECTION_ALIGNMENT)
    struct.pack_into("<I", image, optional + 36, FILE_ALIGNMENT)
    struct.pack_into("<I", image, optional + 56, SECTION_ALIGNMENT * (len(sections) + 1))
    struct.pack_into("<I", image, optional + 60, raw)
    struct.pack_into("<I", image, optional + 108, 16)
    table = optional + 240
    pointer = raw
    for index, (name, data) in enumerate(sections):
        rva = SECTION_ALIGNMENT * (index + 1)
        size = _align(len(data), FILE_ALIGNMENT)
        entry = table + index * 40
        image[entry:entry + 8] = name
        struct.pack_into("<IIII", image, entry + 8, len(data), rva, size, pointer)
        if name.startswith(b".rsrc"):
            struct.pack_into("<II", image, optional + 112 + 16, rva, len(data))
        image += data + b"\0" * (size - len(data))
        pointer += size
    return bytes(image)
