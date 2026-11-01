#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Build an experimental SRMI DLL from patches 0001-0007 plus optional extras.

The checked-in payload build plan stays authoritative for the clean source pin,
compatibility edits, generated assets, third-party objects, compile commands
and link response file. This experimental builder applies the cursor patch
(0009) and any optional ``--conditional-patch`` (0010) or repeated
``--extra-patch`` entries on top of the verified stage-2 tree, recomputes every
affected hash, and rebuilds every first-party translation unit instead of
reusing first-party stage objects. The CommandListState and IfCommand layout
changes make the stage-2 objects ABI-incompatible with the patched headers.

Without an optional patch the builder reproduces the cursor-only candidate.
With ``--conditional-patch`` it links the combined 0001-0007 + 0009 + 0010
candidate and additionally requires the conditional fail-closed log string.

No download, install, Wine, game, launcher, live-prefix, or Git action occurs.
Only host Clang, lld-link, patch and static PE checks are used.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
REBUILD_SCRIPT = REPO_ROOT / "scripts" / "xxmi-rebuild-payload.py"
DEFAULT_PLAN = REPO_ROOT / "compat" / "xxmi" / "build" / "payload-build-plan.json"
DEFAULT_CURSOR_PATCH = REPO_ROOT / "compat" / "xxmi" / "patches" / "0009-srmi-cursor-coordinate-contract.patch"
DEFAULT_CONDITIONAL_PATCH = (
    REPO_ROOT / "compat" / "xxmi" / "patches" / "0010-srmi-invalid-conditional-fail-closed.patch"
)
DEFAULT_SOURCE = Path(
    "/private/tmp/xxmi-libs-v1.2.2-source/"
    "XXMI-Libs-Package-a7847eae82aaac32175c9a7d199673d5c9323bcd"
)
DEFAULT_GENERATED_ASSETS = Path("/private/tmp/xxmi-libs-v1.2.2-build")
DEFAULT_THIRD_PARTY_OBJECTS = Path("/private/tmp/srmi-cxx-smoke-20261030")
DEFAULT_REFERENCE = Path(
    "/Users/angelo/Projects/Personal/macgacha-modsupport/macgacha-srmi-poc/"
    "artifacts/srmi-ngx-context-boundary-sdk-20261031/candidate/d3d11.dll"
)
DEFAULT_CLANG = Path("/usr/bin/clang")
DEFAULT_CLANGXX = Path("/usr/bin/clang++")
DEFAULT_CLANG_RESOURCE = Path(
    "/Applications/Xcode.app/Contents/Developer/Toolchains/"
    "XcodeDefault.xctoolchain/usr/lib/clang/21/include"
)
DEFAULT_MSVC_INCLUDE = Path(
    "/private/tmp/msvc-14.44-headers/Contents/VC/Tools/MSVC/14.44.35207/include"
)
DEFAULT_MSVC_LIB = Path(
    "/private/tmp/msvc-14.44-libs/Contents/VC/Tools/MSVC/14.44.35207/lib/x64"
)
DEFAULT_WINDOWS_SDK_INCLUDE = Path("/private/tmp/windows-sdk-cpp/c/Include/10.0.26100.0")
DEFAULT_WINDOWS_SDK_LIB = Path("/private/tmp/windows-sdk-x64-libs/c")
DEFAULT_LLD_LINK = Path(
    "/Users/angelo/.rustup/toolchains/stable-aarch64-apple-darwin/lib/"
    "rustlib/aarch64-apple-darwin/bin/gcc-ld/lld-link"
)
DEFAULT_OBJDUMP = Path("/usr/bin/objdump")

CURSOR_LOG_STRINGS = (
    "UpdateWindowInfo: GetClientRect failed",
    "UpdateCursorInfo: GetCursorInfo failed",
    "UpdateCursorInfo: ScreenToClient failed",
)

CONDITIONAL_LOG_STRINGS = ("Invalid conditional expression; block disabled",)
# Patch 0010 logs the message through a wide L"..." literal, so the PE stores
# UTF-16LE code units rather than the UTF-8 bytes used by the cursor patch.
CONDITIONAL_LOG_ENCODING = "utf-16-le"

PATCH_LABEL = re.compile(r"^(?P<number>\d{4})-")


class BuildError(RuntimeError):
    pass


def patch_label(path: Path) -> str:
    match = PATCH_LABEL.match(Path(path).name)
    return match.group("number") if match else Path(path).name


def join_labels(labels: list[str]) -> str:
    if not labels:
        raise BuildError("a candidate must apply at least one patch")
    if len(labels) == 1:
        return labels[0]
    if len(labels) == 2:
        return f"{labels[0]} and {labels[1]}"
    return ", ".join(labels[:-1]) + f" and {labels[-1]}"


def patch_plan_description(extra_labels: list[str]) -> str:
    return join_labels(["0001-0007", "0009", *extra_labels])


def build_purpose(extra_labels: list[str]) -> str:
    return (
        "ABI-consistent experimental SRMI candidate with patches "
        f"{patch_plan_description(extra_labels)}"
    )


def experimental_purpose(extra_labels: list[str]) -> str:
    return (
        "experimental SRMI candidate with patches "
        f"{patch_plan_description(extra_labels)}"
    )


def digest_records(records: list[tuple[str, ...]]) -> str:
    digest = hashlib.sha256()
    for record in records:
        for value in record:
            digest.update(value.encode("utf-8"))
            digest.update(b"\0")
        digest.update(b"\n")
    return digest.hexdigest()


def missing_static_strings(
    data: bytes, values: tuple[str, ...], *, encoding: str = "utf-8"
) -> list[str]:
    return [value for value in values if value.encode(encoding) not in data]


def optional_patch_paths(
    conditional_patch: Path | None, extra_patches: list[Path]
) -> list[Path]:
    return ([conditional_patch] if conditional_patch is not None else []) + list(
        extra_patches
    )


def resolve_optional_patch(path: Path) -> Path:
    return path if path.is_absolute() else REPO_ROOT / path


def check_optional_patches(
    conditional_patch: Path | None, extra_patches: list[Path]
) -> None:
    optional = optional_patch_paths(conditional_patch, extra_patches)
    seen: set[Path] = set()
    for path in optional:
        if not resolve_optional_patch(path).is_file():
            raise BuildError(f"missing optional patch: {path}")
        resolved = resolve_optional_patch(path).resolve()
        if resolved in seen:
            raise BuildError(f"duplicate optional patch: {path}")
        seen.add(resolved)


def utc_stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def utc_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def load_rebuild_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("xxmi_rebuild_payload", REBUILD_SCRIPT)
    if spec is None or spec.loader is None:
        raise BuildError(f"cannot load {REBUILD_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def object_canonical_sha256(path: Path) -> str:
    data = path.read_bytes()
    if len(data) >= 8:
        data = data[:4] + b"\0" * 4 + data[8:]
    return hashlib.sha256(data).hexdigest()


def tool_info(
    path: Path, *, executable: bool = False, env: dict[str, str] | None = None
) -> dict[str, Any]:
    resolved = path.resolve()
    info: dict[str, Any] = {"path": str(resolved), "exists": resolved.is_file()}
    if not resolved.is_file():
        return info
    info["sha256"] = sha256_file(resolved)
    if executable:
        proc = subprocess.run(
            [str(resolved), "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        output = (proc.stdout or proc.stderr).strip().splitlines()
        info["version"] = output[:3]
        info["versionReturnCode"] = proc.returncode
    return info


def directory_info(path: Path) -> dict[str, Any]:
    return {
        "path": str(path.resolve()),
        "exists": path.is_dir(),
        "entryCount": sum(1 for _ in path.rglob("*")) if path.is_dir() else 0,
    }


def pe_exports(path: Path, objdump: Path) -> list[str]:
    proc = subprocess.run(
        [str(objdump), "-p", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        raise BuildError(f"objdump -p failed for {path}: {proc.stderr}")
    marker = proc.stdout.find("Export Table:")
    if marker < 0:
        return []
    names = []
    for line in proc.stdout[marker:].splitlines()[1:]:
        match = re.match(r"^\s+\d+\s+0x[0-9a-fA-F]+\s+(\S+)\s*$", line)
        if match:
            names.append(match.group(1))
    return names


def pe_imports(path: Path, objdump: Path) -> list[str]:
    proc = subprocess.run(
        [str(objdump), "-p", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        raise BuildError(f"objdump -p failed for {path}: {proc.stderr}")
    start = proc.stdout.find("The Import Tables:")
    if start < 0:
        return []
    end = proc.stdout.find("Export Table:", start)
    block = proc.stdout[start:end if end >= 0 else len(proc.stdout)]
    current = None
    entries = []
    for line in block.splitlines():
        match = re.match(r"^\s*DLL Name:\s*(\S+)\s*$", line)
        if match:
            current = match.group(1)
            entries.append(current)
            continue
        match = re.match(r"^\s+\d+\s+([A-Za-z_?@$][^\s]*)\s*$", line)
        if match and current:
            entries.append(f"{current}!{match.group(1)}")
    return entries


def import_parity(candidate: Path, reference: Path, objdump: Path) -> dict[str, Any]:
    reference_exports = sorted(set(pe_exports(reference, objdump)))
    candidate_exports = sorted(set(pe_exports(candidate, objdump)))
    reference_imports = sorted(set(pe_imports(reference, objdump)))
    candidate_imports = sorted(set(pe_imports(candidate, objdump)))
    result = {
        "reference": str(reference),
        "referenceExports": reference_exports,
        "candidateExports": candidate_exports,
        "exportsEqual": reference_exports == candidate_exports,
        "missingExports": sorted(set(reference_exports) - set(candidate_exports)),
        "extraExports": sorted(set(candidate_exports) - set(reference_exports)),
        "referenceImports": reference_imports,
        "candidateImports": candidate_imports,
        "importsEqual": reference_imports == candidate_imports,
        "missingImports": sorted(set(reference_imports) - set(candidate_imports)),
        "extraImports": sorted(set(candidate_imports) - set(reference_imports)),
    }
    if not result["exportsEqual"]:
        raise BuildError(
            "export parity with the reference candidate failed: "
            f"missing={result['missingExports']} extra={result['extraExports']}"
        )
    if not result["importsEqual"]:
        raise BuildError(
            "import parity with the reference candidate failed: "
            f"missing={result['missingImports']} extra={result['extraImports']}"
        )
    return result


def apply_cursor_patch(module: ModuleType, source: Path, patch: Path, log_dir: Path) -> None:
    module.apply_patch(source, patch, log_dir)


def patch_record(module: ModuleType, path: Path, role: str) -> dict[str, Any]:
    resolved = module.resolve_plan_path(str(path))
    return {
        "path": str(path),
        "resolvedPath": str(resolved),
        "sha256": sha256_file(resolved),
        "role": role,
    }


def compile_records(plan: dict[str, Any]) -> list[dict[str, Any]]:
    records = []
    seen = set()
    for command in plan["stage1"]["compile"]:
        records.append({"template": command, "stage": "stage1"})
        seen.add(command["source"])
    for command in plan["stage2"]["compile"]:
        if command["source"] in seen:
            continue
        records.append({"template": command, "stage": "stage2"})
        seen.add(command["source"])
    return records


def tree_digest(root: Path) -> dict[str, Any]:
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
    return {"root": str(root), "fileCount": len(entries), "sha256": digest.hexdigest()}


def lld_environment(lld_link: Path) -> dict[str, str]:
    environment = os.environ.copy()
    try:
        toolchain_lib = lld_link.resolve().parents[4]
    except IndexError:
        return environment
    if (toolchain_lib / "libLLVM.dylib").is_file():
        environment["DYLD_LIBRARY_PATH"] = str(toolchain_lib)
    return environment


def build_once(
    module: ModuleType,
    plan: dict[str, Any],
    *,
    source: Path,
    generated_assets: Path,
    third_party_objects: Path,
    toolchain: dict[str, Path],
    clang: Path,
    cursor_patch: Path,
    conditional_patch: Path | None,
    extra_patches: list[Path],
    reference: Path,
    objdump: Path,
    output: Path,
    plan_path: Path,
    do_consistency: bool,
    invocation: list[str],
) -> dict[str, Any]:
    work = output / "work"
    logs = output / "logs"
    candidate_dir = output / "candidate"
    source_tree = work / "src"
    objects = work / "objects"
    build_dir = work / "build"
    for directory in (work, logs, candidate_dir, build_dir):
        directory.mkdir(parents=True, exist_ok=True)

    plan_path = module.resolve_plan_path(str(plan_path))
    source_pin = plan["sourcePin"]
    clean_tree = tree_digest(source)
    if clean_tree["sha256"] != source_pin["cleanTreeSHA256"]:
        raise BuildError(
            "clean source tree SHA-256 mismatch: "
            f"got {clean_tree['sha256']}, expected {source_pin['cleanTreeSHA256']}"
        )

    shutil.copytree(source, source_tree)
    copied_tree = tree_digest(source_tree)
    if copied_tree["sha256"] != source_pin["cleanTreeSHA256"]:
        raise BuildError("copied clean source tree does not match the source pin")

    extra_patch_paths = optional_patch_paths(conditional_patch, extra_patches)
    resolved_optional_patches = [
        module.resolve_plan_path(str(path)) for path in extra_patch_paths
    ]
    extra_labels = [patch_label(path) for path in extra_patch_paths]
    purpose = build_purpose(extra_labels)

    patches = []
    for entry in plan["basePatches"]:
        patch_path = module.resolve_plan_path(entry["path"])
        module.apply_patch(source_tree, patch_path, logs)
        patches.append(patch_record(module, Path(entry["path"]), "base"))
    stage2_patch = plan["stage2"]["patch"]
    stage2_path = module.resolve_plan_path(stage2_patch["path"])
    module.apply_patch(source_tree, stage2_path, logs)
    patches.append(patch_record(module, Path(stage2_patch["path"]), "ngx-context-boundary"))
    apply_cursor_patch(module, source_tree, cursor_patch, logs)
    patches.append(
        patch_record(module, cursor_patch, "cursor-coordinate-contract")
    )
    resolved_index = 0
    if conditional_patch is not None:
        module.apply_patch(source_tree, resolved_optional_patches[resolved_index], logs)
        resolved_index += 1
        patches.append(
            patch_record(module, conditional_patch, "conditional-fail-closed")
        )
    for index, extra_patch in enumerate(extra_patches, start=1):
        module.apply_patch(source_tree, resolved_optional_patches[resolved_index], logs)
        resolved_index += 1
        patches.append(patch_record(module, extra_patch, f"extra-{index}"))
    patch_set_digest = digest_records(
        [(entry["role"], entry["path"], entry["sha256"]) for entry in patches]
    )

    module.apply_compatibility_edits(source_tree, plan["stage1"]["compatibilityEdits"])
    module.vendor_generated_assets(
        source_tree, generated_assets, plan["stage1"]["generatedAssets"]
    )
    patched_tree = tree_digest(source_tree)

    values = module.token_values(
        source=source_tree,
        objects=objects,
        build=build_dir,
        third_party=third_party_objects,
        toolchain=toolchain,
    )

    if objects.exists() and any(objects.iterdir()):
        raise BuildError("first-party object directory must start empty")
    compile_entries = []
    objects.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update({"LC_ALL": "C", "TZ": "UTC", "SOURCE_DATE_EPOCH": "0"})
    templates = compile_records(plan)
    for entry in templates:
        template = entry["template"]
        relative = template["source"]
        source_path = source_tree / relative
        if not source_path.is_file():
            raise BuildError(f"missing first-party source after patches: {relative}")
        source_hash = sha256_file(source_path)
        object_path = objects / template["object"]
        argv = module.expand(template["argv"], values)
        if relative.endswith(".c"):
            argv[0] = str(clang)
        result = subprocess.run(
            argv,
            cwd=str(source_tree),
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        log_path = logs / f"compile-{template['object']}.log"
        log_path.write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode != 0:
            errors = [
                line
                for line in (result.stdout + result.stderr).splitlines()
                if "error:" in line or "fatal error:" in line
            ][:30]
            raise BuildError(
                f"compile failed for {relative}\nlog: {log_path}\n" + "\n".join(errors)
            )
        if not object_path.is_file():
            raise BuildError(f"compiler did not produce {object_path}")
        compile_entries.append(
            {
                "source": relative,
                "sourcePath": str(source_path),
                "sourceSHA256": source_hash,
                "object": template["object"],
                "objectPath": str(object_path),
                "objectSHA256": sha256_file(object_path),
                "objectCanonicalSHA256": object_canonical_sha256(object_path),
                "stageTemplate": entry["stage"],
                "argv": argv,
                "log": str(log_path),
                "rebuiltFromCurrentSource": True,
                "reusedFromStageObject": False,
            }
        )

    expected_objects = {entry["template"]["object"] for entry in templates}
    actual_objects = {path.name for path in objects.iterdir() if path.is_file()}
    if actual_objects != expected_objects:
        raise BuildError(
            "first-party object set mismatch: "
            f"missing={sorted(expected_objects - actual_objects)} "
            f"extra={sorted(actual_objects - expected_objects)}"
        )
    if len(compile_entries) != len(expected_objects):
        raise BuildError("duplicate first-party compile record")

    third_party_entries = []
    for entry in plan["stage1"]["thirdPartyObjects"]:
        path = third_party_objects / entry["path"]
        if not path.is_file():
            raise BuildError(f"missing third-party object: {path}")
        actual = sha256_file(path)
        if actual != entry["sha256"]:
            raise BuildError(f"third-party object SHA-256 mismatch: {path}")
        third_party_entries.append(
            {
                "path": entry["path"],
                "absolutePath": str(path),
                "sha256": actual,
                "label": entry.get("label"),
                "reused": True,
                "authenticated": True,
            }
        )

    object_set_digest = digest_records(
        [
            (
                entry["source"],
                entry["sourceSHA256"],
                entry["object"],
                entry["objectSHA256"],
            )
            for entry in compile_entries
        ]
    )
    third_party_set_digest = digest_records(
        [(entry["path"], entry["sha256"]) for entry in third_party_entries]
    )

    rsp_path = build_dir / "xxmi-cursor-candidate.rsp"
    rsp_lines = module.expand(plan["stage2"]["link"]["rspLines"], values)
    rsp_path.write_text("\n".join(rsp_lines) + "\n", encoding="utf-8")
    link_environment = lld_environment(toolchain["lld_link"])
    link_result = subprocess.run(
        [str(toolchain["lld_link"]), f"@{rsp_path}"],
        cwd=str(build_dir),
        env=link_environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    link_log = logs / "link.log"
    link_log.write_text(link_result.stdout + link_result.stderr, encoding="utf-8")
    if link_result.returncode != 0:
        raise BuildError(
            f"link failed\nlog: {link_log}\n{link_result.stdout + link_result.stderr}"
        )
    linked = build_dir / "d3d11.dll"
    map_path = build_dir / "d3d11.map"
    if not linked.is_file() or not map_path.is_file():
        raise BuildError("linker did not produce d3d11.dll and d3d11.map")

    candidate = candidate_dir / "d3d11.dll"
    shutil.copy2(linked, candidate)
    candidate_hash = sha256_file(candidate)
    baseline_candidate = plan["stage2"]["candidateSHA256"]
    if candidate_hash == baseline_candidate:
        raise BuildError("experimental candidate unexpectedly equals the stage-2 baseline")
    reference_hash = sha256_file(reference)
    if reference_hash != baseline_candidate:
        raise BuildError(
            f"reference candidate hash {reference_hash} does not match the shipped {baseline_candidate}"
        )

    parity = import_parity(candidate, reference, objdump)
    candidate_bytes = candidate.read_bytes()
    missing_strings = missing_static_strings(candidate_bytes, CURSOR_LOG_STRINGS)
    if missing_strings:
        raise BuildError(f"cursor patch strings missing from candidate: {missing_strings}")
    conditional_missing = (
        missing_static_strings(
            candidate_bytes,
            CONDITIONAL_LOG_STRINGS,
            encoding=CONDITIONAL_LOG_ENCODING,
        )
        if conditional_patch is not None
        else []
    )
    if conditional_missing:
        raise BuildError(
            "conditional patch strings missing from candidate: "
            f"{conditional_missing}"
        )

    consistency: dict[str, Any] | None = None
    if do_consistency:
        first_objects = {
            entry["object"]: object_canonical_sha256(objects / entry["object"])
            for entry in compile_entries
        }
        first_raw_objects = {
            entry["object"]: entry["objectSHA256"] for entry in compile_entries
        }
        first_candidate = candidate_hash
        rebuild_objects = work / "objects-rebuild"
        rebuild_objects.mkdir(parents=True, exist_ok=True)
        rebuild_logs = logs / "rebuild"
        rebuild_logs.mkdir(parents=True, exist_ok=True)
        rebuild_entries = []
        for entry in compile_entries:
            object_path = rebuild_objects / entry["object"]
            argv = [
                str(object_path) if part == entry["objectPath"] else part
                for part in entry["argv"]
            ]
            result = subprocess.run(
                argv,
                cwd=str(source_tree),
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            log_path = rebuild_logs / f"compile-{entry['object']}.log"
            log_path.write_text(result.stdout + result.stderr, encoding="utf-8")
            if result.returncode != 0:
                raise BuildError(f"consistency rebuild failed for {entry['source']}")
            raw_hash = sha256_file(object_path)
            canonical_hash = object_canonical_sha256(object_path)
            rebuild_entries.append(
                {
                    "object": entry["object"],
                    "objectPath": str(object_path),
                    "objectSHA256": raw_hash,
                    "objectCanonicalSHA256": canonical_hash,
                    "rawTimestampMatched": raw_hash == first_raw_objects[entry["object"]],
                    "matchesFirstBuild": canonical_hash == first_objects[entry["object"]],
                }
            )
        rebuild_dir = work / "build-rebuild"
        rebuild_dir.mkdir(parents=True, exist_ok=True)
        rebuild_rsp = rebuild_dir / "xxmi-cursor-candidate.rsp"
        rebuild_values = module.token_values(
            source=source_tree,
            objects=rebuild_objects,
            build=rebuild_dir,
            third_party=third_party_objects,
            toolchain=toolchain,
        )
        rebuild_rsp.write_text(
            "\n".join(module.expand(plan["stage2"]["link"]["rspLines"], rebuild_values)) + "\n",
            encoding="utf-8",
        )
        rebuild_link = subprocess.run(
            [str(toolchain["lld_link"]), f"@{rebuild_rsp}"],
            cwd=str(rebuild_dir),
            env=link_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        (rebuild_logs / "link.log").write_text(
            rebuild_link.stdout + rebuild_link.stderr, encoding="utf-8"
        )
        if rebuild_link.returncode != 0:
            raise BuildError("consistency rebuild link failed")
        rebuild_candidate = rebuild_dir / "d3d11.dll"
        rebuild_hash = sha256_file(rebuild_candidate)
        consistency = {
            "objectsEqualIgnoringCOFFTimestamp": all(
                item["matchesFirstBuild"] for item in rebuild_entries
            ),
            "rawObjectBytesEqual": all(
                item["rawTimestampMatched"] for item in rebuild_entries
            ),
            "candidateEqual": rebuild_hash == first_candidate,
            "firstCandidateSHA256": first_candidate,
            "rebuildCandidateSHA256": rebuild_hash,
            "rebuildObjects": rebuild_entries,
            "rebuildLogs": str(rebuild_logs),
            "rebuildObjectsRoot": str(rebuild_objects),
            "note": (
                "Clang writes a wall-clock COFF TimeDateStamp in object headers; "
                "comparison ignores bytes 4-7 of each COFF object. The linked "
                "candidate is byte-identical."
            ),
        }
        if not consistency["objectsEqualIgnoringCOFFTimestamp"]:
            raise BuildError("consistency rebuild produced different first-party objects")
        if not consistency["candidateEqual"]:
            raise BuildError("consistency rebuild produced a different candidate")

    conditional_record = next(
        (entry for entry in patches if entry["role"] == "conditional-fail-closed"),
        None,
    )

    experimental_plan = {
        "schemaVersion": 1,
        "purpose": experimental_purpose(extra_labels),
        "buildInvocation": invocation,
        "derivedFrom": {
            "plan": str(plan_path),
            "planSHA256": sha256_file(plan_path),
            "baselineStage2Patch": plan["stage2"]["patch"],
            "baselinePatchedTreeSHA256": plan["stage2"]["patchedTreeSHA256"],
            "baselineCandidateSHA256": baseline_candidate,
            "conditionalPatch": conditional_record,
            "extraPatches": [
                entry for entry in patches if entry["role"].startswith("extra-")
            ],
        },
        "sourcePin": source_pin,
        "patches": patches,
        "patchSetSHA256": patch_set_digest,
        "patchedTreeSHA256": patched_tree["sha256"],
        "patchedFileCount": patched_tree["fileCount"],
        "rehashedAfterPatching": True,
        "toolchain": {
            "clangxx": str(toolchain["clangxx"]),
            "clangResource": str(toolchain["clang_resource"]),
            "msvcInclude": str(toolchain["msvc_include"]),
            "msvcLib": str(toolchain["msvc_lib"]),
            "windowsSdkInclude": str(toolchain["windows_sdk_include"]),
            "windowsSdkLib": str(toolchain["windows_sdk_lib"]),
            "lldLink": str(toolchain["lld_link"]),
        },
        "compile": [
            {
                "source": entry["source"],
                "sourcePath": entry["sourcePath"],
                "sourceSHA256": entry["sourceSHA256"],
                "object": entry["object"],
                "objectPath": entry["objectPath"],
                "objectSHA256": entry["objectSHA256"],
                "objectCanonicalSHA256": entry["objectCanonicalSHA256"],
                "argv": entry["argv"],
            }
            for entry in compile_entries
        ],
        "thirdPartyObjects": third_party_entries,
        "linkRspLines": plan["stage2"]["link"]["rspLines"],
        "referenceCandidateSHA256": baseline_candidate,
    }
    experimental_plan_path = output / "EXPERIMENTAL-PLAN.json"
    experimental_plan_path.write_text(
        json.dumps(experimental_plan, indent=2) + "\n", encoding="utf-8"
    )

    abi_note = (
        "The CommandListState layout change (0009) makes the candidate "
        "ABI-incompatible with stage-2 first-party objects; only the fully "
        "rebuilt object set may be linked."
        if conditional_patch is None
        else "The CommandListState (0009) and IfCommand (0010) layout changes make "
        "the candidate ABI-incompatible with stage-2 first-party objects; only "
        "the fully rebuilt object set may be linked."
    )
    limitations = [
        "Third-party objects (DirectXTK, NktHookLib, pcre2 and the MSVC assembly helper) are hash-authenticated and reused, not rebuilt from source.",
        "The DirectXTK generated SimpleMath.inl is copied from the explicitly supplied authenticated build tree.",
        "This is a host Apple Clang/lld cross-build, not an MSVC release build.",
        "Patch 0008 changes the SRMI TextPrinter shader payload and is not part of this DLL build.",
        abi_note,
        "Import/export parity is a static PE check against the shipped 52bac2fe candidate, not behavioral equivalence.",
        "No Wine, game, launcher, install, download, live-prefix, or runtime action was performed, and no live mod symptom is claimed fixed.",
    ]
    if conditional_patch is not None:
        limitations.append(
            "The conditional fail-closed correction keeps an invalid if/elif node "
            "with expression_valid false, runs neither branch and discards both "
            "branches during optimisation. It does not add missing variables, "
            "reproduce a live visual symptom or make an imported mod functional."
        )

    manifest = {
        "schemaVersion": 1,
        "status": "success",
        "generatedUtc": utc_iso(),
        "purpose": purpose,
        "buildInvocation": invocation,
        "source": {
            "pin": source_pin,
            "verifiedTree": clean_tree,
        },
        "patches": patches,
        "conditionalPatch": conditional_record,
        "patchedTree": patched_tree,
        "experimentalPlan": {
            "path": str(experimental_plan_path),
            "sha256": sha256_file(experimental_plan_path),
        },
        "provenance": {
            "buildInvocation": invocation,
            "patchSet": {
                "count": len(patches),
                "sha256": patch_set_digest,
            },
            "firstParty": {
                "count": len(compile_entries),
                "expectedCount": len(templates),
                "objectSetSHA256": object_set_digest,
                "fullyRebuiltFromPatchedTree": True,
                "reusedStageObjects": False,
            },
            "thirdParty": {
                "count": len(third_party_entries),
                "objectSetSHA256": third_party_set_digest,
            },
            "tools": {
                "clang": tool_info(clang, executable=True),
                "clangxx": tool_info(toolchain["clangxx"], executable=True),
                "lldLink": tool_info(
                    toolchain["lld_link"], executable=True, env=link_environment
                ),
                "patch": tool_info(Path("/usr/bin/patch"), executable=True),
                "objdump": tool_info(objdump, executable=True),
            },
            "tokenRoots": {
                "source": str(source.resolve()),
                "generatedAssets": str(generated_assets.resolve()),
                "thirdPartyObjects": str(third_party_objects.resolve()),
                "clangResource": directory_info(toolchain["clang_resource"]),
                "msvcInclude": directory_info(toolchain["msvc_include"]),
                "msvcLib": directory_info(toolchain["msvc_lib"]),
                "windowsSdkInclude": directory_info(toolchain["windows_sdk_include"]),
                "windowsSdkLib": directory_info(toolchain["windows_sdk_lib"]),
            },
            "generatedAssets": [
                {
                    "path": entry["path"],
                    "sha256": sha256_file(source_tree / entry["path"]),
                }
                for entry in plan["stage1"]["generatedAssets"]
            ],
            "allFirstPartyObjectsRebuilt": True,
            "firstPartyObjectCount": len(compile_entries),
            "thirdPartyObjectCount": len(third_party_entries),
        },
        "firstPartyCompile": compile_entries,
        "thirdPartyObjects": third_party_entries,
        "link": {
            "command": [str(toolchain["lld_link"]), f"@{rsp_path}"],
            "rsp": str(rsp_path),
            "rspSHA256": sha256_file(rsp_path),
            "output": str(linked),
            "outputSHA256": sha256_file(linked),
            "map": str(map_path),
            "mapSHA256": sha256_file(map_path),
            "log": str(link_log),
            "objectCount": len(compile_entries) + len(third_party_entries),
        },
        "candidate": {
            "path": str(candidate),
            "sha256": candidate_hash,
            "size": candidate.stat().st_size,
            "baselineStage2CandidateSHA256": baseline_candidate,
            "distinctFromBaseline": candidate_hash != baseline_candidate,
        },
        "parity": parity,
        "staticVerification": {
            "cursorPatchLogStrings": list(CURSOR_LOG_STRINGS),
            "allCursorPatchLogStringsPresent": True,
            "conditionalPatchApplied": conditional_patch is not None,
            "conditionalPatchLogStrings": (
                list(CONDITIONAL_LOG_STRINGS) if conditional_patch is not None else []
            ),
            "conditionalPatchLogStringEncoding": CONDITIONAL_LOG_ENCODING,
            "allConditionalPatchLogStringsPresent": (
                True if conditional_patch is not None else None
            ),
            "candidateDiffersFromBaseline": candidate_hash != baseline_candidate,
        },
        "rebuildConsistency": consistency,
        "limitations": limitations,
    }
    manifest_path = output / "BUILD-MANIFEST.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--generated-assets", type=Path, default=DEFAULT_GENERATED_ASSETS)
    parser.add_argument(
        "--third-party-objects", type=Path, default=DEFAULT_THIRD_PARTY_OBJECTS
    )
    parser.add_argument("--cursor-patch", type=Path, default=DEFAULT_CURSOR_PATCH)
    parser.add_argument(
        "--conditional-patch",
        type=Path,
        help=(
            "optional invalid-conditional fail-closed patch (checked-in patch: "
            f"{DEFAULT_CONDITIONAL_PATCH.relative_to(REPO_ROOT)}) applied after "
            "the cursor patch; its block-disabled log string is checked in the candidate"
        ),
    )
    parser.add_argument(
        "--extra-patch",
        type=Path,
        action="append",
        default=[],
        dest="extra_patches",
        metavar="PATCH",
        help="additional patch applied after the cursor/conditional patches (repeatable)",
    )
    parser.add_argument("--reference", type=Path, default=DEFAULT_REFERENCE)
    parser.add_argument("--clang", type=Path, default=DEFAULT_CLANG)
    parser.add_argument("--clangxx", type=Path, default=DEFAULT_CLANGXX)
    parser.add_argument("--clang-resource", type=Path, default=DEFAULT_CLANG_RESOURCE)
    parser.add_argument("--msvc-include", type=Path, default=DEFAULT_MSVC_INCLUDE)
    parser.add_argument("--msvc-lib", type=Path, default=DEFAULT_MSVC_LIB)
    parser.add_argument(
        "--windows-sdk-include", type=Path, default=DEFAULT_WINDOWS_SDK_INCLUDE
    )
    parser.add_argument("--windows-sdk-lib", type=Path, default=DEFAULT_WINDOWS_SDK_LIB)
    parser.add_argument("--lld-link", type=Path, default=DEFAULT_LLD_LINK)
    parser.add_argument("--objdump", type=Path, default=DEFAULT_OBJDUMP)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument(
        "--consistency",
        action="store_true",
        help="recompile every unit and relink a second time, then compare hashes",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = create_parser()
    args = parser.parse_args(argv)
    invocation = [str(Path(__file__).resolve()), *(sys.argv[1:] if argv is None else argv)]

    toolchain = {
        "clangxx": args.clangxx,
        "clang_resource": args.clang_resource,
        "msvc_include": args.msvc_include,
        "msvc_lib": args.msvc_lib,
        "windows_sdk_include": args.windows_sdk_include,
        "windows_sdk_lib": args.windows_sdk_lib,
        "lld_link": args.lld_link,
    }
    if not args.clang.is_file():
        print(f"xxmi-build-cursor-candidate: missing clang: {args.clang}", file=sys.stderr)
        return 1
    if not args.cursor_patch.is_file():
        print(f"xxmi-build-cursor-candidate: missing cursor patch: {args.cursor_patch}", file=sys.stderr)
        return 1
    has_optional = args.conditional_patch is not None or bool(args.extra_patches)
    output_prefix = "xxmi-combined-candidate" if has_optional else "xxmi-cursor-candidate"
    output = args.output_dir or (REPO_ROOT / ".build" / f"{output_prefix}-{utc_stamp()}")
    if output.exists() and any(output.iterdir()):
        print(
            f"xxmi-build-cursor-candidate: output directory must be absent or empty: {output}",
            file=sys.stderr,
        )
        return 1
    try:
        check_optional_patches(args.conditional_patch, args.extra_patches)
        module = load_rebuild_module()
        plan = module.load_plan(args.plan)
        module.validate(
            plan,
            source=args.source,
            generated_assets=args.generated_assets,
            third_party_objects=args.third_party_objects,
            toolchain=toolchain,
        )
        manifest = build_once(
            module,
            plan,
            source=args.source,
            generated_assets=args.generated_assets,
            third_party_objects=args.third_party_objects,
            toolchain=toolchain,
            clang=args.clang,
            cursor_patch=args.cursor_patch,
            conditional_patch=args.conditional_patch,
            extra_patches=args.extra_patches,
            reference=args.reference,
            objdump=args.objdump,
            output=output.resolve(),
            plan_path=args.plan,
            do_consistency=args.consistency,
            invocation=invocation,
        )
    except BuildError as exc:
        print(f"xxmi-build-cursor-candidate: {exc}", file=sys.stderr)
        return 1
    print(f"purpose: {manifest['purpose']}")
    print(f"candidate: {manifest['candidate']['path']}")
    print(f"sha256: {manifest['candidate']['sha256']}")
    print(f"size: {manifest['candidate']['size']} bytes")
    conditional = manifest["conditionalPatch"]
    print(
        "conditional patch: "
        + (f"{conditional['path']} ({conditional['sha256']})" if conditional else "none")
    )
    print(f"manifest: {output.resolve() / 'BUILD-MANIFEST.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
