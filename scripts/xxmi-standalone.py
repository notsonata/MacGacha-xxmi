#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Wrap a verified XXMI package pair into its standalone release download.

The output is `XXMI-<GAME>-<version>.zip` plus a `.sha256` sidecar. The ZIP
holds one top-level `XXMI-<GAME>-<version>/` folder with the verified manifest
and archive (unchanged), a README, the package NOTICE and the license texts.
Users extract it and choose that folder in **XXMI → Import Package…**.

The pair is verified against its pins first, so a standalone download can only
wrap a package the app itself would accept. Output is deterministic.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("xxmi_package", ROOT / "scripts" / "xxmi-package.py")
xxmi_package = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(xxmi_package)

GAME_LABELS = {"starrail": ("HSR", "Honkai: Star Rail"), "zzz": ("ZZZ", "Zenless Zone Zero")}


class StandaloneError(Exception):
    pass


def _readme(manifest: dict, label: str, game: str, folder: str, manifest_name: str, archive_name: str) -> str:
    minimum = manifest.get("minimumAppBuild")
    requirement = (f"MacGacha build {minimum} or later" if minimum
                   else "any MacGacha XXMI build that supports this game")
    return (
        f"XXMI compatibility package for {game}\n"
        f"Version: {manifest['version']}\n"
        f"Requires: {requirement}, and the {', '.join(manifest['supportedRuntimeBundleIDs'])} runtime\n\n"
        "How to install\n"
        "1. Extract this ZIP.\n"
        f"2. In MacGacha, select {game}, open XXMI and click Import Package...\n"
        f"3. Choose the extracted {folder} folder.\n\n"
        "Your mods and saved settings are kept. MacGacha checks every file against\n"
        f"{manifest_name} before it installs {archive_name}.\n\n"
        "This is a compatibility package, not a mod. Mod folders and ZIPs go in the\n"
        "mod list instead. The XXMI Launcher app is not included.\n\n"
        "Mod injection may be treated as cheating by HoYoverse and can lead to an\n"
        "account ban. See NOTICE.md and licenses/ for the included components.\n"
    )


def build_standalone(directory: Path, pins_path: Path, output_dir: Path,
                     notice: Path, licenses: Path) -> Path:
    manifest = xxmi_package.verify_package(directory, pins_path=pins_path)
    package = json.loads(pins_path.read_text(encoding="utf-8"))["package"]
    game = manifest["gameID"]
    if game not in GAME_LABELS:
        raise StandaloneError(f"no standalone label for game {game!r}")
    label, title = GAME_LABELS[game]
    manifest_name, archive_name = package["manifestName"], package["archiveName"]
    folder = f"XXMI-{label}-{manifest['version']}"
    if not notice.is_file():
        raise StandaloneError(f"missing NOTICE: {notice}")
    license_files = sorted(path for path in licenses.iterdir() if path.is_file()) if licenses.is_dir() else []
    if not license_files:
        raise StandaloneError(f"no license texts in {licenses}")

    files = {
        f"{folder}/{manifest_name}": (directory / manifest_name).read_bytes(),
        f"{folder}/{archive_name}": (directory / archive_name).read_bytes(),
        f"{folder}/README.txt": _readme(manifest, label, title, folder, manifest_name, archive_name).encode("utf-8"),
        f"{folder}/NOTICE.md": notice.read_bytes(),
    }
    for path in license_files:
        files[f"{folder}/licenses/{path.name}"] = path.read_bytes()

    output_dir.mkdir(parents=True, exist_ok=True)
    zip_path = output_dir / f"{folder}.zip"
    if zip_path.exists() or zip_path.is_symlink():
        raise StandaloneError(f"refusing to overwrite {zip_path}")
    temporary = output_dir / f".{folder}.zip.partial"
    try:
        xxmi_package._write_zip(temporary, files)
        temporary.replace(zip_path)
    finally:
        if temporary.exists():
            temporary.unlink()
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    (output_dir / f"{folder}.zip.sha256").write_text(f"{digest}  {zip_path.name}\n", encoding="utf-8")
    _check(zip_path, folder, manifest_name, archive_name, directory)
    return zip_path


def _check(zip_path: Path, folder: str, manifest_name: str, archive_name: str, directory: Path) -> None:
    """Re-read the download: the wrapped pair must be byte-identical to the verified one."""
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        if any(not name.startswith(folder + "/") or name.endswith("/") for name in names):
            raise StandaloneError("standalone ZIP has an entry outside its top-level folder")
        for name in (manifest_name, archive_name):
            if archive.read(f"{folder}/{name}") != (directory / name).read_bytes():
                raise StandaloneError(f"wrapped {name} differs from the verified package")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "App" / "Resources" / "XXMI",
                        help="folder holding the verified manifest and archive")
    parser.add_argument("--pins", type=Path, required=True,
                        help="compat/xxmi/source-pins.json (HSR) or compat/xxmi/zzz-source-pins.json (ZZZ)")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--notice", type=Path, default=ROOT / "compat" / "xxmi" / "NOTICE.md")
    parser.add_argument("--licenses", type=Path, default=ROOT / "compat" / "xxmi" / "licenses")
    args = parser.parse_args(argv)
    try:
        path = build_standalone(args.directory, args.pins, args.output_dir, args.notice, args.licenses)
    except (StandaloneError, xxmi_package.PackageError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
