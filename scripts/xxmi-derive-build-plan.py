#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Derive a new payload build plan from an actual three-stage build.

The checked-in plan is derived data. This tool takes the current plan as a
template (patch order, compatibility edits, generated assets, compile argv
templates and link response lines), a new authenticated clean source tree and
an authenticated third-party object set, performs the stage-1, stage-2 and
stage-3 builds with the explicit toolchain, and writes a plan whose every tree,
source, object and candidate hash comes from that build. Nothing is
hand-edited and no hash is copied forward unverified:

* the clean tree and every patched tree are hashed after patching;
* compatibility edits are re-applied and must still match their recorded
  before/after hashes, so an upstream change to an edited file fails closed;
* every first-party translation unit is compiled; stage 3 starts from an empty
  object directory because its patches change internal class layouts;
* third-party objects are not rebuilt here: they are taken from the supplied
  root and must match the supplied per-object SHA-256 list;
* when the template (or ``--resources``, the output of
  ``xxmi-payload-resources.py describe``) carries a ``resources`` record, every
  stage compiles its own DirectX11.res from its own tree, links it as the last
  link input and must embed exactly the authenticated font and VERSIONINFO
  bytes. Resource inputs never enter a pinned tree hash.

The output plan carries only tokenized paths. Verify it afterwards with an
independent ``xxmi-rebuild-payload.py --output-dir`` run.

No download, install, Wine, game, launcher or Git action is performed.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import copy
import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
REBUILD_SCRIPT = REPO_ROOT / "scripts" / "xxmi-rebuild-payload.py"
DEFAULT_PLAN = REPO_ROOT / "compat" / "xxmi" / "build" / "payload-build-plan.json"


class DeriveError(RuntimeError):
    pass


def load_rebuild() -> ModuleType:
    spec = importlib.util.spec_from_file_location("xxmi_rebuild_payload", REBUILD_SCRIPT)
    if spec is None or spec.loader is None:
        raise DeriveError(f"cannot load {REBUILD_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


REBUILD = load_rebuild()


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError as exc:
        raise DeriveError(f"patch must live inside the repository: {path}") from exc


def patch_entry(path: Path) -> dict[str, str]:
    return {"path": repo_relative(path), "sha256": REBUILD.sha256_file(path)}


def compile_all(
    commands: list[dict[str, Any]],
    *,
    source: Path,
    objects: Path,
    values: dict[str, str],
    c_compiler: Path,
    log_dir: Path,
    jobs: int,
) -> list[dict[str, Any]]:
    objects.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update({"LC_ALL": "C", "TZ": "UTC", "SOURCE_DATE_EPOCH": "0"})

    def one(command: dict[str, Any]) -> dict[str, Any]:
        argv = REBUILD.expand(command["argv"], values)
        if command["source"].endswith(".c"):
            argv[0] = str(c_compiler)
        result = REBUILD.run(argv, cwd=source, env=environment)
        (log_dir / f"compile-{command['object']}.log").write_text(
            result.stdout + result.stderr, encoding="utf-8"
        )
        if result.returncode != 0:
            raise DeriveError(f"compile failed: {command['source']}")
        output = objects / command["object"]
        if not output.is_file():
            raise DeriveError(f"compiler did not produce {output}")
        entry = {
            key: command[key] for key in ("source", "object")
        }
        entry["sourceSHA256"] = REBUILD.sha256_file(source / command["source"])
        entry["objectSHA256"] = REBUILD.sha256_file(output)
        entry["objectCanonicalSHA256"] = REBUILD.canonical_object_sha256(output)
        entry["argv"] = command["argv"]
        return entry

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        return list(pool.map(one, commands))


def with_libraries(lines: list[str], libraries: list[str]) -> list[str]:
    result = list(lines)
    for library in libraries:
        if library not in result:
            result.append(library)
    return result


def object_entries(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        entries = value
    elif isinstance(value, dict) and isinstance(value.get("stage1"), dict):
        entries = value["stage1"].get("thirdPartyObjects")
    else:
        entries = None
    if not isinstance(entries, list) or not entries or not all(isinstance(entry, dict) for entry in entries):
        raise DeriveError("third-party manifest has no object entries")
    return entries


def derive(args: argparse.Namespace) -> dict[str, Any]:
    template = REBUILD.load_plan(args.plan)
    if template.get("stage3") is None:
        raise DeriveError("the template plan must contain stage3")
    plan = copy.deepcopy(template)
    toolchain = {
        "clang": args.clang,
        "clangxx": args.clangxx,
        "clang_resource": args.clang_resource,
        "msvc_include": args.msvc_include,
        "msvc_lib": args.msvc_lib,
        "windows_sdk_include": args.windows_sdk_include,
        "windows_sdk_lib": args.windows_sdk_lib,
        "lld_link": args.lld_link,
    }
    if args.lld_library_path:
        toolchain["lld_library_path"] = args.lld_library_path

    third_party = json.loads(args.third_party_manifest.read_text(encoding="utf-8"))
    entries = object_entries(third_party)
    third_party_objects = []
    for entry in entries:
        path = args.third_party_objects / entry["path"]
        if not path.is_file() or REBUILD.sha256_file(path) != entry["sha256"]:
            raise DeriveError(f"third-party object missing or mismatched: {path}")
        third_party_objects.append(
            {"path": entry["path"], "sha256": entry["sha256"], "label": entry.get("label")}
        )
    plan["stage1"]["thirdPartyObjects"] = third_party_objects

    output = args.work_dir.resolve()
    if output.exists() and any(output.iterdir()):
        raise DeriveError(f"work directory must be absent or empty: {output}")
    logs = output / "logs"
    logs.mkdir(parents=True)
    c_compiler = args.clang

    clean = REBUILD.tree_manifest(args.source)
    plan["sourcePin"] = {
        "repository": args.repository,
        "tag": args.tag,
        "commit": args.commit,
        "cleanTreeSHA256": clean["sha256"],
        "cleanFileCount": clean["fileCount"],
    }

    stage3_patches = [patch_entry(path) for path in args.stage3_patch]
    if not stage3_patches:
        raise DeriveError("at least one --stage3-patch is required")
    plan["stage3"]["patches"] = stage3_patches

    if args.resources is not None:
        plan["resources"] = json.loads(args.resources.read_text(encoding="utf-8"))
    resources = plan.get("resources")
    if resources is not None:
        try:
            REBUILD.RESOURCES.validate_spec(resources)
        except REBUILD.RESOURCES.ResourceError as exc:
            raise DeriveError(str(exc)) from exc
    libraries = list(args.add_link_library)
    stages: dict[str, Path] = {}
    trees: dict[str, Path] = {}

    def link(name: str, objects: Path, source: Path) -> Path:
        lines = [
            line for line in with_libraries(template[name]["link"]["rspLines"], libraries)
            if line != REBUILD.RESOURCES.RES_LINK_LINE
        ]
        build = output / name / "build"
        if resources is not None:
            lines.append(REBUILD.RESOURCES.RES_LINK_LINE)
            REBUILD.stage_resources(plan, source=source, generated_assets=args.generated_assets,
                                    build=build, log_dir=logs, label=name)
        plan[name]["link"]["rspLines"] = lines
        dll = REBUILD.link_stage(
            plan[name]["link"]["rspLines"],
            objects=objects,
            build=output / name / "build",
            source=source,
            third_party=args.third_party_objects,
            toolchain=toolchain,
            log_dir=logs,
            label=name,
        )
        REBUILD.verify_stage_resources(plan, dll, name)
        return dll

    # Stage 1: clean tree, base patches, compatibility edits, generated input.
    source1 = output / "stage1" / "src"
    shutil.copytree(args.source, source1)
    for entry in plan["basePatches"]:
        REBUILD.apply_patch(source1, REBUILD.resolve_plan_path(entry["path"]), logs)
    REBUILD.apply_compatibility_edits(source1, plan["stage1"]["compatibilityEdits"])
    REBUILD.vendor_generated_assets(source1, args.generated_assets, plan["stage1"]["generatedAssets"])
    plan["stage1"]["patchedTreeSHA256"] = REBUILD.tree_manifest(source1)["sha256"]
    objects1 = output / "stage1" / "objects"
    values1 = REBUILD.token_values(
        source=source1, objects=objects1, build=output / "stage1" / "build",
        third_party=args.third_party_objects, toolchain=toolchain,
    )
    plan["stage1"]["compile"] = compile_all(
        template["stage1"]["compile"], source=source1, objects=objects1,
        values=values1, c_compiler=c_compiler, log_dir=logs, jobs=args.jobs,
    )
    stages["stage1"] = link("stage1", objects1, source1)
    trees["stage1"] = source1

    # Stage 2: NGX context boundary, recompiling only its translation units.
    source2 = output / "stage2" / "src"
    shutil.copytree(source1, source2)
    REBUILD.apply_patch(source2, REBUILD.resolve_plan_path(plan["stage2"]["patch"]["path"]), logs)
    plan["stage2"]["patchedTreeSHA256"] = REBUILD.tree_manifest(source2)["sha256"]
    objects2 = output / "stage2" / "objects"
    shutil.copytree(objects1, objects2)
    values2 = REBUILD.token_values(
        source=source2, objects=objects2, build=output / "stage2" / "build",
        third_party=args.third_party_objects, toolchain=toolchain,
    )
    plan["stage2"]["compile"] = compile_all(
        template["stage2"]["compile"], source=source2, objects=objects2,
        values=values2, c_compiler=c_compiler, log_dir=logs, jobs=args.jobs,
    )
    stages["stage2"] = link("stage2", objects2, source2)
    trees["stage2"] = source2

    # Stage 3: layout-changing patches; every first-party unit from empty.
    source3 = output / "stage3" / "src"
    shutil.copytree(source2, source3)
    for entry in stage3_patches:
        REBUILD.apply_patch(source3, REBUILD.resolve_plan_path(entry["path"]), logs)
    plan["stage3"]["patchedTreeSHA256"] = REBUILD.tree_manifest(source3)["sha256"]
    objects3 = output / "stage3" / "objects"
    values3 = REBUILD.token_values(
        source=source3, objects=objects3, build=output / "stage3" / "build",
        third_party=args.third_party_objects, toolchain=toolchain,
    )
    plan["stage3"]["compile"] = compile_all(
        template["stage3"]["compile"], source=source3, objects=objects3,
        values=values3, c_compiler=c_compiler, log_dir=logs, jobs=args.jobs,
    )
    stages["stage3"] = link("stage3", objects3, source3)
    trees["stage3"] = source3

    for name, dll in stages.items():
        plan[name]["candidateSHA256"] = REBUILD.sha256_file(dll)
        plan[name]["candidateSize"] = dll.stat().st_size

    serialized = json.dumps(plan)
    for forbidden in (str(output), str(Path.home()), "/private/tmp/", "/var/folders/"):
        if forbidden and forbidden in serialized:
            raise DeriveError(f"derived plan would contain a local path: {forbidden}")
    return plan


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN, help="template plan")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--generated-assets", type=Path, required=True)
    parser.add_argument("--third-party-objects", type=Path, required=True)
    parser.add_argument(
        "--third-party-manifest", type=Path, required=True,
        help="JSON plan or list whose thirdPartyObjects entries (path, sha256, label) are adopted",
    )
    parser.add_argument("--stage3-patch", type=Path, action="append", default=[])
    parser.add_argument("--add-link-library", action="append", default=[])
    parser.add_argument(
        "--resources", type=Path,
        help="resources record from xxmi-payload-resources.py describe (replaces the template's)",
    )
    parser.add_argument("--clang", type=Path, required=True)
    parser.add_argument("--clangxx", type=Path, required=True)
    parser.add_argument("--clang-resource", type=Path, required=True)
    parser.add_argument("--msvc-include", type=Path, required=True)
    parser.add_argument("--msvc-lib", type=Path, required=True)
    parser.add_argument("--windows-sdk-include", type=Path, required=True)
    parser.add_argument("--windows-sdk-lib", type=Path, required=True)
    parser.add_argument("--lld-link", type=Path, required=True)
    parser.add_argument("--lld-library-path", type=Path)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--output-plan", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        plan = derive(args)
    except (DeriveError, REBUILD.BuildError) as exc:
        print(f"xxmi-derive-build-plan: {exc}", file=sys.stderr)
        return 1
    args.output_plan.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    for name in ("stage1", "stage2", "stage3"):
        print(f"{name}: {plan[name]['candidateSHA256']} ({plan[name]['candidateSize']} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
