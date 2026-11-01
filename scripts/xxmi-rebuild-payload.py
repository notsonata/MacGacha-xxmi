#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Rebuild the pinned SRMI payload from source with explicit toolchain inputs.

This command never downloads, installs, launches Wine, or falls back to a
prebuilt DLL. Missing source, patches, SDK headers, import libraries, Clang
resource headers, reference third-party objects or lld fail before any output
is written. The checked-in build plan is generated from the verified build and
contains only tokenized paths; developer paths never enter the plan.

Stages 1 and 2 reproduce the base and NGX-boundary candidates. An optional final
stage 3 applies the cursor-coordinate and invalid-conditional patches on top of
stage 2 and recompiles every first-party translation unit; its layout changes
make stage-2 first-party objects ABI-incompatible, so no stage-2 object is
reused. Object hashes are verified through their COFF-timestamp-normalised
form when the plan records one, because Clang writes a wall-clock timestamp
into every object header while the linked /Brepro candidate stays identical.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PLAN = REPO_ROOT / "compat" / "xxmi" / "build" / "payload-build-plan.json"


class BuildError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_object_sha256(path: Path) -> str:
    """Hash a COFF object with its non-reproducible TimeDateStamp bytes cleared.

    Clang stamps a wall-clock time into bytes 4-7 of the COFF header, so the raw
    object hash changes on every build even though the generated code and the
    linked /Brepro candidate are identical. Files shorter than a COFF header are
    hashed verbatim.
    """
    data = path.read_bytes()
    if len(data) >= 8:
        data = data[:4] + b"\0" * 4 + data[8:]
    return hashlib.sha256(data).hexdigest()


def tree_manifest(root: Path) -> dict[str, Any]:
    entries: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            entries[path.relative_to(root).as_posix()] = sha256_file(path)
    digest = hashlib.sha256()
    for relative, file_hash in entries.items():
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_hash.encode("ascii"))
        digest.update(b"\n")
    return {"fileCount": len(entries), "sha256": digest.hexdigest()}


def run(command: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        command,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def load_plan(path: Path) -> dict[str, Any]:
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError(f"build plan is not valid UTF-8 JSON: {path}") from exc
    if plan.get("schemaVersion") != 1:
        raise BuildError("build plan schemaVersion must be 1")
    for key in ("sourcePin", "basePatches", "stage1", "stage2", "textPrinter"):
        if key not in plan:
            raise BuildError(f"build plan is missing {key}")
    stage3 = plan.get("stage3")
    if stage3 is not None:
        if not isinstance(stage3, dict):
            raise BuildError("build plan stage3 must be an object")
        for key in ("patches", "patchedTreeSHA256", "candidateSHA256", "compile", "link"):
            if key not in stage3:
                raise BuildError(f"build plan stage3 is missing {key}")
        if not stage3["patches"]:
            raise BuildError("build plan stage3 must list at least one patch")
        if not stage3["compile"]:
            raise BuildError("build plan stage3 must list at least one compile command")
    return plan


def resolve_plan_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else REPO_ROOT / path


def check_file(path: Path, label: str, errors: list[str], *, executable: bool = False) -> None:
    if not path.is_file():
        errors.append(f"missing {label}: {path}")
    elif executable and not os.access(path, os.X_OK):
        errors.append(f"{label} is not executable: {path}")


def check_dir(path: Path, label: str, errors: list[str]) -> None:
    if not path.is_dir():
        errors.append(f"missing {label}: {path}")


def check_compile_commands(commands: list[dict[str, Any]], label: str, errors: list[str]) -> None:
    seen_objects: set[str] = set()
    for command in commands:
        for key in ("source", "object", "sourceSHA256", "argv"):
            if key not in command:
                errors.append(f"{label} compile command is missing {key}")
        if "objectCanonicalSHA256" not in command and "objectSHA256" not in command:
            errors.append(f"{label} compile command has no object hash: {command.get('object')}")
        object_name = command.get("object")
        if isinstance(object_name, str):
            if object_name in seen_objects:
                errors.append(f"{label} duplicate compile object: {object_name}")
            seen_objects.add(object_name)


def check_patches(patches: list[dict[str, Any]], label: str, errors: list[str]) -> None:
    for patch in patches:
        path = resolve_plan_path(patch["path"])
        check_file(path, f"{label} patch", errors)
        if path.is_file() and sha256_file(path) != patch["sha256"]:
            errors.append(f"{label} patch SHA-256 mismatch: {path}")


def validate(
    plan: dict[str, Any],
    *,
    source: Path,
    generated_assets: Path,
    third_party_objects: Path,
    toolchain: dict[str, Path],
    verify_source_hash: bool = True,
) -> None:
    errors: list[str] = []
    check_dir(source, "pinned clean source", errors)
    check_dir(generated_assets, "generated-assets root", errors)
    check_dir(third_party_objects, "third-party object root", errors)
    for label, path in toolchain.items():
        if label in (
            "msvc_include",
            "msvc_lib",
            "windows_sdk_include",
            "windows_sdk_lib",
            "clang_resource",
            "lld_library_path",
        ):
            check_dir(path, label, errors)
        else:
            check_file(path, label, errors, executable=True)
    check_patches(plan["basePatches"], "base", errors)
    check_patches([plan["stage2"]["patch"]], "stage2", errors)
    check_compile_commands(plan["stage1"]["compile"], "stage1", errors)
    check_compile_commands(plan["stage2"]["compile"], "stage2", errors)
    stage3 = plan.get("stage3")
    if stage3 is not None:
        check_patches(stage3["patches"], "stage3", errors)
        check_compile_commands(stage3["compile"], "stage3", errors)
    shader_patch = plan["textPrinter"]["patch"]
    shader_patch_path = resolve_plan_path(shader_patch["path"])
    check_file(shader_patch_path, "TextPrinter patch", errors)
    if shader_patch_path.is_file() and sha256_file(shader_patch_path) != shader_patch["sha256"]:
        errors.append(f"TextPrinter patch SHA-256 mismatch: {shader_patch_path}")
    for asset in plan["stage1"]["generatedAssets"]:
        path = generated_assets / asset["path"]
        if (source / asset["path"]).is_file():
            path = source / asset["path"]
        check_file(path, "generated asset", errors)
        if path.is_file() and sha256_file(path) != asset["sha256"]:
            errors.append(f"generated asset SHA-256 mismatch: {path}")
    for entry in plan["stage1"]["thirdPartyObjects"]:
        path = third_party_objects / entry["path"]
        check_file(path, "third-party object", errors)
        if path.is_file() and sha256_file(path) != entry["sha256"]:
            errors.append(f"third-party object SHA-256 mismatch: {path}")
    if verify_source_hash and source.is_dir():
        actual = tree_manifest(source)
        expected = plan["sourcePin"]["cleanTreeSHA256"]
        if actual["sha256"] != expected:
            errors.append(
                "clean source tree SHA-256 mismatch: "
                f"got {actual['sha256']}, expected {expected}"
            )
    if errors:
        raise BuildError("\n".join(errors))


def apply_patch(source: Path, patch: Path, log_dir: Path) -> None:
    result = run(
        ["patch", "-p1", "--fuzz=0", "--no-backup-if-mismatch", "-i", str(patch)],
        cwd=source,
    )
    output = result.stdout + result.stderr
    (log_dir / f"patch-{patch.name}.log").write_text(output, encoding="utf-8")
    lowered = output.lower()
    if result.returncode != 0:
        raise BuildError(f"patch failed: {patch}\n{output}")
    if "fuzz" in lowered or "offset" in lowered:
        raise BuildError(f"patch applied with fuzz/offset: {patch}\n{output}")
    rejects = sorted(source.rglob("*.rej"))
    if rejects:
        raise BuildError(f"patch left rejects: {[str(path) for path in rejects]}")


def apply_compatibility_edits(source: Path, edits: list[dict[str, Any]]) -> None:
    for edit in edits:
        path = source / edit["path"]
        before = path.read_text()
        count = before.count(edit["old"])
        if count != edit["occurrences"]:
            raise BuildError(
                f"compatibility edit count mismatch for {edit['path']}: "
                f"found {count}, expected {edit['occurrences']}"
            )
        after = before.replace(edit["old"], edit["new"])
        if hashlib.sha256(before.encode()).hexdigest() != edit["sha256_before"]:
            raise BuildError(f"compatibility edit before-hash mismatch: {edit['path']}")
        if hashlib.sha256(after.encode()).hexdigest() != edit["sha256_after"]:
            raise BuildError(f"compatibility edit after-hash mismatch: {edit['path']}")
        path.write_text(after)


def vendor_generated_assets(source: Path, generated_assets: Path, assets: list[dict[str, Any]]) -> None:
    for asset in assets:
        target = source / asset["path"]
        if target.is_file() and sha256_file(target) == asset["sha256"]:
            continue
        candidate = generated_assets / asset["path"]
        if not candidate.is_file():
            raise BuildError(f"missing generated asset: {candidate}")
        if sha256_file(candidate) != asset["sha256"]:
            raise BuildError(f"generated asset SHA-256 mismatch: {candidate}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(candidate, target)


def token_values(
    *,
    source: Path,
    objects: Path,
    build: Path,
    third_party: Path,
    toolchain: dict[str, Path],
) -> dict[str, str]:
    return {
        "{SRC}": str(source),
        "{OBJDIR}": str(objects),
        "{BUILD}": str(build),
        "{THIRD}": str(third_party),
        "{CLANG}": str(toolchain.get("clang", toolchain["clangxx"])),
        "{CLANGXX}": str(toolchain["clangxx"]),
        "{CLANG_RESOURCE}": str(toolchain["clang_resource"]),
        "{MSVC_INCLUDE}": str(toolchain["msvc_include"]),
        "{MSVC_LIB}": str(toolchain["msvc_lib"]),
        "{WIN_SDK_INCLUDE}": str(toolchain["windows_sdk_include"]),
        "{WIN_SDK_LIB}": str(toolchain["windows_sdk_lib"]),
    }


def expand(parts: list[str], values: dict[str, str]) -> list[str]:
    expanded = []
    for part in parts:
        for token, value in values.items():
            part = part.replace(token, value)
        if "{SRC}" in part or "{OBJDIR}" in part or "{THIRD}" in part or "{" in part:
            raise BuildError(f"unresolved build-plan token in: {part}")
        expanded.append(part)
    return expanded


def verify_source_hashes(source: Path, commands: list[dict[str, Any]], label: str) -> None:
    for command in commands:
        path = source / command["source"]
        if not path.is_file():
            raise BuildError(f"{label} source is missing: {path}")
        actual = sha256_file(path)
        if actual != command["sourceSHA256"]:
            raise BuildError(
                f"{label} source SHA-256 mismatch: {command['source']}\n"
                f"got {actual}, expected {command['sourceSHA256']}"
            )


def verify_object(command: dict[str, Any], output: Path) -> None:
    expected_canonical = command.get("objectCanonicalSHA256")
    if expected_canonical is not None:
        actual = canonical_object_sha256(output)
        if actual != expected_canonical:
            raise BuildError(
                f"object canonical SHA-256 mismatch: {command['object']}\n"
                f"got {actual}, expected {expected_canonical}"
            )
        return
    expected_raw = command.get("objectSHA256")
    if expected_raw is None:
        raise BuildError(f"compile command has no object hash: {command['object']}")
    actual = sha256_file(output)
    if actual != expected_raw:
        raise BuildError(
            f"object SHA-256 mismatch: {command['object']}\n"
            f"got {actual}, expected {expected_raw}"
        )


def compile_stage(
    commands: list[dict[str, Any]],
    *,
    source: Path,
    objects: Path,
    log_dir: Path,
    values: dict[str, str],
    c_compiler: Path,
) -> None:
    objects.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update({"LC_ALL": "C", "TZ": "UTC", "SOURCE_DATE_EPOCH": "0"})
    for command in commands:
        argv = expand(command["argv"], values)
        if command["source"].endswith(".c"):
            argv[0] = str(c_compiler)
        result = run(argv, cwd=source, env=environment)
        (log_dir / f"compile-{command['object']}.log").write_text(
            result.stdout + result.stderr, encoding="utf-8"
        )
        if result.returncode != 0:
            errors = [
                line
                for line in (result.stdout + result.stderr).splitlines()
                if "error:" in line or "fatal error:" in line
            ][:20]
            raise BuildError(
                f"compile failed: {command['source']}\n" + "\n".join(errors)
            )
        output = objects / command["object"]
        if not output.is_file():
            raise BuildError(f"compiler did not produce {output}")
        verify_object(command, output)


def link_stage(
    rsp_lines: list[str],
    *,
    objects: Path,
    build: Path,
    source: Path,
    third_party: Path,
    toolchain: dict[str, Path],
    log_dir: Path,
    label: str,
) -> Path:
    build.mkdir(parents=True, exist_ok=True)
    values = token_values(
        source=source,
        objects=objects,
        build=build,
        third_party=third_party,
        toolchain=toolchain,
    )
    rsp = build / f"{label}.rsp"
    rsp.write_text("\n".join(expand(rsp_lines, values)) + "\n", encoding="utf-8")
    environment = os.environ.copy()
    environment.update({"LC_ALL": "C", "TZ": "UTC", "SOURCE_DATE_EPOCH": "0"})
    library_path = toolchain.get("lld_library_path")
    if library_path:
        environment["DYLD_LIBRARY_PATH"] = str(library_path)
    result = run([str(toolchain["lld_link"]), f"@{rsp}"], cwd=build, env=environment)
    (log_dir / f"link-{label}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise BuildError(f"link failed for {label}\n{result.stdout + result.stderr}")
    output = build / "d3d11.dll"
    if not output.is_file():
        raise BuildError(f"linker did not produce {output}")
    return output


def build(
    plan: dict[str, Any],
    *,
    source: Path,
    generated_assets: Path,
    third_party_objects: Path,
    toolchain: dict[str, Path],
    output_dir: Path,
) -> dict[str, Any]:
    output_dir = output_dir.resolve()
    if output_dir.exists() and any(output_dir.iterdir()):
        raise BuildError(f"output directory must be absent or empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    work = output_dir / "work"
    log_dir = output_dir / "logs"
    candidate_dir = output_dir / "candidate"
    for directory in (work, log_dir, candidate_dir):
        directory.mkdir(parents=True, exist_ok=True)
    validate(
        plan,
        source=source,
        generated_assets=generated_assets,
        third_party_objects=third_party_objects,
        toolchain=toolchain,
    )
    stage1 = plan["stage1"]
    stage2 = plan["stage2"]
    stage3 = plan.get("stage3")
    c_compiler = Path(toolchain.get("clang", toolchain["clangxx"]))
    source1 = work / "stage1" / "src"
    objects1 = work / "stage1" / "objects"
    build1 = work / "stage1" / "build"
    source2 = work / "stage2" / "src"
    objects2 = work / "stage2" / "objects"
    build2 = work / "stage2" / "build"
    shutil.copytree(source, source1)
    if tree_manifest(source1)["sha256"] != plan["sourcePin"]["cleanTreeSHA256"]:
        raise BuildError("copied source tree does not match the clean source pin")
    for patch in plan["basePatches"]:
        apply_patch(source1, resolve_plan_path(patch["path"]), log_dir)
    apply_compatibility_edits(source1, stage1["compatibilityEdits"])
    vendor_generated_assets(source1, generated_assets, stage1["generatedAssets"])
    if tree_manifest(source1)["sha256"] != stage1["patchedTreeSHA256"]:
        raise BuildError("stage 1 patched tree SHA-256 does not match the build plan")
    verify_source_hashes(source1, stage1["compile"], "stage1")
    values1 = token_values(
        source=source1,
        objects=objects1,
        build=build1,
        third_party=third_party_objects,
        toolchain=toolchain,
    )
    compile_stage(
        stage1["compile"],
        source=source1,
        objects=objects1,
        log_dir=log_dir,
        values=values1,
        c_compiler=c_compiler,
    )
    linked1 = link_stage(
        stage1["link"]["rspLines"],
        objects=objects1,
        build=build1,
        source=source1,
        third_party=third_party_objects,
        toolchain=toolchain,
        log_dir=log_dir,
        label="stage1",
    )
    if sha256_file(linked1) != stage1["candidateSHA256"]:
        raise BuildError("stage 1 candidate SHA-256 does not match the verified base build")

    shutil.copytree(source1, source2)
    apply_patch(source2, resolve_plan_path(stage2["patch"]["path"]), log_dir)
    if tree_manifest(source2)["sha256"] != stage2["patchedTreeSHA256"]:
        raise BuildError("stage 2 patched tree SHA-256 does not match the build plan")
    verify_source_hashes(source2, stage2["compile"], "stage2")
    shutil.copytree(objects1, objects2)
    values2 = token_values(
        source=source2,
        objects=objects2,
        build=build2,
        third_party=third_party_objects,
        toolchain=toolchain,
    )
    compile_stage(
        stage2["compile"],
        source=source2,
        objects=objects2,
        log_dir=log_dir,
        values=values2,
        c_compiler=c_compiler,
    )
    linked2 = link_stage(
        stage2["link"]["rspLines"],
        objects=objects2,
        build=build2,
        source=source2,
        third_party=third_party_objects,
        toolchain=toolchain,
        log_dir=log_dir,
        label="stage2",
    )
    if sha256_file(linked2) != stage2["candidateSHA256"]:
        raise BuildError("stage 2 candidate SHA-256 does not match the verified payload")
    final = linked2
    maps = {
        "stage1": str(build1 / "d3d11.map"),
        "stage2": str(build2 / "d3d11.map"),
    }
    limitations = [
        "Third-party objects are reused from the explicitly supplied authenticated tree; they are hash-checked but not rebuilt from source.",
        "The DirectXTK generated SimpleMath.inl is copied from the explicitly supplied generated-assets tree.",
        "This is a host Clang/lld cross-build, not an MSVC release build.",
        "The TextPrinter shader patch is a separate payload change and is not applied by this DLL build.",
        "No Wine, game, launcher, install, download, or installed-state action is performed.",
    ]
    if stage3 is not None:
        source3 = work / "stage3" / "src"
        objects3 = work / "stage3" / "objects"
        build3 = work / "stage3" / "build"
        shutil.copytree(source2, source3)
        for patch in stage3["patches"]:
            apply_patch(source3, resolve_plan_path(patch["path"]), log_dir)
        if tree_manifest(source3)["sha256"] != stage3["patchedTreeSHA256"]:
            raise BuildError("stage 3 patched tree SHA-256 does not match the build plan")
        verify_source_hashes(source3, stage3["compile"], "stage3")
        # Stage 3 must not reuse stage-2 first-party objects: its layout changes
        # make them ABI-incompatible, so the object directory starts empty and
        # every listed translation unit is compiled again from the stage-3 tree.
        values3 = token_values(
            source=source3,
            objects=objects3,
            build=build3,
            third_party=third_party_objects,
            toolchain=toolchain,
        )
        compile_stage(
            stage3["compile"],
            source=source3,
            objects=objects3,
            log_dir=log_dir,
            values=values3,
            c_compiler=c_compiler,
        )
        linked3 = link_stage(
            stage3["link"]["rspLines"],
            objects=objects3,
            build=build3,
            source=source3,
            third_party=third_party_objects,
            toolchain=toolchain,
            log_dir=log_dir,
            label="stage3",
        )
        if sha256_file(linked3) != stage3["candidateSHA256"]:
            raise BuildError("stage 3 candidate SHA-256 does not match the verified payload")
        final = linked3
        maps["stage3"] = str(build3 / "d3d11.map")
        limitations.append(
            "Stage 3 recompiles every first-party translation unit from the fully "
            "patched tree; stage-2 first-party objects are not reused because the "
            "CommandListState and IfCommand layout changes make them ABI-incompatible."
        )
    candidate = candidate_dir / "d3d11.dll"
    shutil.copy2(final, candidate)
    manifest = {
        "schemaVersion": 1,
        "status": "success",
        "sourcePin": plan["sourcePin"],
        "basePatches": plan["basePatches"],
        "stage2Patch": stage2["patch"],
        "finalStage": 3 if stage3 is not None else 2,
        "candidate": {
            "path": str(candidate),
            "size": candidate.stat().st_size,
            "sha256": sha256_file(candidate),
        },
        "maps": maps,
        "limitations": limitations,
    }
    if stage3 is not None:
        manifest["stage3Patches"] = stage3["patches"]
    (output_dir / "BUILD-MANIFEST.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--generated-assets", type=Path, required=True)
    parser.add_argument("--third-party-objects", type=Path, required=True)
    parser.add_argument("--clangxx", type=Path, required=True)
    parser.add_argument(
        "--clang",
        type=Path,
        help="C driver for .c translation units (default: the sibling clang of --clangxx)",
    )
    parser.add_argument("--clang-resource", type=Path, required=True)
    parser.add_argument("--msvc-include", type=Path, required=True)
    parser.add_argument("--msvc-lib", type=Path, required=True)
    parser.add_argument("--windows-sdk-include", type=Path, required=True)
    parser.add_argument("--windows-sdk-lib", type=Path, required=True)
    parser.add_argument("--lld-link", type=Path, required=True)
    parser.add_argument(
        "--lld-library-path",
        type=Path,
        help="directory containing the lld-link sibling libraries (DYLD_LIBRARY_PATH)",
    )
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--check", action="store_true", help="validate every input and stop")
    args = parser.parse_args(argv)
    clang = args.clang
    if clang is None:
        sibling = args.clangxx.with_name("clang")
        clang = sibling if sibling.is_file() else args.clangxx
    toolchain = {
        "clang": clang,
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
    try:
        plan = load_plan(args.plan)
        validate(
            plan,
            source=args.source,
            generated_assets=args.generated_assets,
            third_party_objects=args.third_party_objects,
            toolchain=toolchain,
        )
        if args.check:
            print("xxmi-rebuild-payload: all pinned inputs are present and hash-checked")
            return 0
        if args.output_dir is None:
            raise BuildError("--output-dir is required unless --check is used")
        manifest = build(
            plan,
            source=args.source,
            generated_assets=args.generated_assets,
            third_party_objects=args.third_party_objects,
            toolchain=toolchain,
            output_dir=args.output_dir,
        )
    except BuildError as exc:
        print(f"xxmi-rebuild-payload: {exc}", file=sys.stderr)
        return 1
    print(f"candidate: {manifest['candidate']['path']}")
    print(f"sha256: {manifest['candidate']['sha256']}")
    print(f"size: {manifest['candidate']['size']} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
