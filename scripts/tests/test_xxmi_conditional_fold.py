#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline regression tests for patch 0011 (conditional-chain folding fail-closed).

XXMI Libraries v1.2.3 folds an if/elif/else chain that drives one fixed
shader-resource slot into a ``ConditionalSlotCopyOperation`` inside
``merge_shader_resource_batches``. Upstream reads and later evaluates the
chain's expression without any notion of the ``expression_valid`` flag that
patch 0010 introduces.

The harness compiles verbatim excerpts from the authenticated v1.2.3 source
(``fixtures/xxmi-conditional-fold``): ``optimise_command_lists``, the whole
batching optimiser region from ``is_batchable_bind`` through
``merge_shader_resource_batches``, and the ``BatchDirection`` /
``ConditionalSlotBranch`` / ``ConditionalSlotCopyOperation`` declarations.
Boundary stubs replace D3D11, logging, globals, profiling, the expression
evaluator (which counts evaluations of an invalid expression) and
``IfCommand``. The ``IfCommand`` stub mirrors patch 0010's contract
(``expression_valid``; an invalid node runs neither branch, ``optimise`` and
``noop`` clear both branches and ``noop`` reports it removable); that
contract itself is proven against the real code by
``test_xxmi_conditional_contract.py``.

Two builds are compared: the pristine excerpt (upstream v1.2.3 behaviour)
and the excerpt after ``0011-srmi-conditional-fold-fail-closed.patch``. They
establish that (1) the real optimiser order already erases an invalid node
before batching, (2) without 0011 a batching call that does see an invalid
node folds it and evaluates the partial expression, and (3) with 0011 it is
never folded and never evaluated while valid chains fold unchanged.

``XXMI_LIBS_SOURCE`` may point at the full pinned clean v1.2.3 tree. When set,
it is authenticated against the build plan, the full stage-3 patch chain,
including 0011, must apply with ``--fuzz=0`` and no offset, and the patched
excerpt must appear verbatim in the result. Without it that parity test is
skipped.

This is host-native evidence of control flow, not a live rendering test.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import Any

REPO = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "xxmi-conditional-fold"
BUILD_PLAN = REPO / "compat" / "xxmi" / "build" / "payload-build-plan.json"
SOURCE_PINS = REPO / "compat" / "xxmi" / "source-pins.json"
PATCH_DIR = REPO / "compat" / "xxmi" / "patches"
FOLD_PATCH = PATCH_DIR / "0011-srmi-conditional-fold-fail-closed.patch"
REBUILD_SCRIPT = REPO / "scripts" / "xxmi-rebuild-payload.py"
BANNER_LINES = 6


def load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


REBUILD = load_module("xxmi_rebuild_payload_fold", REBUILD_SCRIPT)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def verify_fixture(root: Path, plan: dict[str, Any]) -> dict[str, Any]:
    """Authenticate the excerpts and their source-pin metadata."""

    source_pin = plan["sourcePin"]
    pins = load_json(SOURCE_PINS)["sourcePins"]["xxmiLibsPackage"]
    metadata = load_json(root / "PROVENANCE.json")
    if metadata.get("schemaVersion") != 1:
        raise AssertionError("fixture PROVENANCE schemaVersion must be 1")
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
        if metadata["source"].get(key) != value:
            raise AssertionError(
                f"fixture source metadata {key} mismatch: "
                f"got {metadata['source'].get(key)!r}, expected {value!r}"
            )
    for excerpt in metadata["excerpts"]:
        text = (root / excerpt["path"]).read_text(encoding="utf-8")
        lines = text.splitlines(keepends=True)
        if len(lines) != excerpt["fixtureLineCount"]:
            raise AssertionError(f"fixture line count mismatch for {excerpt['path']}")
        if sha256_text(text) != excerpt["fixtureSHA256"]:
            raise AssertionError(f"fixture SHA-256 mismatch for {excerpt['path']}")
        banner = "".join(lines[: excerpt["bannerLineCount"]])
        for required in ("SPDX-License-Identifier: GPL-3.0-only", source_pin["commit"]):
            if required not in banner:
                raise AssertionError(f"fixture banner for {excerpt['path']} lacks {required!r}")
        index = excerpt["bannerLineCount"]
        separator = excerpt["segmentSeparator"]
        for position, segment in enumerate(excerpt["segments"]):
            if segment["sourceEnd"] - segment["sourceStart"] + 1 != segment["lineCount"]:
                raise AssertionError("fixture source line range is inconsistent")
            chunk = "".join(lines[index : index + segment["lineCount"]])
            if sha256_text(chunk) != segment["sha256"]:
                raise AssertionError(
                    f"source excerpt SHA-256 mismatch for {excerpt['path']} "
                    f"lines {segment['sourceStart']}-{segment['sourceEnd']}"
                )
            index += segment["lineCount"]
            if position + 1 < len(excerpt["segments"]):
                if lines[index] != separator:
                    raise AssertionError(f"fixture separator mismatch in {excerpt['path']}")
                index += 1
        if index != len(lines):
            raise AssertionError(f"fixture {excerpt['path']} has unauthenticated trailing lines")
    return metadata


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
    if sorted(tree.rglob("*.rej")):
        raise AssertionError(f"{patch.name} left rejects")
    return output


def segments(path: Path) -> list[str]:
    body = "".join(path.read_text(encoding="utf-8").splitlines(keepends=True)[BANNER_LINES:])
    return body.split("// --- verbatim source excerpt gap ---\n")


PRE_HEADER = r"""
#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

using namespace std;

typedef unsigned int UINT;
typedef unsigned long DWORD;
struct ID3D11Resource {};
struct ID3D11View {};
struct HackerDevice {};

static void LogInfo(const char *, ...) {}
#define COMMAND_LIST_LOG(state, ...) do { (void)(state); } while (0)
static DWORD GetTickCount() { return 0; }

struct CommandListState {};

static int g_expression_evaluations = 0;
static int g_invalid_expression_evaluations = 0;
static vector<string> g_ran;

enum class ParamOverrideType { INVALID, VALUE, TEXTURE };

class CommandListEvaluatable {
public:
    virtual ~CommandListEvaluatable() {}
};

class CommandListOperand : public CommandListEvaluatable {
public:
    ParamOverrideType type = ParamOverrideType::VALUE;
};

class CommandListOperator : public CommandListEvaluatable {
public:
    shared_ptr<CommandListEvaluatable> lhs, rhs;
};

// Boundary stub: a partially parsed expression is modelled by
// parsed == false. Its value is what a half-built evaluatable would yield.
class CommandListExpression {
public:
    shared_ptr<CommandListEvaluatable> evaluatable;
    bool parsed = true;
    float value = 0;
    float evaluate(CommandListState *) {
        g_expression_evaluations++;
        if (!parsed)
            g_invalid_expression_evaluations++;
        return value;
    }
};

class CommandListCommand {
public:
    wstring ini_line;
    virtual ~CommandListCommand() {}
    virtual void run(CommandListState *) = 0;
    virtual bool optimise(HackerDevice *) { return false; }
    virtual bool noop(bool, bool, bool) { return false; }
};

class CommandList {
public:
    typedef std::vector<std::shared_ptr<CommandListCommand>> Commands;
    Commands commands;
    wstring ini_section;
    bool post = false;
    bool noop() { return commands.empty(); }
};

std::vector<CommandList*> registered_command_lists;
std::vector<std::shared_ptr<CommandList>> dynamically_allocated_command_lists;

enum class ResourceCopyTargetType { INVALID, EMPTY, SHADER_RESOURCE, CUSTOM_RESOURCE };
enum class ResourceCopyTargetEvaluationMode { RESOURCE, RESOURCE_REGION };
enum class ResourceCopyOptions { INVALID = 0, REFERENCE = 1, UNLESS_NULL = 2 };
inline int operator & (ResourceCopyOptions a, ResourceCopyOptions b) { return ((int)a) & ((int)b); }
inline ResourceCopyOptions &operator |= (ResourceCopyOptions &a, ResourceCopyOptions b) {
    return (ResourceCopyOptions &)(((int &)a) |= ((int)b));
}

class ResourceCopyTarget {
public:
    ResourceCopyTargetType type = ResourceCopyTargetType::INVALID;
    ResourceCopyTargetEvaluationMode evaluation_mode = ResourceCopyTargetEvaluationMode::RESOURCE;
    void *slot_expression = nullptr;
    wchar_t shader_type = L'p';
    unsigned slot = 0;
};

struct DeferredBinding {};

struct TextureOverride { CommandList command_list, post_command_list; };
struct FuzzyTextureOverride { TextureOverride *texture_override; };
struct Globals {
    map<uint32_t, vector<TextureOverride>> mTextureOverrideMap;
    vector<shared_ptr<FuzzyTextureOverride>> mFuzzyTextureOverrides;
};
static Globals g_globals;
static Globals *G = &g_globals;
namespace Profiling { static void update_cto_warning(bool) {} }
"""

MID_HEADER = r"""
class ResourceCopyOperation : public CommandListCommand {
public:
    ResourceCopyTarget src;
    ResourceCopyTarget dst;
    ResourceCopyOptions options = ResourceCopyOptions::INVALID;
    DeferredBinding *deferred = nullptr;
    string label;

    void run(CommandListState *) override { g_ran.push_back(label); }
    virtual void RunWithSource(CommandListState *, ID3D11Resource *, ID3D11View *) { g_ran.push_back(label); }
    virtual const ResourceCopyTarget& BatchTarget(BatchDirection direction) const;
};

class ShaderResourceBatch : public CommandListCommand {
public:
    wchar_t shader_type = L'\0';
    unsigned first_slot = 0;
    unsigned count = 0;
    bool prefetch_current_bindings = false;
    std::vector<std::shared_ptr<ResourceCopyOperation>> operations;
};

class ShaderResourceBindBatch : public ShaderResourceBatch {
public:
    void run(CommandListState *state) override {
        for (auto &op : operations)
            op->run(state);
    }
};

class ShaderResourceFetchBatch : public ShaderResourceBatch {
public:
    void run(CommandListState *state) override {
        for (auto &op : operations)
            op->RunWithSource(state, nullptr, nullptr);
    }
};

// Boundary stub mirroring patch 0010's IfCommand contract.
class IfCommand : public CommandListCommand {
public:
    CommandListExpression expression;
    bool expression_valid = true;
    bool has_nested_else_if = false;
    std::shared_ptr<CommandList> true_commands_pre = std::make_shared<CommandList>();
    std::shared_ptr<CommandList> true_commands_post = std::make_shared<CommandList>();
    std::shared_ptr<CommandList> false_commands_pre = std::make_shared<CommandList>();
    std::shared_ptr<CommandList> false_commands_post = std::make_shared<CommandList>();

    void clear_branches() {
        true_commands_pre->commands.clear();
        true_commands_post->commands.clear();
        false_commands_pre->commands.clear();
        false_commands_post->commands.clear();
    }
    void run(CommandListState *state) override {
        if (!expression_valid) {
            g_ran.push_back("disabled");
            return;
        }
        auto &list = expression.evaluate(state) ? true_commands_pre : false_commands_pre;
        for (auto &command : list->commands)
            command->run(state);
    }
    bool optimise(HackerDevice *) override {
        if (!expression_valid)
            clear_branches();
        return false;
    }
    bool noop(bool post, bool, bool) override {
        if (!expression_valid) {
            clear_branches();
            return true;
        }
        if (post)
            return true_commands_post->noop() && false_commands_post->noop();
        return true_commands_pre->noop() && false_commands_pre->noop();
    }
};
"""

MAIN = r"""
static shared_ptr<ResourceCopyOperation> slot_bind(const char *label, unsigned slot)
{
    auto op = make_shared<ResourceCopyOperation>();
    op->label = label;
    op->dst.type = ResourceCopyTargetType::SHADER_RESOURCE;
    op->dst.slot = slot;
    op->src.type = ResourceCopyTargetType::CUSTOM_RESOURCE;
    return op;
}

static shared_ptr<IfCommand> make_if(bool valid, float value)
{
    auto cmd = make_shared<IfCommand>();
    cmd->expression_valid = valid;
    cmd->expression.parsed = valid;
    cmd->expression.value = value;
    return cmd;
}

static void register_if(const shared_ptr<IfCommand> &cmd)
{
    registered_command_lists.push_back(cmd->true_commands_pre.get());
    registered_command_lists.push_back(cmd->false_commands_pre.get());
}

static bool contains(const CommandList::Commands &list, const CommandListCommand *wanted)
{
    for (auto &command : list)
        if (command.get() == wanted)
            return true;
    return false;
}

static int folded_operations(const CommandList::Commands &list)
{
    int count = 0;
    for (auto &command : list) {
        if (dynamic_pointer_cast<ConditionalSlotCopyOperation>(command))
            count++;
        if (auto batch = dynamic_pointer_cast<ShaderResourceBatch>(command))
            for (auto &op : batch->operations)
                if (dynamic_pointer_cast<ConditionalSlotCopyOperation>(op))
                    count++;
    }
    return count;
}

static int ran(const char *label)
{
    int count = 0;
    for (auto &entry : g_ran)
        if (entry == label)
            count++;
    return count;
}

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    string scenario = argv[1];
    CommandList list;
    list.ini_section = L"[TextureOverrideTest]";
    shared_ptr<IfCommand> head;

    if (scenario == "invalid-if" || scenario == "optimiser-order") {
        // A guarded assignment whose condition did not parse, between two
        // batchable binds: [t0 bind] [if <invalid> t1 bind endif] [t2 bind]
        head = make_if(false, 1);
        head->true_commands_pre->commands.push_back(slot_bind("B", 1));
        list.commands = { slot_bind("A", 0), head, slot_bind("C", 2) };
    } else if (scenario == "invalid-elif") {
        // if <valid, false> t1 = A2 / elif <invalid> t1 = B / endif
        head = make_if(true, 0);
        head->has_nested_else_if = true;
        head->true_commands_pre->commands.push_back(slot_bind("A2", 1));
        auto nested = make_if(false, 1);
        nested->true_commands_pre->commands.push_back(slot_bind("B", 1));
        head->false_commands_pre->commands.push_back(nested);
        list.commands = { slot_bind("A", 0), head, slot_bind("C", 2) };
    } else if (scenario == "valid-chain") {
        // if <valid, true> t1 = B / else t1 = D / endif
        head = make_if(true, 1);
        head->true_commands_pre->commands.push_back(slot_bind("B", 1));
        head->false_commands_pre->commands.push_back(slot_bind("D", 1));
        list.commands = { slot_bind("A", 0), head, slot_bind("C", 2) };
    } else {
        return 2;
    }

    size_t before = list.commands.size();
    if (scenario == "optimiser-order") {
        registered_command_lists.push_back(&list);
        register_if(head);
        optimise_command_lists(nullptr);
    } else {
        merge_shader_resource_batches(&list);
    }
    int evaluations_during_merge = g_expression_evaluations;

    CommandListState state;
    for (auto &command : list.commands)
        command->run(&state);

    printf("BEFORE=%zu\n", before);
    printf("AFTER=%zu\n", list.commands.size());
    printf("IF_STANDALONE=%d\n", contains(list.commands, head.get()) ? 1 : 0);
    printf("FOLDED=%d\n", folded_operations(list.commands));
    printf("MERGE_EVALUATIONS=%d\n", evaluations_during_merge);
    printf("INVALID_EVALUATIONS=%d\n", g_invalid_expression_evaluations);
    printf("RAN_A=%d\n", ran("A"));
    printf("RAN_A2=%d\n", ran("A2"));
    printf("RAN_B=%d\n", ran("B"));
    printf("RAN_C=%d\n", ran("C"));
    printf("RAN_D=%d\n", ran("D"));
    printf("RAN_DISABLED=%d\n", ran("disabled"));
    return 0;
}
"""


def build_harness(root: Path) -> str:
    header = segments(root / "DirectX11" / "CommandList.h")
    source = segments(root / "DirectX11" / "CommandList.cpp")
    if len(header) != 2 or len(source) != 2:
        raise AssertionError("unexpected fold fixture segment layout")
    return "\n".join(
        [PRE_HEADER, header[0], MID_HEADER, header[1], source[0], source[1], MAIN]
    )


class ConditionalFoldTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = load_json(BUILD_PLAN)
        cls.pin = cls.plan["sourcePin"]
        cls.provenance = verify_fixture(FIXTURE, cls.plan)
        cls.cxx = shutil.which("clang++") or shutil.which("c++")
        if cls.cxx is None:
            raise unittest.SkipTest("a C++ compiler is required for the fold harness")
        if shutil.which("patch") is None:
            raise unittest.SkipTest("patch(1) is required for the fold harness")
        cls._temp = tempfile.TemporaryDirectory(prefix="macgacha-conditional-fold-")
        cls.temp = Path(cls._temp.name)
        cls.old_tree = cls.temp / "fixture-old"
        cls.new_tree = cls.temp / "fixture-new"
        shutil.copytree(FIXTURE, cls.old_tree)
        shutil.copytree(FIXTURE, cls.new_tree)
        apply_fixture_patch(cls.new_tree, FOLD_PATCH)
        cls.old_harness = cls._compile("old", cls.old_tree)
        cls.new_harness = cls._compile("new", cls.new_tree)

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "_temp"):
            cls._temp.cleanup()

    @classmethod
    def _compile(cls, name: str, root: Path) -> Path:
        cpp = cls.temp / f"fold_harness_{name}.cpp"
        exe = cls.temp / f"fold_harness_{name}"
        cpp.write_text(build_harness(root), encoding="utf-8")
        command = [
            cls.cxx, "-std=c++17", "-O0", "-Wall", "-Wextra", "-Werror",
            "-Wno-unused-parameter", "-Wno-unused-function", "-Wno-unused-variable",
            "-Wno-unused-private-field", "-Wno-unused-but-set-variable",
            "-o", str(exe), str(cpp),
        ]
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode != 0:
            raise AssertionError(
                f"fold harness compilation failed for {name}:\n{result.stdout}{result.stderr}"
            )
        return exe

    @staticmethod
    def _run(harness: Path, scenario: str) -> dict[str, int]:
        result = subprocess.run(
            [str(harness), scenario], text=True, capture_output=True, check=True
        )
        values: dict[str, int] = {}
        for line in result.stdout.splitlines():
            key, raw = line.split("=", 1)
            values[key] = int(raw)
        return values

    def test_fixture_metadata_is_authenticated(self) -> None:
        self.assertEqual(self.provenance["source"]["commit"], self.pin["commit"])

    def test_tampered_fixture_is_rejected(self) -> None:
        tampered = self.temp / "tampered"
        shutil.copytree(FIXTURE, tampered)
        path = tampered / "DirectX11" / "CommandList.cpp"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "if (expression_reads_pipeline(", "if (!expression_reads_pipeline(", 1
            ),
            encoding="utf-8",
        )
        with self.assertRaises(AssertionError):
            verify_fixture(tampered, self.plan)

    def test_patch_is_pinned_in_plan_and_source_pins(self) -> None:
        digest = REBUILD.sha256_file(FOLD_PATCH)
        stage3 = {entry["path"]: entry["sha256"] for entry in self.plan["stage3"]["patches"]}
        self.assertEqual(
            stage3.get("compat/xxmi/patches/0011-srmi-conditional-fold-fail-closed.patch"), digest
        )
        pins = load_json(SOURCE_PINS)["sources"]["patches"]
        self.assertEqual(pins["order"][-1], FOLD_PATCH.name)
        self.assertEqual(pins["sha256"][FOLD_PATCH.name], digest)

    def test_patch_adds_only_the_guard(self) -> None:
        old = (self.old_tree / "DirectX11" / "CommandList.cpp").read_text(encoding="utf-8")
        new = (self.new_tree / "DirectX11" / "CommandList.cpp").read_text(encoding="utf-8")
        old_lines, new_lines = old.splitlines(), new.splitlines()
        added = [line for line in new_lines if line not in old_lines]
        self.assertEqual(len(new_lines) - len(old_lines), 10)
        self.assertIn("\tif (!if_cmd->expression_valid)", added)
        self.assertTrue(all(line.startswith("\t//") or line.strip() in ("", "return false;")
                            or "expression_valid" in line for line in added))
        guard = new.index("if (!if_cmd->expression_valid)")
        self.assertLess(guard, new.index("if (expression_reads_pipeline(if_cmd->expression"))
        self.assertGreater(guard, new.index("static bool collect_conditional_chain("))

    def test_optimiser_removes_invalid_node_before_batching(self) -> None:
        # The real optimise_command_lists order: optimise, noop removal, then
        # merge. Even upstream batching never sees the invalid node.
        for harness in (self.old_harness, self.new_harness):
            values = self._run(harness, "optimiser-order")
            self.assertEqual(values["IF_STANDALONE"], 0)
            self.assertEqual(values["FOLDED"], 0)
            self.assertEqual(values["INVALID_EVALUATIONS"], 0)
            self.assertEqual(values["RAN_B"], 0)
            self.assertEqual(values["RAN_A"], 1)
            self.assertEqual(values["RAN_C"], 1)

    def test_upstream_batching_folds_an_invalid_if(self) -> None:
        values = self._run(self.old_harness, "invalid-if")
        self.assertEqual(values["FOLDED"], 1)
        self.assertEqual(values["IF_STANDALONE"], 0)
        self.assertEqual(values["INVALID_EVALUATIONS"], 1)
        self.assertEqual(values["RAN_B"], 1)
        self.assertEqual(values["RAN_DISABLED"], 0)

    def test_guarded_batching_keeps_invalid_if_closed(self) -> None:
        values = self._run(self.new_harness, "invalid-if")
        self.assertEqual(values["FOLDED"], 0)
        self.assertEqual(values["IF_STANDALONE"], 1)
        self.assertEqual(values["MERGE_EVALUATIONS"], 0)
        self.assertEqual(values["INVALID_EVALUATIONS"], 0)
        self.assertEqual(values["RAN_B"], 0)
        self.assertEqual(values["RAN_DISABLED"], 1)
        self.assertEqual(values["RAN_A"], 1)
        self.assertEqual(values["RAN_C"], 1)

    def test_upstream_batching_folds_an_invalid_elif(self) -> None:
        values = self._run(self.old_harness, "invalid-elif")
        self.assertEqual(values["FOLDED"], 1)
        self.assertEqual(values["INVALID_EVALUATIONS"], 1)
        self.assertEqual(values["RAN_B"], 1)

    def test_guarded_batching_keeps_invalid_elif_closed(self) -> None:
        values = self._run(self.new_harness, "invalid-elif")
        self.assertEqual(values["FOLDED"], 0)
        self.assertEqual(values["IF_STANDALONE"], 1)
        self.assertEqual(values["INVALID_EVALUATIONS"], 0)
        self.assertEqual(values["RAN_A2"], 0)
        self.assertEqual(values["RAN_B"], 0)
        self.assertEqual(values["RAN_DISABLED"], 1)

    def test_valid_chain_folds_unchanged(self) -> None:
        old = self._run(self.old_harness, "valid-chain")
        new = self._run(self.new_harness, "valid-chain")
        self.assertEqual(old, new)
        self.assertEqual(new["FOLDED"], 1)
        self.assertEqual(new["AFTER"], 1)
        self.assertEqual(new["RAN_B"], 1)
        self.assertEqual(new["RAN_D"], 0)
        self.assertEqual(new["INVALID_EVALUATIONS"], 0)

    def test_full_stage3_chain_matches_plan(self) -> None:
        override = os.environ.get("XXMI_LIBS_SOURCE")
        if not override:
            self.skipTest("XXMI_LIBS_SOURCE is not set; full-tree parity is optional")
        source = Path(override)
        manifest = REBUILD.tree_manifest(source)
        self.assertEqual(manifest["sha256"], self.pin["cleanTreeSHA256"])
        self.assertEqual(manifest["fileCount"], self.pin["cleanFileCount"])
        tree = self.temp / "full"
        logs = self.temp / "full-logs"
        shutil.copytree(source, tree)
        logs.mkdir()
        for entry in self.plan["basePatches"]:
            REBUILD.apply_patch(tree, REBUILD.resolve_plan_path(entry["path"]), logs)
        REBUILD.apply_compatibility_edits(tree, self.plan["stage1"]["compatibilityEdits"])
        REBUILD.apply_patch(tree, REBUILD.resolve_plan_path(self.plan["stage2"]["patch"]["path"]), logs)
        for entry in self.plan["stage3"]["patches"]:
            REBUILD.apply_patch(tree, REBUILD.resolve_plan_path(entry["path"]), logs)
        patched = (tree / "DirectX11" / "CommandList.cpp").read_text(encoding="utf-8")
        fixture = segments(self.new_tree / "DirectX11" / "CommandList.cpp")
        for segment in fixture:
            self.assertIn(segment, patched)


if __name__ == "__main__":
    unittest.main()
