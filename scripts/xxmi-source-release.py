#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Assemble the corresponding-source archive for the bundled SRMI payload.

The archive contains the original pinned XXMI Libraries source, the final
patched source reconstructed from the checked-in patch order, the generated
input the clean archive omits, the compatibility pins, patches, notices,
licenses and build plan, and the source rebuild/package/runner tools.

This command never downloads, installs, launches Wine, runs the game, edits a
clean or reference tree, or rebuilds the DLL. It only reads authenticated
inputs, reconstructs copies in a private staging directory and writes a
deterministic tar.gz plus its checksum.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import stat
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PLAN = REPO_ROOT / "compat" / "xxmi" / "build" / "payload-build-plan.json"
APP_REPOSITORY = "https://github.com/notsonata/MacGacha-xxmi"
ARCHIVE_SCHEMA_VERSION = 1
SAFE_VERSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
FORBIDDEN_NAMES = {".git", ".svn", ".hg", ".DS_Store", "__pycache__", "d3dx_user.ini"}
FORBIDDEN_DIRS = {"Mods", "ShaderCache", "ShaderFixes"}
FORBIDDEN_SUFFIXES = {".pyc", ".pyo", ".orig", ".rej", ".log", ".dmp", ".pdb", ".ilk"}

COMPAT_FILES = (
    "compat/xxmi/README.md",
    "compat/xxmi/NOTICE.md",
    "compat/xxmi/source-pins.json",
    "compat/xxmi/build/payload-build-plan.json",
    "compat/xxmi/runner/srmi_hook_launcher.c",
)
SCRIPT_FILES = (
    "scripts/xxmi-rebuild-payload.py",
    "scripts/xxmi-package.py",
    "scripts/xxmi-build-runner.sh",
    "scripts/xxmi-source-release.py",
)


class ReleaseError(RuntimeError):
    """Expected, user-facing archive-assembly failure."""


@dataclass(frozen=True)
class Entry:
    arcname: str
    mode: int
    source: Path | None = None
    data: bytes | None = None

    def sha256(self) -> str:
        if self.data is not None:
            return hashlib.sha256(self.data).hexdigest()
        assert self.source is not None
        return sha256_file(self.source)

    def size(self) -> int:
        if self.data is not None:
            return len(self.data)
        assert self.source is not None
        return self.source.stat().st_size


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _load_rebuild_module() -> Any:
    script = REPO_ROOT / "scripts" / "xxmi-rebuild-payload.py"
    spec = importlib.util.spec_from_file_location("xxmi_rebuild_payload", script)
    if spec is None or spec.loader is None:
        raise ReleaseError(f"cannot load rebuild helpers: {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


REBUILD = _load_rebuild_module()


def validate_version(value: str) -> str:
    if not SAFE_VERSION.fullmatch(value):
        raise ReleaseError(
            "--version must be a safe identifier matching "
            "[A-Za-z0-9][A-Za-z0-9._+-]{0,63}"
        )
    return value


def _relative_path(value: str, label: str) -> PurePosixPath:
    path = PurePosixPath(value.replace("\\", "/"))
    if path.is_absolute() or not path.parts:
        raise ReleaseError(f"{label} must be a relative path: {value}")
    if any(part in ("", ".", "..") for part in path.parts):
        raise ReleaseError(f"{label} contains an unsafe path component: {value}")
    return path


def _regular_file(path: Path, label: str) -> Path:
    try:
        info = path.lstat()
    except OSError as exc:
        raise ReleaseError(f"missing {label}: {path}") from exc
    if stat.S_ISLNK(info.st_mode):
        raise ReleaseError(f"{label} must not be a symlink: {path}")
    if not stat.S_ISREG(info.st_mode):
        raise ReleaseError(f"{label} must be a regular file: {path}")
    return path


def _forbidden(name: str) -> bool:
    return (
        name in FORBIDDEN_NAMES
        or name in FORBIDDEN_DIRS
        or Path(name).suffix.lower() in FORBIDDEN_SUFFIXES
    )


def scan_tree(root: Path, label: str) -> None:
    """Reject symlinks, special files and personal build artifacts."""
    if not root.is_dir():
        raise ReleaseError(f"missing {label}: {root}")
    if root.is_symlink():
        raise ReleaseError(f"{label} must not be a symlink: {root}")
    for current, dirnames, filenames in os.walk(root, followlinks=False):
        directory = Path(current)
        for name in list(dirnames):
            path = directory / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ReleaseError(f"{label} contains a symlink: {path}")
            if not stat.S_ISDIR(info.st_mode):
                raise ReleaseError(f"{label} contains a non-directory: {path}")
            if _forbidden(name):
                raise ReleaseError(f"{label} contains a forbidden directory: {path}")
        for name in filenames:
            path = directory / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ReleaseError(f"{label} contains a symlink: {path}")
            if not stat.S_ISREG(info.st_mode):
                raise ReleaseError(f"{label} contains a special file: {path}")
            if _forbidden(name):
                raise ReleaseError(f"{label} contains a forbidden file: {path}")


def _pin_tag(plan: dict[str, Any]) -> str:
    tag = str(plan["sourcePin"]["tag"])
    if not SAFE_NAME.fullmatch(tag):
        raise ReleaseError("source pin tag is not a safe file-name component")
    return tag


def _archive_source_name(plan: dict[str, Any]) -> str:
    repository = str(plan["sourcePin"]["repository"]).rstrip("/")
    repo_name = repository.rsplit("/", 1)[-1]
    commit = str(plan["sourcePin"]["commit"])
    name = f"{repo_name}-{commit}"
    if not SAFE_NAME.fullmatch(name):
        raise ReleaseError("source pin does not yield a safe archive directory name")
    return name


def validate_inputs(
    plan: dict[str, Any],
    *,
    source: Path,
    generated_assets: Path,
    third_party_objects: Path | None,
) -> list[dict[str, Any]]:
    """Validate every input and return the plan's third-party object entries."""
    scan_tree(source, "pinned clean source")
    if not generated_assets.is_dir() or generated_assets.is_symlink():
        raise ReleaseError(f"missing or symlinked generated-assets root: {generated_assets}")

    actual = REBUILD.tree_manifest(source)
    pin = plan["sourcePin"]
    if actual["fileCount"] != pin["cleanFileCount"]:
        raise ReleaseError(
            "clean source tree file count mismatch: "
            f"got {actual['fileCount']}, expected {pin['cleanFileCount']}"
        )
    if actual["sha256"] != pin["cleanTreeSHA256"]:
        raise ReleaseError(
            "clean source tree SHA-256 mismatch: "
            f"got {actual['sha256']}, expected {pin['cleanTreeSHA256']}"
        )

    for patch in plan["basePatches"]:
        path = _regular_file(REBUILD.resolve_plan_path(patch["path"]), "base patch")
        if sha256_file(path) != patch["sha256"]:
            raise ReleaseError(f"base patch SHA-256 mismatch: {path}")
    stage2_patch = plan["stage2"]["patch"]
    path = _regular_file(REBUILD.resolve_plan_path(stage2_patch["path"]), "stage2 patch")
    if sha256_file(path) != stage2_patch["sha256"]:
        raise ReleaseError(f"stage2 patch SHA-256 mismatch: {path}")
    for patch in plan.get("stage3", {}).get("patches", []):
        path = _regular_file(REBUILD.resolve_plan_path(patch["path"]), "stage3 patch")
        if sha256_file(path) != patch["sha256"]:
            raise ReleaseError(f"stage3 patch SHA-256 mismatch: {path}")
    shader_patch = plan["textPrinter"]["patch"]
    path = _regular_file(REBUILD.resolve_plan_path(shader_patch["path"]), "TextPrinter patch")
    if sha256_file(path) != shader_patch["sha256"]:
        raise ReleaseError(f"TextPrinter patch SHA-256 mismatch: {path}")

    for asset in plan["stage1"]["generatedAssets"]:
        relative = _relative_path(asset["path"], "generated asset")
        candidate = generated_assets / relative
        _regular_file(candidate, "generated asset")
        if sha256_file(candidate) != asset["sha256"]:
            raise ReleaseError(f"generated asset SHA-256 mismatch: {candidate}")
        in_source = source / relative
        if in_source.is_file() and sha256_file(in_source) != asset["sha256"]:
            raise ReleaseError(f"generated asset in source tree mismatches the plan: {in_source}")

    objects = plan["stage1"].get("thirdPartyObjects", [])
    if third_party_objects is not None:
        scan_tree(third_party_objects, "third-party object tree")
        for entry in objects:
            relative = _relative_path(entry["path"], "third-party object")
            path = _regular_file(third_party_objects / relative, "third-party object")
            if sha256_file(path) != entry["sha256"]:
                raise ReleaseError(f"third-party object SHA-256 mismatch: {path}")
    return objects


@dataclass(frozen=True)
class Reconstruction:
    stage1: Path
    stage1_manifest: dict[str, Any]
    stage2: Path
    stage2_manifest: dict[str, Any]
    final: Path
    final_manifest: dict[str, Any]
    stage3_present: bool


def reconstruct(
    plan: dict[str, Any],
    *,
    source: Path,
    generated_assets: Path,
    work: Path,
) -> Reconstruction:
    """Rebuild every patched source copy and verify every recorded tree hash."""
    log_dir = work / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    stage1 = work / "stage1" / "src"
    stage2 = work / "stage2" / "src"

    shutil.copytree(source, stage1)
    if REBUILD.tree_manifest(stage1)["sha256"] != plan["sourcePin"]["cleanTreeSHA256"]:
        raise ReleaseError("copied source tree does not match the clean source pin")
    for patch in plan["basePatches"]:
        REBUILD.apply_patch(stage1, REBUILD.resolve_plan_path(patch["path"]), log_dir)
    REBUILD.apply_compatibility_edits(stage1, plan["stage1"]["compatibilityEdits"])
    REBUILD.vendor_generated_assets(stage1, generated_assets, plan["stage1"]["generatedAssets"])
    stage1_manifest = REBUILD.tree_manifest(stage1)
    if stage1_manifest["sha256"] != plan["stage1"]["patchedTreeSHA256"]:
        raise ReleaseError(
            "stage 1 patched tree SHA-256 does not match the build plan: "
            f"got {stage1_manifest['sha256']}"
        )
    REBUILD.verify_source_hashes(stage1, plan["stage1"]["compile"], "stage1")

    shutil.copytree(stage1, stage2)
    REBUILD.apply_patch(stage2, REBUILD.resolve_plan_path(plan["stage2"]["patch"]["path"]), log_dir)
    stage2_manifest = REBUILD.tree_manifest(stage2)
    if stage2_manifest["sha256"] != plan["stage2"]["patchedTreeSHA256"]:
        raise ReleaseError(
            "stage 2 patched tree SHA-256 does not match the build plan: "
            f"got {stage2_manifest['sha256']}"
        )
    REBUILD.verify_source_hashes(stage2, plan["stage2"]["compile"], "stage2")

    stage3 = plan.get("stage3")
    if stage3 is None:
        return Reconstruction(
            stage1=stage1,
            stage1_manifest=stage1_manifest,
            stage2=stage2,
            stage2_manifest=stage2_manifest,
            final=stage2,
            final_manifest=stage2_manifest,
            stage3_present=False,
        )

    final = work / "stage3" / "src"
    shutil.copytree(stage2, final)
    for patch in stage3["patches"]:
        REBUILD.apply_patch(final, REBUILD.resolve_plan_path(patch["path"]), log_dir)
    final_manifest = REBUILD.tree_manifest(final)
    if final_manifest["sha256"] != stage3["patchedTreeSHA256"]:
        raise ReleaseError(
            "stage 3 patched tree SHA-256 does not match the build plan: "
            f"got {final_manifest['sha256']}"
        )
    REBUILD.verify_source_hashes(final, stage3["compile"], "stage3")
    return Reconstruction(
        stage1=stage1,
        stage1_manifest=stage1_manifest,
        stage2=stage2,
        stage2_manifest=stage2_manifest,
        final=final,
        final_manifest=final_manifest,
        stage3_present=True,
    )


def _iter_tree(root: Path, prefix: str) -> Iterable[Entry]:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            arcname = f"{prefix}/{relative}"
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            yield Entry(arcname=arcname, mode=mode, source=path)


def _selected_files(paths: Iterable[str]) -> Iterable[Entry]:
    for value in paths:
        path = REPO_ROOT / value
        _regular_file(path, value)
        mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
        yield Entry(arcname=value, mode=mode, source=path)


def _patch_files() -> Iterable[Entry]:
    directory = REPO_ROOT / "compat" / "xxmi" / "patches"
    for path in sorted(directory.iterdir(), key=lambda item: item.name):
        if path.suffix == ".patch":
            _regular_file(path, "compat patch")
            yield Entry(
                arcname=f"compat/xxmi/patches/{path.name}",
                mode=0o644,
                source=path,
            )


def _license_files() -> Iterable[Entry]:
    directory = REPO_ROOT / "compat" / "xxmi" / "licenses"
    for path in sorted(directory.iterdir(), key=lambda item: item.name):
        if path.is_file():
            _regular_file(path, "compat license")
            yield Entry(
                arcname=f"compat/xxmi/licenses/{path.name}",
                mode=0o644,
                source=path,
            )


def _readme(
    *,
    version: str,
    tag: str,
    plan: dict[str, Any],
    source_name: str,
    stage1: dict[str, Any],
    stage2: dict[str, Any],
    final: dict[str, Any],
    stage3_present: bool,
    included_objects: int,
) -> bytes:
    pin = plan["sourcePin"]
    objects_line = (
        "- `third-party-objects/`: the authenticated unmodified objects listed "
        "in the build plan.\n"
        if included_objects
        else ""
    )
    if included_objects:
        object_text = (
            f"The {included_objects} unmodified third-party objects used by the "
            "verified build are included under `third-party-objects/` and are "
            "hash-checked against `compat/xxmi/build/payload-build-plan.json`. "
            "They are reused as-is and are not rebuilt. Their source inputs are "
            "in the pinned upstream tree where applicable."
        )
    else:
        object_text = (
            "The unmodified third-party objects used by the verified build are "
            "not included in this archive by default. The build reuses them "
            "as-is and hash-checks every object against "
            "`compat/xxmi/build/payload-build-plan.json`. Their exact "
            "authenticated source inputs are available in the pinned upstream "
            "tree (`DirectXTK/`, `Nektra/`, `pcre2/` and `pcre2-10.30/`); the "
            "plan records each expected object hash so a different tree fails "
            "closed instead of producing an unverified DLL. The MSVC assembly "
            "helper object comes from the external compiler toolchain."
        )
    if stage3_present:
        stage3_names = ", ".join(
            f"`{PurePosixPath(str(patch['path']).replace(chr(92), '/')).name}`"
            for patch in plan["stage3"]["patches"]
        )
        patched_paragraph = f"""- `patched/{source_name}/`: the final patched source used for the payload.
  It equals the clean tree after base patches 0001-0006, the explicit
  compatibility edits, the generated `DirectXTK/Inc/SimpleMath.inl`, patch 0007
  and then the stage-3 patches {stage3_names}. Its tree SHA-256 is
  `{final["sha256"]}`. The intermediate stage-2 tree (through patch 0007)
  hashes to `{stage2["sha256"]}`, and the intermediate base candidate tree
  (patches 0001-0006 plus the edits and generated input) hashes to
  `{stage1["sha256"]}`."""
        rebuild_candidates = "the stage-1, stage-2 and stage-3 candidates"
    else:
        patched_paragraph = f"""- `patched/{source_name}/`: the final patched source used for the payload.
  It equals the clean tree after base patches 0001-0006, the explicit
  compatibility edits, the generated `DirectXTK/Inc/SimpleMath.inl`, and then
  patch 0007. Its tree SHA-256 is `{final["sha256"]}`.
  The intermediate base candidate tree (patches 0001-0006 plus the edits and
  generated input) hashes to `{stage1["sha256"]}`."""
        rebuild_candidates = "both candidates"
    return f"""# Corresponding source: MacGacha XXMI SRMI payload

Release: `{version}`
MacGacha application source: {APP_REPOSITORY}, tag `{tag}`
Payload source base: {pin["repository"]}, tag `{pin["tag"]}`, commit `{pin["commit"]}`
License: GPL-3.0-only

This archive is the corresponding source for the modified GPL-3.0-only SRMI
`d3d11.dll` payload bundled in the MacGacha `{version}` release. It is a source
archive only: it contains no rebuilt DLL, no prebuilt binary and no claim that a
different toolchain reproduces the released DLL byte for byte.

The MacGacha application source for this release is the Git tag `{tag}` in
{APP_REPOSITORY}. Fetch that tag from the repository; the application source is
not duplicated here.

## Contents

- `upstream/{source_name}/`: the original pinned XXMI Libraries clean source
  tree, with {pin["cleanFileCount"]} files and tree SHA-256
  `{pin["cleanTreeSHA256"]}`.
{patched_paragraph}
- `generated/DirectXTK/Inc/SimpleMath.inl`: the generated input omitted by the
  clean upstream archive.
- `compat/xxmi/`: source pins, the build plan, the ordered patches, notices,
  licenses and the GPL-covered runner source.
- `scripts/`: the source rebuild, package, runner and archive tools.
- `SHA256SUMS`: per-file SHA-256 for every other file in this archive.
- `SOURCE-RELEASE.json`: machine-readable pins and reconstructed tree hashes.
{objects_line}
## Reconstruct and rebuild

The patches in `compat/xxmi/patches/` apply with `patch -p1 --fuzz=0` in the
documented order. `scripts/xxmi-rebuild-payload.py` performs the same
reconstruction, verifies the clean, base and final tree hashes and rebuilds
{rebuild_candidates}. It requires explicit paths for the clean source, generated
assets, authenticated third-party objects and the local toolchain. The tools
never download, install, run Wine or touch an installed game or prefix.

## Not included

- **System toolchains.** macOS and Apple Clang, `lld-link`, MSVC 14.44 headers
  and libraries, the Clang resource headers and the Windows SDK
  10.0.26100.0 headers and import libraries are not included. They are
  separately licensed products supplied by the builder.
- **Prebuilt binaries.** The payload DLL, injector, shader compiler and runner
  binaries are not part of this source archive.
- **User data.** No mods, shader fixes, caches, logs, profiles, game files or
  developer build directories are archived.

## Third-party objects

{object_text}

## Verification

`SHA256SUMS` lists every archived file except itself. The sidecar file
`<archive>.sha256` records the SHA-256 of the archive. Archive entry names,
order, owner and group (0/0), timestamps (Unix epoch 0) and modes are fixed, so
two assemblies from identical inputs are byte-identical.

## Licensing

The payload is a fork of 3DMigoto and is distributed under GPL-3.0-only. See
`compat/xxmi/NOTICE.md`, `compat/xxmi/licenses/` and the upstream license files
inside the source trees. Redistribution of the DLL must satisfy those licenses
and the MacGacha `LICENSE` and `NOTICE`.
""".encode("utf-8")


def _archived_patches(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Replace plan-local paths with archive-relative patch names."""
    return [
        {
            "path": f"compat/xxmi/patches/{PurePosixPath(str(entry['path']).replace(chr(92), '/')).name}",
            "sha256": entry["sha256"],
        }
        for entry in entries
    ]


def _metadata(
    *,
    version: str,
    tag: str,
    plan: dict[str, Any],
    source_name: str,
    stage1: dict[str, Any],
    stage2: dict[str, Any],
    final: dict[str, Any],
    stage3_present: bool,
    objects: list[dict[str, Any]],
    included_objects: bool,
) -> bytes:
    value = {
        "schemaVersion": ARCHIVE_SCHEMA_VERSION,
        "kind": "xxmi-corresponding-source",
        "releaseVersion": version,
        "appRepository": APP_REPOSITORY,
        "appSourceTag": tag,
        "license": "GPL-3.0-only",
        "sourcePin": {
            "repository": plan["sourcePin"]["repository"],
            "tag": _pin_tag(plan),
            "commit": plan["sourcePin"]["commit"],
            "cleanTreeSHA256": plan["sourcePin"]["cleanTreeSHA256"],
            "cleanFileCount": plan["sourcePin"]["cleanFileCount"],
        },
        "basePatches": _archived_patches(plan["basePatches"]),
        "stage2Patch": _archived_patches([plan["stage2"]["patch"]])[0],
        "trees": {
            "upstream": {
                "path": f"upstream/{source_name}",
                "fileCount": plan["sourcePin"]["cleanFileCount"],
                "sha256": plan["sourcePin"]["cleanTreeSHA256"],
            },
            "stage1": {
                "archived": False,
                "fileCount": stage1["fileCount"],
                "sha256": stage1["sha256"],
            },
            "patched": {
                "path": f"patched/{source_name}",
                "fileCount": final["fileCount"],
                "sha256": final["sha256"],
            },
        },
        "generatedAssets": plan["stage1"]["generatedAssets"],
        "thirdPartyObjects": {
            "included": included_objects,
            "count": len(objects),
            "entries": objects if included_objects else [],
        },
        "limitations": [
            "Source archive only; no DLL is rebuilt or included.",
            "System toolchains are not included and must be supplied by the builder.",
            "Third-party objects are reused unmodified and hash-checked; they are "
            "included only when explicitly supplied.",
            "No network, download, Wine, game, launcher or installed-state action "
            "is performed by the archive tool.",
        ],
    }
    if stage3_present:
        value["stage3Patches"] = _archived_patches(plan["stage3"]["patches"])
        value["trees"]["stage2"] = {
            "archived": False,
            "fileCount": stage2["fileCount"],
            "sha256": stage2["sha256"],
        }
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def build_entries(
    *,
    plan: dict[str, Any],
    version: str,
    source: Path,
    generated_assets: Path,
    third_party_objects: Path | None,
    objects: list[dict[str, Any]],
    reconstruction: Reconstruction,
) -> list[Entry]:
    source_name = _archive_source_name(plan)
    tag = version if version.startswith("v") else f"v{version}"
    entries: list[Entry] = []
    entries.extend(_iter_tree(source, f"upstream/{source_name}"))
    entries.extend(_iter_tree(reconstruction.final, f"patched/{source_name}"))
    for asset in plan["stage1"]["generatedAssets"]:
        relative = _relative_path(asset["path"], "generated asset")
        path = _regular_file(generated_assets / relative, "generated asset")
        entries.append(Entry(arcname=f"generated/{relative.as_posix()}", mode=0o644, source=path))
    if third_party_objects is not None:
        for entry in objects:
            relative = _relative_path(entry["path"], "third-party object")
            path = _regular_file(third_party_objects / relative, "third-party object")
            entries.append(
                Entry(
                    arcname=f"third-party-objects/{relative.as_posix()}",
                    mode=0o644,
                    source=path,
                )
            )
    entries.extend(_selected_files(COMPAT_FILES))
    entries.extend(_selected_files(SCRIPT_FILES))
    entries.extend(_patch_files())
    entries.extend(_license_files())

    readme = _readme(
        version=version,
        tag=tag,
        plan=plan,
        source_name=source_name,
        stage1=reconstruction.stage1_manifest,
        stage2=reconstruction.stage2_manifest,
        final=reconstruction.final_manifest,
        stage3_present=reconstruction.stage3_present,
        included_objects=len(objects) if third_party_objects is not None else 0,
    )
    metadata = _metadata(
        version=version,
        tag=tag,
        plan=plan,
        source_name=source_name,
        stage1=reconstruction.stage1_manifest,
        stage2=reconstruction.stage2_manifest,
        final=reconstruction.final_manifest,
        stage3_present=reconstruction.stage3_present,
        objects=objects,
        included_objects=third_party_objects is not None,
    )
    entries.append(Entry(arcname="README.md", mode=0o644, data=readme))
    entries.append(Entry(arcname="SOURCE-RELEASE.json", mode=0o644, data=metadata))

    names = [entry.arcname for entry in entries]
    if len(names) != len(set(names)):
        raise ReleaseError("archive contains duplicate entry names")
    for name in names:
        _relative_path(name, "archive entry")
    return sorted(entries, key=lambda entry: entry.arcname)


def _sha256sums(entries: list[Entry]) -> bytes:
    lines = [f"{entry.sha256()}  {entry.arcname}" for entry in entries]
    return ("\n".join(lines) + "\n").encode("utf-8")


def _archive_dirs(entries: list[Entry], root_name: str) -> list[str]:
    directories = {root_name}
    for entry in entries:
        parts = f"{root_name}/{entry.arcname}".split("/")
        for index in range(1, len(parts)):
            directories.add("/".join(parts[:index]))
    return sorted(directories)


def write_archive(entries: list[Entry], *, output_path: Path, root_name: str) -> None:
    with output_path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for directory in _archive_dirs(entries, root_name):
                    info = tarfile.TarInfo(directory)
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    archive.addfile(info)
                for entry in entries:
                    info = tarfile.TarInfo(f"{root_name}/{entry.arcname}")
                    info.type = tarfile.REGTYPE
                    info.mode = entry.mode
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    info.size = entry.size()
                    if entry.data is not None:
                        archive.addfile(info, io.BytesIO(entry.data))
                    else:
                        assert entry.source is not None
                        with entry.source.open("rb") as stream:
                            archive.addfile(info, stream)


def assemble(
    plan: dict[str, Any],
    *,
    version: str,
    source: Path,
    generated_assets: Path,
    third_party_objects: Path | None,
    output_dir: Path,
) -> dict[str, Any]:
    output_dir = output_dir.resolve()
    if output_dir.exists() and not output_dir.is_dir():
        raise ReleaseError(f"output path is not a directory: {output_dir}")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ReleaseError(f"output directory must be absent or empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)

    objects = validate_inputs(
        plan,
        source=source,
        generated_assets=generated_assets,
        third_party_objects=third_party_objects,
    )
    staging = Path(tempfile.mkdtemp(prefix=".xxmi-source-release-", dir=output_dir))
    try:
        reconstruction = reconstruct(
            plan,
            source=source,
            generated_assets=generated_assets,
            work=staging,
        )
        entries = build_entries(
            plan=plan,
            version=version,
            source=source,
            generated_assets=generated_assets,
            third_party_objects=third_party_objects,
            objects=objects,
            reconstruction=reconstruction,
        )
        sums = Entry(
            arcname="SHA256SUMS",
            mode=0o644,
            data=_sha256sums(entries),
        )
        entries.append(sums)
        entries.sort(key=lambda entry: entry.arcname)

        source_name = _archive_source_name(plan)
        tag = version if version.startswith("v") else f"v{version}"
        pin_tag = _pin_tag(plan)
        archive_name = f"xxmi-libs-{pin_tag}-source-{version}.tar.gz"
        root_name = f"xxmi-libs-{pin_tag}-source-{version}"
        archive_path = output_dir / archive_name

        generated_text = [
            entry.data.decode("utf-8", "replace") for entry in entries if entry.data is not None
        ]
        for value, label in (
            (str(source), "source path"),
            (str(generated_assets), "generated-assets path"),
            (str(output_dir), "output path"),
            (str(third_party_objects) if third_party_objects else "", "third-party path"),
        ):
            if value and any(value in text for text in generated_text):
                raise ReleaseError(f"generated archive metadata would leak a {label}")

        write_archive(entries, output_path=archive_path, root_name=root_name)
        archive_sha = sha256_file(archive_path)
        checksum_path = output_dir / f"{archive_name}.sha256"
        checksum_path.write_text(f"{archive_sha}  {archive_name}\n", encoding="utf-8")
        return {
            "archive": str(archive_path),
            "archiveSHA256": archive_sha,
            "checksum": str(checksum_path),
            "fileCount": len(entries),
            "archiveEntryCount": len(_archive_dirs(entries, root_name)) + len(entries),
            "sourceName": source_name,
            "stage1TreeSHA256": reconstruction.stage1_manifest["sha256"],
            "stage2TreeSHA256": reconstruction.stage2_manifest["sha256"],
            "finalTreeSHA256": reconstruction.final_manifest["sha256"],
            "stage3Present": reconstruction.stage3_present,
            "thirdPartyObjectsIncluded": third_party_objects is not None,
            "tag": tag,
        }
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--generated-assets", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--third-party-objects", type=Path)
    args = parser.parse_args(argv)
    try:
        version = validate_version(args.version)
        plan = REBUILD.load_plan(args.plan)
        result = assemble(
            plan,
            version=version,
            source=args.source,
            generated_assets=args.generated_assets,
            third_party_objects=args.third_party_objects,
            output_dir=args.output_dir,
        )
    except ReleaseError as exc:
        print(f"xxmi-source-release: {exc}", file=sys.stderr)
        return 1
    except REBUILD.BuildError as exc:
        print(f"xxmi-source-release: {exc}", file=sys.stderr)
        return 1
    print(f"archive: {result['archive']}")
    print(f"sha256: {result['archiveSHA256']}")
    print(f"files: {result['fileCount']}")
    print(f"upstream tree: {plan['sourcePin']['cleanTreeSHA256']}")
    print(f"stage1 tree: {result['stage1TreeSHA256']}")
    print(f"stage2 tree: {result['stage2TreeSHA256']}")
    if result["stage3Present"]:
        print(f"stage3 tree: {result['finalTreeSHA256']}")
    print(
        "third-party objects: "
        + ("included" if result["thirdPartyObjectsIncluded"] else "not included")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
