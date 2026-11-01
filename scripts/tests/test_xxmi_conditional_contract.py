#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline regression tests for SRMI invalid conditional-flow handling.

The core tests are self-contained: they authenticate the checked-in minimal
source excerpts under ``fixtures/xxmi-conditional`` against fixed SHA-256
metadata, apply ``0010-srmi-invalid-conditional-fail-closed.patch`` to those
excerpts, and compile the real production flow-control functions and
``IfCommand`` methods against small boundary stubs.

The excerpts contain the verbatim ``ParseFlowControl`` region,
``AddCommandToList``, the local/global variable lookup helpers, the variable
token scanner, ``CommandList::clear``/``ResolveCommandList``/``noop``,
``_RunCommandList``, and IniHandler's ``ParseCommandListLine`` and
``ParseCommandList`` loop, plus the class declarations they need.

Boundary stubs (documented in the harness): Win32/global/rendering state, log
sinks, profiling, the four non-flow command parsers, and the expression
tokeniser itself. The conditional expression stub uses the real
``FindVariableTokenEnd`` and the real namespace-aware
``find_local_variable``/``parse_command_list_var_name`` lookup, so an
unresolvable ``$variable`` fails exactly as ``CommandListExpression::parse``
does in production. The tested algorithm is the real production control flow,
not a transcription.

``XXMI_LIBS_SOURCE`` may point at the full pinned clean tree. When set, the
tree is authenticated against the build plan's clean-tree digest before use and
a wrong override fails closed. The full tree is optional and only enables an
extra parity test: patches 0001-0007 (and, in a separate copy, 0009) plus 0010
must apply with ``--fuzz=0`` and the resulting relevant regions must match the
minimal fixture. Without an override, the recorded build-machine path is used
only if it is present and authentic; otherwise that optional parity test is
skipped. A full Windows/SDK translation-unit compile is not attempted: the
harness does not require MSVC/DirectX11 headers. The changed functions themselves are
compiled from the authenticated excerpts.

This proves malformed-config behaviour, not a live visual repair. A mod that
references another manager's generated variables still needs those
definitions; it now fails closed and is diagnosed instead of running its body
unconditionally.
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
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "xxmi-conditional"
BUILD_PLAN = REPO / "compat" / "xxmi" / "build" / "payload-build-plan.json"
SOURCE_PINS = REPO / "compat" / "xxmi" / "source-pins.json"
PATCH_DIR = REPO / "compat" / "xxmi" / "patches"
CONDITIONAL_PATCH = PATCH_DIR / "0010-srmi-invalid-conditional-fail-closed.patch"
CURSOR_PATCH = PATCH_DIR / "0009-srmi-cursor-coordinate-contract.patch"
REBUILD_SCRIPT = REPO / "scripts" / "xxmi-rebuild-payload.py"

DEFAULT_SOURCE = Path(
    "/private/tmp/xxmi-libs-v1.2.2-source/"
    "XXMI-Libs-Package-a7847eae82aaac32175c9a7d199673d5c9323bcd"
)

NEW_ONLY_KEYS = frozenset(
    {"IF_VALID", "BRANCH_true_pre", "BRANCH_true_post",
     "BRANCH_false_pre", "BRANCH_false_post"}
)

PREAMBLE = r"""
#include <algorithm>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <exception>
#include <forward_list>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

using namespace std;

struct LARGE_INTEGER { long long QuadPart; };
#define SENSIBLE_ENUM(ENUMTYPE) \
inline int operator | (ENUMTYPE a, ENUMTYPE b) { return (((int)a) | ((int)b)); } \
inline int operator & (ENUMTYPE a, ENUMTYPE b) { return (((int)a) & ((int)b)); } \
inline int operator ^ (ENUMTYPE a, ENUMTYPE b) { return (((int)a) ^ ((int)b)); } \
inline int operator ~ (ENUMTYPE a) { return (~((int)a)); } \
inline ENUMTYPE &operator |= (ENUMTYPE &a, ENUMTYPE b) { return (ENUMTYPE &)(((int &)a) |= ((int)b)); } \
inline ENUMTYPE &operator &= (ENUMTYPE &a, ENUMTYPE b) { return (ENUMTYPE &)(((int &)a) &= ((int)b)); } \
inline ENUMTYPE &operator ^= (ENUMTYPE &a, ENUMTYPE b) { return (ENUMTYPE &)(((int &)a) ^= ((int)b)); } \
inline bool operator || (ENUMTYPE a,  ENUMTYPE b) { return (((int)a) || ((int)b)); } \
inline bool operator || (    bool a,  ENUMTYPE b) { return (((int)a) || ((int)b)); } \
inline bool operator || (ENUMTYPE a,      bool b) { return (((int)a) || ((int)b)); } \
inline bool operator && (ENUMTYPE a,  ENUMTYPE b) { return (((int)a) && ((int)b)); } \
inline bool operator && (    bool a,  ENUMTYPE b) { return (((int)a) && ((int)b)); } \
inline bool operator && (ENUMTYPE a,      bool b) { return (((int)a) && ((int)b)); } \
inline bool operator ! (ENUMTYPE a) { return (!((int)a)); }
template <typename T1, typename T2>
struct EnumName_t { T1 name; T2 val; };
static void DoubleBeepExit() {}

enum { LOG_DIRE = 0, LOG_WARNING = 1, LOG_NOTICE = 2 };

struct HackerDevice;
struct CommandListState {
    bool post = false;
    bool aborted = false;
    int recursion = 0;
    int extra_indent = 0;
};

static vector<wstring> g_messages;
static void RecordNarrow(const char *fmt)
{
    wstring out;
    for (const char *p = fmt; p && *p; ++p)
        out.push_back((wchar_t)(unsigned char)*p);
    g_messages.push_back(out);
}
static void RecordWide(const wchar_t *fmt) { g_messages.push_back(fmt ? fmt : L""); }
static void LogDebug(const char *, ...) {}
static void LogInfo(const char *fmt, ...) { RecordNarrow(fmt); }
static void LogInfoW(const wchar_t *fmt, ...) { RecordWide(fmt); }
static void LogOverlay(int, const char *fmt, ...) { RecordNarrow(fmt); }
static void LogOverlayW(int, const wchar_t *fmt, ...) { RecordWide(fmt); }
static void IniWarning(const char *fmt, ...) { RecordNarrow(fmt); }
static void IniWarningW(const wchar_t *fmt, ...) { RecordWide(fmt); }

static int g_eval_calls = 0;
static int g_static_calls = 0;
static int g_null_eval = 0;
static int g_null_static = 0;
static float g_primary_value = 0.0f;
static float g_outer_value = 0.0f;
static float g_inner_value = 0.0f;
static wstring g_parse_error;

#define MAX_COMMAND_LIST_RECURSION 256
#define COMMAND_LIST_LOG(state, ...) do { } while (0)
"""

DECLS = r"""
inline wchar_t ascii_tolower(wchar_t c);
wstring get_namespaced_var_name_lower(const wstring& low_name, const wstring* ini_namespace);

struct command_list_profiling_state {};
static void profile_command_list_start(CommandList*, CommandListState*, command_list_profiling_state*) {}
static void profile_command_list_cmd_start(CommandListCommand*, command_list_profiling_state*) {}
static void profile_command_list_cmd_end(CommandListCommand*, CommandListState*, command_list_profiling_state*) {}
static void profile_command_list_end(CommandList*, CommandListState*, command_list_profiling_state*) {}

CommandListVariables command_list_globals;
vector<CommandListVariable*> persistent_variables;
map<wstring, float> unknown_variables;
vector<CommandList*> registered_command_lists;
vector<shared_ptr<CommandList>> dynamically_allocated_command_lists;

struct FakeGlobals { wstring user_config; };
static FakeGlobals fake_globals;
static FakeGlobals *G = &fake_globals;

typedef set<wstring> IniSectionSet;
static IniSectionVector g_section;
static bool IsCommandListSection(const wchar_t *) { return true; }
static void GetIniSection(IniSectionVector **out, const wchar_t *) { *out = &g_section; }

bool ParseCommandListVariableAssignment(const wchar_t *, const wchar_t *,
        wstring *, const wstring *, CommandList *, CommandList *,
        CommandList *, const wstring *);
bool ParseCommandListGeneralCommands(const wchar_t *, const wchar_t *,
        wstring *, CommandList *, CommandList *, CommandList *,
        const wstring *);
bool ParseCommandListIniParamOverride(const wchar_t *, const wchar_t *,
        wstring *, CommandList *, const wstring *);
bool ParseCommandListResourceCopyTargetDirective(const wchar_t *,
        const wchar_t *, wstring *, CommandList *, const wstring *);
"""

EXPRESSION_STUB = r"""
static float OperandFor(const wstring& expression)
{
    if (expression.find(L"$outer") != wstring::npos)
        return g_outer_value;
    if (expression.find(L"$inner") != wstring::npos)
        return g_inner_value;
    return g_primary_value;
}

class TestOperand : public CommandListEvaluatable {
public:
    explicit TestOperand(float value) : value(value) {}
    float evaluate(CommandListState *, HackerDevice *) override { return value; }
    bool static_evaluate(float *ret, HackerDevice *, bool) override
    {
        if (ret)
            *ret = value;
        return true;
    }
    bool optimise(HackerDevice *, shared_ptr<CommandListEvaluatable> *) override
    {
        return false;
    }
private:
    float value;
};

// Boundary stub: the full SRMI expression tokeniser is out of scope here.
// Variable token boundaries and namespace-aware lookup are the real production
// helpers, so an unresolvable $variable fails exactly like
// CommandListExpression::parse does in production.
bool CommandListExpression::parse(const wstring *expression,
        const wstring *ini_namespace, CommandListScope *scope)
{
    size_t pos = 0;
    while (true) {
        pos = expression->find_first_not_of(L" \t", pos);
        if (pos == wstring::npos)
            break;
        if ((*expression)[pos] != L'$') {
            ++pos;
            continue;
        }
        size_t end = FindVariableTokenEnd(*expression, pos + 1);
        wstring token = expression->substr(pos, end - pos);
        CommandListVariable *var = nullptr;
        if (!(find_local_variable(token, scope, &var) ||
              parse_command_list_var_name(token, ini_namespace, &var))) {
            g_parse_error = wstring(L"Variable not recognized: ") +
                    expression->substr(pos);
            return false;
        }
        pos = end;
    }
    evaluatable = make_shared<TestOperand>(OperandFor(*expression));
    return true;
}

float CommandListExpression::evaluate(CommandListState *state, HackerDevice *device)
{
    ++g_eval_calls;
    if (!evaluatable) {
        g_null_eval = 1;
        return 0.0f;
    }
    return evaluatable->evaluate(state, device);
}

bool CommandListExpression::static_evaluate(float *ret, HackerDevice *device,
        bool evaluate_variables)
{
    ++g_static_calls;
    if (!evaluatable) {
        g_null_static = 1;
        return false;
    }
    return evaluatable->static_evaluate(ret, device, evaluate_variables);
}

bool CommandListExpression::optimise(HackerDevice *device)
{
    if (!evaluatable)
        return false;
    return evaluatable->optimise(device, nullptr);
}
"""

PARSER_STUBS = r"""
static vector<wstring> g_ran;

struct TestBodyCommand : CommandListCommand {
    explicit TestBodyCommand(const wstring& tag) : tag(tag) {}
    void run(CommandListState *state) override
    {
        g_ran.push_back(state->post ? (wstring(L"post:") + tag) : tag);
    }
    wstring tag;
};

bool ParseCommandListVariableAssignment(const wchar_t *, const wchar_t *,
        wstring *, const wstring *, CommandList *, CommandList *,
        CommandList *, const wstring *)
{
    return false;
}

bool ParseCommandListIniParamOverride(const wchar_t *, const wchar_t *,
        wstring *, CommandList *, const wstring *)
{
    return false;
}

bool ParseCommandListResourceCopyTargetDirective(const wchar_t *,
        const wchar_t *, wstring *, CommandList *, const wstring *)
{
    return false;
}

bool ParseCommandListGeneralCommands(const wchar_t *section,
        const wchar_t *key, wstring *val, CommandList *explicit_list,
        CommandList *pre, CommandList *post, const wstring *)
{
    if (wcsncmp(key, L"body", 4) != 0)
        return false;
    TestBodyCommand *command = new TestBodyCommand(wstring(key));
    AddCommandToList(command, explicit_list, nullptr, pre, post, section,
            key, val);
    return true;
}
"""

MAIN = r"""
static void AddLine(const wstring& key, const wstring& value,
        const wstring& raw, const wstring& ns = wstring())
{
    wstring k = key, v = value, r = raw, n = ns;
    g_section.emplace_back(k, v, r, n);
}

static int CountMessages(const wchar_t *needle)
{
    int count = 0;
    for (const wstring& message : g_messages)
        if (message.find(needle) != wstring::npos)
            ++count;
    return count;
}

static bool Ran(const wchar_t *tag)
{
    for (const wstring& ran : g_ran)
        if (ran == tag)
            return true;
    return false;
}

static bool RanPost(const wchar_t *tag)
{
    wstring wanted = wstring(L"post:") + tag;
    for (const wstring& ran : g_ran)
        if (ran == wanted)
            return true;
    return false;
}

static int TopIfIndex(CommandList *list)
{
    for (size_t i = 0; i < list->commands.size(); ++i)
        if (dynamic_cast<IfCommand *>(list->commands[i].get()))
            return (int)i;
    return -1;
}

static void PrintBranchSizes(IfCommand *command)
{
    printf("BRANCH_true_pre=%zu\n", command->true_commands_pre->commands.size());
    printf("BRANCH_true_post=%zu\n", command->true_commands_post->commands.size());
    printf("BRANCH_false_pre=%zu\n", command->false_commands_pre->commands.size());
    printf("BRANCH_false_post=%zu\n", command->false_commands_post->commands.size());
}

static int g_invalid_nodes = 0;
static int g_invalid_branch_total = 0;

static void OptimiseTree(CommandList *list)
{
    for (size_t i = 0; i < list->commands.size();) {
        IfCommand *command = dynamic_cast<IfCommand *>(list->commands[i].get());
        if (!command) {
            ++i;
            continue;
        }
        command->optimise(nullptr);
        bool removed = command->noop(false, true, false);
#ifdef NEW_CONTRACT
        if (!command->expression_valid) {
            ++g_invalid_nodes;
            g_invalid_branch_total += (int)(command->true_commands_pre->commands.size()
                    + command->true_commands_post->commands.size()
                    + command->false_commands_pre->commands.size()
                    + command->false_commands_post->commands.size());
        }
#endif
        OptimiseTree(command->true_commands_pre.get());
        OptimiseTree(command->false_commands_pre.get());
        if (removed) {
            list->commands.erase(list->commands.begin() + i);
            continue;
        }
        ++i;
    }
}

static void RegisterVariable(const wstring& name)
{
    command_list_globals.emplace(name, CommandListVariable(name, 1.0f, VariableFlags::NONE));
}

static void SectionInvalidIfWithElse(const wstring& ns)
{
    AddLine(L"if $missing", L"", L"if $missing", ns);
    AddLine(L"body1", L"1", L"body1 = 1", ns);
    AddLine(L"else", L"", L"else", ns);
    AddLine(L"body2", L"1", L"body2 = 1", ns);
    AddLine(L"endif", L"", L"endif", ns);
    AddLine(L"body3", L"1", L"body3 = 1", ns);
}

int main(int argc, char **argv)
{
    if (argc < 6)
        return 2;
    const string scenario = argv[1];
    g_primary_value = (float)atoi(argv[2]);
    g_outer_value = (float)atoi(argv[3]);
    g_inner_value = (float)atoi(argv[4]);
    wstring ns;
    for (const char *p = argv[5]; p && *p; ++p)
        ns.push_back((wchar_t)(unsigned char)*p);
    const bool optimise_path = argc > 6 && string(argv[6]) == "opt";

    RegisterVariable(L"$cond");
    RegisterVariable(L"$outer");
    RegisterVariable(L"$inner");
    RegisterVariable(L"$managed_slot_id");
    wstring modns = L"modns";
    RegisterVariable(get_namespaced_var_name_lower(L"$nsvar", &modns));

    if (scenario == "blank_if" || scenario == "direct_blank_if") {
        wstring line = scenario == "blank_if" ? NormalizeIniLine(L" \tif \t ") : L"if \t";
        AddLine(line, L"", line, ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
    } else if (scenario == "blank_elif" || scenario == "blank_else_if" || scenario == "direct_blank_elif") {
        AddLine(L"if $outer", L"", L"if $outer", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        wstring line = scenario == "blank_else_if" ? NormalizeIniLine(L" else if \t ")
            : scenario == "blank_elif" ? NormalizeIniLine(L" \telif \t ") : L"elif \t";
        AddLine(line, L"", line, ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body4", L"1", L"body4 = 1", ns);
    } else if (scenario == "if_else_missing" || scenario == "second_section"
            || scenario == "post_invalid") {
        SectionInvalidIfWithElse(ns);
    } else if (scenario == "if_else" || scenario == "post_valid") {
        AddLine(L"if $cond", L"", L"if $cond", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
    } else if (scenario == "namespace") {
        AddLine(L"if $nsvar", L"", L"if $nsvar", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
    } else if (scenario == "manager_var" || scenario == "manager_var_defined") {
        if (scenario == "manager_var_defined") {
            wstring managerns = L"modmanageragl\\group_1";
            RegisterVariable(get_namespaced_var_name_lower(L"$active_slot", &managerns));
        }
        AddLine(L"if $managed_slot_id == $\\modmanageragl\\group_1\\active_slot",
                L"", L"if $managed_slot_id == $\\modmanageragl\\group_1\\active_slot", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
    } else if (scenario == "elif_missing") {
        AddLine(L"if $outer", L"", L"if $outer", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"elif $missing", L"", L"elif $missing", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body4", L"1", L"body4 = 1", ns);
    } else if (scenario == "elseif_missing") {
        AddLine(L"if $outer", L"", L"if $outer", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"else if $missing", L"", L"else if $missing", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body4", L"1", L"body4 = 1", ns);
    } else if (scenario == "elif_valid") {
        AddLine(L"if $outer", L"", L"if $outer", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"elif $inner", L"", L"elif $inner", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body4", L"1", L"body4 = 1", ns);
    } else if (scenario == "if_missing_elif_valid") {
        AddLine(L"if $missing", L"", L"if $missing", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"elif $inner", L"", L"elif $inner", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body4", L"1", L"body4 = 1", ns);
    } else if (scenario == "chain") {
        AddLine(L"if $outer", L"", L"if $outer", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"elif $inner", L"", L"elif $inner", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"elif $missing", L"", L"elif $missing", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
        AddLine(L"elif $inner", L"", L"elif $inner", ns);
        AddLine(L"body4", L"1", L"body4 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body5", L"1", L"body5 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body6", L"1", L"body6 = 1", ns);
    } else if (scenario == "nested") {
        AddLine(L"if $outer", L"", L"if $outer", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"if $missing", L"", L"if $missing", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body3", L"1", L"body3 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body4", L"1", L"body4 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body5", L"1", L"body5 = 1", ns);
    } else if (scenario == "missing_endif") {
        AddLine(L"if $missing", L"", L"if $missing", ns);
        AddLine(L"body1", L"1", L"body1 = 1", ns);
        AddLine(L"body2", L"1", L"body2 = 1", ns);
    } else {
        return 3;
    }

    const bool post_mode = scenario == "post_valid" || scenario == "post_invalid";
    CommandList pre;
    CommandList post;
    ParseCommandList(L"TestSection", &pre, post_mode ? &post : nullptr, nullptr);

    CommandList second;
    if (scenario == "second_section") {
        g_section.clear();
        AddLine(L"if $cond", L"", L"if $cond", ns);
        AddLine(L"body4", L"1", L"body4 = 1", ns);
        AddLine(L"else", L"", L"else", ns);
        AddLine(L"body5", L"1", L"body5 = 1", ns);
        AddLine(L"endif", L"", L"endif", ns);
        AddLine(L"body6", L"1", L"body6 = 1", ns);
        ParseCommandList(L"SecondSection", &second, nullptr, nullptr);
    }

    printf("PARSE_ERROR=%d\n", g_parse_error.empty() ? 0 : 1);
    printf("WARN_UNRECOGNISED=%d\n", CountMessages(L"Unrecognised entry"));
    printf("WARN_INVALID_COND=%d\n", CountMessages(L"Invalid conditional expression"));
    printf("WARN_MISSING_IF=%d\n", CountMessages(L"Statement \"endif\" missing"));
    printf("WARN_SCOPE=%d\n", CountMessages(L"Scope unbalanced"));
    printf("WARN_PLACEHOLDER=%d\n", CountMessages(L"Placeholder command executed"));
    printf("TOP_COMMANDS=%zu\n", pre.commands.size());
    printf("POST_COMMANDS=%zu\n", post.commands.size());

    int if_index = TopIfIndex(&pre);
    printf("TOP_IFS=%d\n", if_index >= 0 ? 1 : 0);
#ifdef NEW_CONTRACT
    if (if_index >= 0) {
        IfCommand *command = dynamic_cast<IfCommand *>(pre.commands[if_index].get());
        printf("IF_VALID=%d\n", command->expression_valid ? 1 : 0);
        PrintBranchSizes(command);
    }
#endif

    if (optimise_path) {
        OptimiseTree(&pre);
        printf("OPT_INVALID_NODES=%d\n", g_invalid_nodes);
        printf("OPT_INVALID_BRANCH_TOTAL=%d\n", g_invalid_branch_total);
        printf("OPT_WARN_MISSING_ENDIF=%d\n", CountMessages(L"Statement \"if\" missing"));
        printf("OPT_EVAL=%d\n", g_eval_calls);
        printf("OPT_STATIC=%d\n", g_static_calls);
        printf("OPT_NULL_EVAL=%d\n", g_null_eval);
        printf("OPT_NULL_STATIC=%d\n", g_null_static);
    }

    CommandListState state;
    _RunCommandList(&pre, &state, false);
    if (post_mode) {
        CommandListState post_state;
        post_state.post = true;
        _RunCommandList(&post, &post_state, false);
    }
    if (scenario == "second_section") {
        CommandListState second_state;
        _RunCommandList(&second, &second_state, false);
    }

    printf("EVAL_CALLS=%d\n", g_eval_calls);
    printf("STATIC_CALLS=%d\n", g_static_calls);
    printf("NULL_EVAL=%d\n", g_null_eval);
    printf("NULL_STATIC=%d\n", g_null_static);
    for (int i = 1; i <= 6; ++i) {
        wstring tag = wstring(L"body") + (wchar_t)(L'0' + i);
        printf("RAN_%d=%d\n", i, Ran(tag.c_str()) ? 1 : 0);
        printf("RAN_POST_%d=%d\n", i, RanPost(tag.c_str()) ? 1 : 0);
    }
    return 0;
}
"""

BANNER_LINES = 6


def load_rebuild_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("xxmi_rebuild_payload", REBUILD_SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {REBUILD_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


REBUILD = load_rebuild_module()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AssertionError(f"cannot read JSON metadata {path}: {exc}") from exc


def load_build_plan() -> dict[str, Any]:
    plan = load_json(BUILD_PLAN)
    if plan.get("schemaVersion") != 1:
        raise AssertionError("payload build plan schemaVersion must be 1")
    for key in ("sourcePin", "basePatches", "stage1", "stage2"):
        if key not in plan:
            raise AssertionError(f"payload build plan is missing {key}")
    return plan


def plan_patch_paths(plan: dict[str, Any]) -> list[Path]:
    paths = [REBUILD.resolve_plan_path(entry["path"]) for entry in plan["basePatches"]]
    paths.append(REBUILD.resolve_plan_path(plan["stage2"]["patch"]["path"]))
    return paths


def verify_fixture(root: Path = FIXTURE, plan: dict[str, Any] | None = None) -> dict[str, Any]:
    """Authenticate the checked-in excerpts and their source-pin metadata."""

    plan = plan or load_build_plan()
    source_pin = plan["sourcePin"]
    pins = load_json(SOURCE_PINS)["sourcePins"]["xxmiLibsPackage"]
    metadata = load_json(root / "PROVENANCE.json")
    if metadata.get("schemaVersion") != 1:
        raise AssertionError("fixture PROVENANCE schemaVersion must be 1")

    source = metadata.get("source", {})
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
        if source.get(key) != value:
            raise AssertionError(
                f"fixture source metadata {key} mismatch: "
                f"got {source.get(key)!r}, expected {value!r}"
            )

    excerpts = metadata.get("excerpts")
    if not isinstance(excerpts, list) or not excerpts:
        raise AssertionError("fixture PROVENANCE has no excerpts")

    for excerpt in excerpts:
        path = root / excerpt["path"]
        if not path.is_file():
            raise AssertionError(f"fixture excerpt is missing: {path}")
        text = path.read_text(encoding="utf-8")
        lines = text.splitlines(keepends=True)
        if len(lines) != excerpt["fixtureLineCount"]:
            raise AssertionError(
                f"fixture line count mismatch for {excerpt['path']}: "
                f"got {len(lines)}, expected {excerpt['fixtureLineCount']}"
            )
        actual_hash = sha256_text(text)
        if actual_hash != excerpt["fixtureSHA256"]:
            raise AssertionError(
                f"fixture SHA-256 mismatch for {excerpt['path']}: "
                f"got {actual_hash}, expected {excerpt['fixtureSHA256']}"
            )

        banner_count = excerpt["bannerLineCount"]
        banner = "".join(lines[:banner_count])
        for required in (
            "SPDX-License-Identifier: GPL-3.0-only",
            "MacGacha — https://github.com/deruta74/MacGacha",
            source_pin["commit"],
            pins["license"],
            "XXMI-Libs-Package",
        ):
            if required not in banner:
                raise AssertionError(
                    f"fixture banner for {excerpt['path']} is missing {required!r}"
                )

        index = banner_count
        segments = excerpt["segments"]
        separator = excerpt["segmentSeparator"]
        separator_lines = separator.splitlines(keepends=True)
        if len(separator_lines) != excerpt["segmentSeparatorLineCount"]:
            raise AssertionError("fixture segment separator metadata is inconsistent")
        for position, segment in enumerate(segments):
            if segment["sourceEnd"] - segment["sourceStart"] + 1 != segment["lineCount"]:
                raise AssertionError("fixture source line range is inconsistent")
            chunk = "".join(lines[index : index + segment["lineCount"]])
            if sha256_text(chunk) != segment["sha256"]:
                raise AssertionError(
                    f"source excerpt SHA-256 mismatch for {excerpt['path']} "
                    f"lines {segment['sourceStart']}-{segment['sourceEnd']}"
                )
            index += segment["lineCount"]
            if position + 1 < len(segments):
                found = "".join(lines[index : index + len(separator_lines)])
                if found != separator:
                    raise AssertionError(
                        f"fixture segment separator mismatch in {excerpt['path']}"
                    )
                index += len(separator_lines)
        if index != len(lines):
            raise AssertionError(
                f"fixture {excerpt['path']} has unauthenticated trailing lines"
            )
    return metadata


def require_source_pin_match(path: Path, source_pin: dict[str, Any]) -> dict[str, Any]:
    """Authenticate a full clean tree against the build plan, without exclusions."""

    if not path.is_dir():
        raise AssertionError(f"XXMI source override is not a directory: {path}")
    manifest = REBUILD.tree_manifest(path)
    if manifest["fileCount"] != source_pin["cleanFileCount"]:
        raise AssertionError(
            "source override file count mismatch: "
            f"got {manifest['fileCount']}, expected {source_pin['cleanFileCount']}"
        )
    if manifest["sha256"] != source_pin["cleanTreeSHA256"]:
        raise AssertionError(
            "source override is not the pinned clean tree: "
            f"got {manifest['sha256']}, expected {source_pin['cleanTreeSHA256']}"
        )
    return manifest


def resolve_optional_full_source(
    override: str | None,
    default_path: Path,
    source_pin: dict[str, Any],
) -> Path | None:
    """Return an authenticated full source tree, or None when none is present.

    A non-empty override is authoritative: it must exist and match the source
    pin. An absent recorded path is optional. A present recorded path is also
    authenticated so a stale build-machine tree cannot silently poison tests.
    """

    if override:
        path = Path(override)
        require_source_pin_match(path, source_pin)
        return path
    if default_path.is_dir():
        require_source_pin_match(default_path, source_pin)
        return default_path
    return None


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
    rejects = sorted(tree.rglob("*.rej"))
    if rejects:
        raise AssertionError(f"{patch.name} left rejects: {rejects}")
    return output


def fixture_body(path: Path, banner_lines: int = BANNER_LINES) -> str:
    text = path.read_text(encoding="utf-8")
    return "".join(text.splitlines(keepends=True)[banner_lines:])


def build_harness(root: Path, *, new_contract: bool) -> str:
    header = fixture_body(root / "DirectX11" / "CommandList.h")
    # clang rejects MSVC's extra qualification on an in-class member
    # declaration. This is a compile-only portability shim; the tested
    # flow-control region and all patched lines stay verbatim.
    header = header.replace("bool CommandList::noop();", "bool noop();")

    commandlist_cpp = fixture_body(root / "DirectX11" / "CommandList.cpp")
    marker = "static bool ParseIfCommand("
    if marker not in commandlist_cpp:
        raise AssertionError("ParseIfCommand missing from the CommandList.cpp excerpt")
    commandlist_cpp = commandlist_cpp.replace(
        marker, EXPRESSION_STUB + "\n" + marker, 1
    )

    parts = [
        PREAMBLE,
        fixture_body(root / "DirectX11" / "IniHandler.h"),
        header,
        DECLS,
        commandlist_cpp,
        PARSER_STUBS,
        fixture_body(root / "DirectX11" / "IniHandler.cpp"),
        "static wstring NormalizeIniLine(wstring wline) { size_t first, last; for (int once = 0; once < 1; ++once) {\n"
        + fixture_body(root / "IniWhitespace.inc")
        + "\n} return wline; }\n",
        MAIN,
    ]
    text = "\n".join(parts)
    if new_contract:
        text = "#define NEW_CONTRACT 1\n" + text
    return text


def extract_block(text: str, marker: str) -> str:
    match = text.find(marker)
    if match < 0:
        raise AssertionError(f"source block not found: {marker}")
    open_index = text.index("{", match)
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                if end < len(text) and text[end] == ";":
                    end += 1
                return text[match:end]
    raise AssertionError(f"unbalanced braces for {marker}")


def extract_flow_control(text: str) -> str:
    start = text.find("static bool ParseIfCommand(")
    if start < 0:
        raise AssertionError("ParseIfCommand not found")
    end_marker = "bool CommandPlaceholder::noop(bool post, bool ignore_cto_pre, bool ignore_cto_post)"
    end_start = text.find(end_marker, start)
    if end_start < 0:
        raise AssertionError("CommandPlaceholder::noop not found")
    end = text.index("{", end_start)
    depth = 0
    for index in range(end, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise AssertionError("unbalanced braces after CommandPlaceholder::noop")


class ConditionalContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = load_build_plan()
        cls.pin = cls.plan["sourcePin"]
        cls.provenance = verify_fixture(FIXTURE, cls.plan)

        cls.cxx = shutil.which("clang++") or shutil.which("c++")
        if cls.cxx is None:
            raise unittest.SkipTest("a C++ compiler is required for the conditional harness")
        if shutil.which("patch") is None:
            raise unittest.SkipTest("patch(1) is required for the conditional harness")
        if not CONDITIONAL_PATCH.is_file():
            raise AssertionError(f"missing patch {CONDITIONAL_PATCH}")

        cls._temp = tempfile.TemporaryDirectory(prefix="macgacha-conditional-")
        cls.temp = Path(cls._temp.name)
        cls.old_tree = cls.temp / "fixture-old"
        cls.new_tree = cls.temp / "fixture-new"

        shutil.copytree(FIXTURE, cls.old_tree)
        shutil.copytree(FIXTURE, cls.new_tree)
        cls.fixture_patch_output = apply_fixture_patch(cls.new_tree, CONDITIONAL_PATCH)

        cls.old_header = (cls.old_tree / "DirectX11" / "CommandList.h").read_text(
            encoding="utf-8"
        )
        cls.new_header = (cls.new_tree / "DirectX11" / "CommandList.h").read_text(
            encoding="utf-8"
        )
        cls.old_source = (cls.old_tree / "DirectX11" / "CommandList.cpp").read_text(
            encoding="utf-8"
        )
        cls.new_source = (cls.new_tree / "DirectX11" / "CommandList.cpp").read_text(
            encoding="utf-8"
        )

        cls.old_harness = cls._compile("old", cls.old_tree, new_contract=False)
        cls.new_harness = cls._compile("new", cls.new_tree, new_contract=True)

        cls.full_source = resolve_optional_full_source(
            os.environ.get("XXMI_LIBS_SOURCE"), DEFAULT_SOURCE, cls.pin
        )
        cls.full_new_source: str | None = None
        cls.full_new_header: str | None = None
        cls.full_after_cursor_source: str | None = None
        if cls.full_source is not None:
            base = cls.temp / "full-base"
            shutil.copytree(cls.full_source, base)
            logs = cls.temp / "full-logs"
            logs.mkdir()
            for patch_path in plan_patch_paths(cls.plan):
                REBUILD.apply_patch(base, patch_path, logs)
            REBUILD.apply_patch(base, CONDITIONAL_PATCH, logs)
            cls.full_new_source = (base / "DirectX11" / "CommandList.cpp").read_text(
                encoding="utf-8"
            )
            cls.full_new_header = (base / "DirectX11" / "CommandList.h").read_text(
                encoding="utf-8"
            )

            after_cursor = cls.temp / "full-after-cursor"
            shutil.copytree(cls.full_source, after_cursor)
            logs_cursor = cls.temp / "full-cursor-logs"
            logs_cursor.mkdir()
            for patch_path in plan_patch_paths(cls.plan):
                REBUILD.apply_patch(after_cursor, patch_path, logs_cursor)
            if CURSOR_PATCH.is_file():
                REBUILD.apply_patch(after_cursor, CURSOR_PATCH, logs_cursor)
                REBUILD.apply_patch(after_cursor, CONDITIONAL_PATCH, logs_cursor)
                cls.full_after_cursor_source = (
                    after_cursor / "DirectX11" / "CommandList.cpp"
                ).read_text(encoding="utf-8")
            else:
                cls.full_after_cursor_source = None

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "_temp"):
            cls._temp.cleanup()

    @classmethod
    def _compile(cls, name: str, root: Path, *, new_contract: bool) -> Path:
        cpp = cls.temp / f"conditional_harness_{name}.cpp"
        exe = cls.temp / f"conditional_harness_{name}"
        cpp.write_text(build_harness(root, new_contract=new_contract), encoding="utf-8")
        command = [
            cls.cxx,
            "-std=c++17",
            "-O0",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wno-unused-parameter",
            "-Wno-reorder",
            "-Wno-unused-function",
            "-Wno-unused-variable",
            "-Wno-unused-const-variable",
            "-Wno-unused-but-set-variable",
        ]
        command.extend(["-o", str(exe), str(cpp)])
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode != 0:
            raise AssertionError(
                f"harness compilation failed for {name}:\n"
                f"{result.stdout}{result.stderr}"
            )
        return exe

    @staticmethod
    def _run(
        harness: Path,
        scenario: str,
        *,
        primary: int = 0,
        outer: int = 0,
        inner: int = 0,
        namespace: str = "",
        optimise: bool = False,
    ) -> dict[str, int]:
        arguments = [
            str(harness),
            scenario,
            str(primary),
            str(outer),
            str(inner),
            namespace,
        ]
        if optimise:
            arguments.append("opt")
        result = subprocess.run(
            arguments,
            text=True,
            capture_output=True,
            check=True,
        )
        values: dict[str, int] = {}
        for output in result.stdout.splitlines():
            key, raw = output.split("=", 1)
            values[key] = int(raw)
        return values

    def assert_runs(self, values: dict[str, int], **expected: int) -> None:
        for index, wanted in expected.items():
            self.assertEqual(
                values[f"RAN_{index}"], wanted,
                f"RAN_{index} expected {wanted}, got {values[f'RAN_{index}']}",
            )

    def test_fixture_metadata_is_authenticated(self) -> None:
        self.assertEqual(self.provenance["source"]["commit"], self.pin["commit"])
        self.assertTrue(self.provenance["excerpts"])
        for excerpt in self.provenance["excerpts"]:
            self.assertTrue((FIXTURE / excerpt["path"]).is_file())

    def test_tampered_fixture_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macgacha-conditional-tamper-") as raw:
            copy = Path(raw)
            shutil.copytree(FIXTURE, copy / "fixture")
            target = copy / "fixture" / "DirectX11" / "CommandList.cpp"
            text = target.read_text(encoding="utf-8")
            tampered = text.replace(
                "static bool ParseIfCommand", "static bool TamperedParseIfCommand", 1
            )
            self.assertNotEqual(tampered, text)
            target.write_text(tampered, encoding="utf-8")
            with self.assertRaises(AssertionError):
                verify_fixture(copy / "fixture", self.plan)

    def test_patch_applies_with_zero_fuzz_and_retains_invalid_node(self) -> None:
        self.assertNotIn("fuzz", self.fixture_patch_output.lower())
        self.assertNotIn("bool expression_valid;", self.old_header)
        self.assertIn("bool expression_valid;", self.new_header)
        self.assertIn("expression_valid(true),", self.new_source)
        self.assertIn("goto bail;", self.old_source)

        old_if = extract_block(self.old_source, "static bool ParseIfCommand(")
        new_if = extract_block(self.new_source, "static bool ParseIfCommand(")
        old_elif = extract_block(self.old_source, "static bool ParseElseIfCommand(")
        new_elif = extract_block(self.new_source, "static bool ParseElseIfCommand(")
        for old_block, new_block in ((old_if, new_if), (old_elif, new_elif)):
            self.assertIn("bail:", old_block)
            self.assertIn("delete operation;", old_block)
            self.assertNotIn("bail:", new_block)
            self.assertNotIn("delete operation;", new_block)
            self.assertIn("expression_valid = false;", new_block)

        self.assertIn("if (!expression_valid)", extract_block(
            self.new_source, "void IfCommand::run("
        ))
        self.assertIn("if (!expression_valid)", extract_block(
            self.new_source, "bool IfCommand::optimise("
        ))
        self.assertIn("if (!expression_valid)", extract_block(
            self.new_source, "bool IfCommand::noop("
        ))

    def test_old_invalid_if_lets_guarded_body_run(self) -> None:
        """The pre-patch parser drops the if and runs its body unguarded."""

        invalid_if = self._run(self.old_harness, "if_else_missing")
        self.assertEqual(invalid_if["PARSE_ERROR"], 1)
        self.assertEqual(invalid_if["WARN_UNRECOGNISED"], 2)
        self.assertEqual(invalid_if["WARN_MISSING_IF"], 1)
        self.assertEqual(invalid_if["TOP_IFS"], 0)
        self.assert_runs(invalid_if, **{"1": 1, "2": 1, "3": 1})

        manager = self._run(self.old_harness, "manager_var")
        self.assertEqual(manager["WARN_UNRECOGNISED"], 2)
        self.assert_runs(manager, **{"1": 1, "2": 1, "3": 1})

        elif_else = self._run(self.old_harness, "elif_missing", outer=0)
        self.assertEqual(elif_else["WARN_UNRECOGNISED"], 1)
        self.assert_runs(elif_else, **{"1": 0, "2": 0, "3": 1, "4": 1})

        elif_leak = self._run(self.old_harness, "elif_missing", outer=1)
        self.assert_runs(elif_leak, **{"1": 1, "2": 1, "3": 0, "4": 1})

        nested = self._run(self.old_harness, "nested", outer=0)
        self.assert_runs(nested, **{"1": 0, "2": 0, "3": 1, "4": 1, "5": 1})

    def test_empty_conditions_survive_real_ini_whitespace_trimming(self) -> None:
        old = self._run(self.old_harness, "blank_if")
        self.assert_runs(old, **{"1": 1, "2": 1, "3": 1})
        for scenario in ("blank_if", "direct_blank_if"):
            for optimised in (False, True):
                values = self._run(self.new_harness, scenario, optimise=optimised)
                self.assertEqual(values["WARN_INVALID_COND"], 1)
                self.assertEqual(values["NULL_EVAL"], 0)
                self.assert_runs(values, **{"1": 0, "2": 0, "3": 1})
        for scenario in ("blank_elif", "blank_else_if", "direct_blank_elif"):
            for outer in (0, 1):
                values = self._run(self.new_harness, scenario, outer=outer)
                self.assertEqual(values["WARN_INVALID_COND"], 1)
                self.assert_runs(values, **{"1": outer, "2": 0, "3": 0, "4": 1})

    def test_new_invalid_if_runs_neither_branch(self) -> None:
        invalid_if = self._run(self.new_harness, "if_else_missing")
        self.assertEqual(invalid_if["PARSE_ERROR"], 1)
        self.assertEqual(invalid_if["WARN_UNRECOGNISED"], 0)
        self.assertEqual(invalid_if["WARN_INVALID_COND"], 1)
        self.assertEqual(invalid_if["WARN_MISSING_IF"], 0)
        self.assertEqual(invalid_if["TOP_IFS"], 1)
        self.assertEqual(invalid_if["IF_VALID"], 0)
        self.assertEqual(invalid_if["BRANCH_true_pre"], 1)
        self.assertEqual(invalid_if["BRANCH_false_pre"], 1)
        self.assertEqual(invalid_if["EVAL_CALLS"], 0)
        self.assertEqual(invalid_if["NULL_EVAL"], 0)
        self.assert_runs(invalid_if, **{"1": 0, "2": 0, "3": 1})

        manager = self._run(self.new_harness, "manager_var")
        self.assertEqual(manager["WARN_INVALID_COND"], 1)
        self.assertEqual(manager["WARN_UNRECOGNISED"], 0)
        self.assertEqual(manager["EVAL_CALLS"], 0)
        self.assertEqual(manager["NULL_EVAL"], 0)
        self.assert_runs(manager, **{"1": 0, "2": 0, "3": 1})

    def test_namespaced_manager_variable_resolves_when_present(self) -> None:
        values = self._run(self.new_harness, "manager_var_defined", primary=1)
        self.assertEqual(values["PARSE_ERROR"], 0)
        self.assertEqual(values["WARN_INVALID_COND"], 0)
        self.assertEqual(values["IF_VALID"], 1)
        self.assertEqual(values["NULL_EVAL"], 0)
        self.assert_runs(values, **{"1": 1, "2": 0, "3": 1})

    def test_invalid_elif_does_not_make_else_unconditional(self) -> None:
        outer_false = self._run(self.new_harness, "elif_missing", outer=0)
        self.assertEqual(outer_false["WARN_INVALID_COND"], 1)
        self.assertEqual(outer_false["WARN_UNRECOGNISED"], 0)
        self.assertEqual(outer_false["NULL_EVAL"], 0)
        self.assert_runs(outer_false, **{"1": 0, "2": 0, "3": 0, "4": 1})

        outer_true = self._run(self.new_harness, "elif_missing", outer=1)
        self.assert_runs(outer_true, **{"1": 1, "2": 0, "3": 0, "4": 1})

        else_if = self._run(self.new_harness, "elseif_missing", outer=0)
        self.assertEqual(else_if["WARN_INVALID_COND"], 1)
        self.assert_runs(else_if, **{"1": 0, "2": 0, "3": 0, "4": 1})

    def test_multi_elif_chain_fails_closed(self) -> None:
        old_else = self._run(self.old_harness, "chain", outer=0, inner=0)
        self.assertEqual(old_else["WARN_UNRECOGNISED"], 1)
        # The invalid middle elif vanished, so the final else ran even though
        # the first valid elif was false and the middle condition was unknown.
        self.assert_runs(old_else, **{"1": 0, "2": 0, "3": 0, "4": 0, "5": 1, "6": 1})

        old_leak = self._run(self.old_harness, "chain", outer=0, inner=1)
        self.assert_runs(old_leak, **{"1": 0, "2": 1, "3": 1, "4": 0, "5": 0, "6": 1})

        closed = self._run(self.new_harness, "chain", outer=0, inner=0)
        self.assertEqual(closed["WARN_INVALID_COND"], 1)
        self.assertEqual(closed["WARN_UNRECOGNISED"], 0)
        self.assertEqual(closed["EVAL_CALLS"], 2)
        self.assertEqual(closed["NULL_EVAL"], 0)
        self.assert_runs(closed, **{"1": 0, "2": 0, "3": 0, "4": 0, "5": 0, "6": 1})

        kept = self._run(self.new_harness, "chain", outer=0, inner=1)
        self.assertEqual(kept["EVAL_CALLS"], 2)
        self.assert_runs(kept, **{"1": 0, "2": 1, "3": 0, "4": 0, "5": 0, "6": 1})

        outer_true = self._run(self.new_harness, "chain", outer=1, inner=1)
        self.assertEqual(outer_true["EVAL_CALLS"], 1)
        self.assert_runs(outer_true, **{"1": 1, "2": 0, "3": 0, "4": 0, "5": 0, "6": 1})

    def test_nested_invalid_block_keeps_outer_balance(self) -> None:
        outer_false = self._run(self.new_harness, "nested", outer=0)
        self.assertEqual(outer_false["WARN_INVALID_COND"], 1)
        self.assertEqual(outer_false["WARN_MISSING_IF"], 0)
        self.assertEqual(outer_false["EVAL_CALLS"], 1)
        self.assertEqual(outer_false["NULL_EVAL"], 0)
        self.assert_runs(outer_false, **{"1": 0, "2": 0, "3": 0, "4": 1, "5": 1})

        outer_true = self._run(self.new_harness, "nested", outer=1)
        self.assertEqual(outer_true["EVAL_CALLS"], 1)
        self.assertEqual(outer_true["NULL_EVAL"], 0)
        self.assert_runs(outer_true, **{"1": 1, "2": 0, "3": 1, "4": 0, "5": 1})

    def test_invalid_if_before_valid_elif_stays_closed(self) -> None:
        values = self._run(self.new_harness, "if_missing_elif_valid", inner=1)
        self.assertEqual(values["WARN_INVALID_COND"], 1)
        self.assertEqual(values["WARN_MISSING_IF"], 0)
        self.assertEqual(values["EVAL_CALLS"], 0)
        self.assert_runs(values, **{"1": 0, "2": 0, "3": 0, "4": 1})

    def test_valid_conditions_are_unchanged(self) -> None:
        for primary in (0, 1):
            old = self._run(self.old_harness, "if_else", primary=primary)
            new = self._run(self.new_harness, "if_else", primary=primary)
            for key, value in old.items():
                if key in NEW_ONLY_KEYS:
                    continue
                self.assertEqual(new[key], value, f"if_else primary={primary} {key}")
            self.assertEqual(new["IF_VALID"], 1)
            if primary:
                self.assert_runs(new, **{"1": 1, "2": 0, "3": 1})
            else:
                self.assert_runs(new, **{"1": 0, "2": 1, "3": 1})

        for outer, inner in ((0, 0), (0, 1), (1, 0), (1, 1)):
            old = self._run(
                self.old_harness, "elif_valid", outer=outer, inner=inner
            )
            new = self._run(
                self.new_harness, "elif_valid", outer=outer, inner=inner
            )
            for key, value in old.items():
                if key in NEW_ONLY_KEYS:
                    continue
                self.assertEqual(
                    new[key], value, f"elif_valid outer={outer} inner={inner} {key}"
                )

        old_opt = self._run(self.old_harness, "if_else", primary=1, optimise=True)
        new_opt = self._run(self.new_harness, "if_else", primary=1, optimise=True)
        for key, value in old_opt.items():
            if key in NEW_ONLY_KEYS or key == "OPT_INVALID_NODES" or key == "OPT_INVALID_BRANCH_TOTAL":
                continue
            self.assertEqual(new_opt[key], value, f"if_else opt {key}")

    def test_optimiser_discards_invalid_branches_without_evaluating(self) -> None:
        cases = (
            ("if_else_missing", {}, 1),
            ("manager_var", {}, 1),
            ("elif_missing", {"outer": 0}, 1),
            ("nested", {"outer": 1}, 1),
            # A statically false valid outer if discards its whole true branch,
            # including the invalid nested node, before that node is visited.
            ("nested", {"outer": 0}, 0),
        )
        for scenario, arguments, invalid_nodes in cases:
            values = self._run(
                self.new_harness, scenario, optimise=True, **arguments
            )
            label = f"{scenario} {arguments}"
            self.assertEqual(values["OPT_INVALID_NODES"], invalid_nodes, label)
            self.assertEqual(values["OPT_INVALID_BRANCH_TOTAL"], 0, label)
            self.assertEqual(values["OPT_EVAL"], 0, label)
            # A valid outer condition may still be static-evaluated. The
            # invalid node's proof is that its branch list was discarded and
            # that evaluating its absent expression was never attempted.
            self.assertEqual(values["OPT_NULL_EVAL"], 0, label)
            self.assertEqual(values["OPT_NULL_STATIC"], 0, label)

        values = self._run(self.new_harness, "if_else_missing", optimise=True)
        self.assert_runs(values, **{"1": 0, "2": 0, "3": 1})

        values = self._run(self.new_harness, "manager_var", optimise=True)
        self.assert_runs(values, **{"1": 0, "2": 0, "3": 1})

        values = self._run(self.new_harness, "nested", outer=1, optimise=True)
        self.assert_runs(values, **{"1": 1, "2": 0, "3": 1, "4": 0, "5": 1})

    def test_post_command_list_uses_same_fail_closed_guard(self) -> None:
        old = self._run(self.old_harness, "post_invalid")
        self.assertEqual(old["WARN_UNRECOGNISED"], 2)
        self.assertEqual(old["POST_COMMANDS"], 4)
        for index in (1, 2, 3):
            self.assertEqual(old[f"RAN_POST_{index}"], 1, f"old post body{index}")

        new = self._run(self.new_harness, "post_invalid")
        self.assertEqual(new["WARN_UNRECOGNISED"], 0)
        self.assertEqual(new["WARN_INVALID_COND"], 1)
        self.assertEqual(new["POST_COMMANDS"], 2)
        self.assertEqual(new["NULL_EVAL"], 0)
        for index in (1, 2):
            self.assertEqual(new[f"RAN_POST_{index}"], 0, f"new post body{index}")
        self.assertEqual(new["RAN_POST_3"], 1)

        for primary in (0, 1):
            old_valid = self._run(self.old_harness, "post_valid", primary=primary)
            new_valid = self._run(self.new_harness, "post_valid", primary=primary)
            for key, value in old_valid.items():
                if key in NEW_ONLY_KEYS:
                    continue
                self.assertEqual(
                    new_valid[key], value, f"post_valid primary={primary} {key}"
                )

    def test_missing_endif_warns_and_never_evaluates(self) -> None:
        values = self._run(self.new_harness, "missing_endif", optimise=True)
        self.assertEqual(values["WARN_INVALID_COND"], 1)
        self.assertEqual(values["WARN_SCOPE"], 1)
        self.assertEqual(values["OPT_WARN_MISSING_ENDIF"], 1)
        self.assertEqual(values["OPT_INVALID_NODES"], 1)
        self.assertEqual(values["OPT_INVALID_BRANCH_TOTAL"], 0)
        self.assertEqual(values["NULL_EVAL"], 0)
        self.assertEqual(values["NULL_STATIC"], 0)
        # An unterminated conditional has no body boundary. The invalid node
        # stays inert, but the following lines retain the existing
        # missing-endif sibling behaviour instead of being swallowed.
        self.assert_runs(values, **{"1": 1, "2": 1})

    def test_namespace_boundary(self) -> None:
        valid = self._run(self.new_harness, "namespace", primary=1, namespace="modns")
        self.assertEqual(valid["PARSE_ERROR"], 0)
        self.assertEqual(valid["IF_VALID"], 1)
        self.assert_runs(valid, **{"1": 1, "2": 0, "3": 1})

        other = self._run(self.new_harness, "namespace", namespace="other")
        self.assertEqual(other["PARSE_ERROR"], 1)
        self.assertEqual(other["WARN_INVALID_COND"], 1)
        self.assertEqual(other["NULL_EVAL"], 0)
        self.assert_runs(other, **{"1": 0, "2": 0, "3": 1})

        old_other = self._run(self.old_harness, "namespace", namespace="other")
        self.assert_runs(old_other, **{"1": 1, "2": 1, "3": 1})

    def test_following_commands_and_other_section_unaffected(self) -> None:
        missing = self._run(self.new_harness, "if_else_missing")
        self.assert_runs(missing, **{"3": 1})

        second_true = self._run(
            self.new_harness, "second_section", primary=1
        )
        self.assertEqual(second_true["WARN_INVALID_COND"], 1)
        self.assert_runs(second_true, **{"1": 0, "2": 0, "3": 1, "4": 1, "5": 0, "6": 1})

        second_false = self._run(
            self.new_harness, "second_section", primary=0
        )
        self.assert_runs(second_false, **{"1": 0, "2": 0, "3": 1, "4": 0, "5": 1, "6": 1})

    def test_absent_full_source_is_optional(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macgacha-conditional-source-") as raw:
            root = Path(raw)
            self.assertIsNone(
                resolve_optional_full_source(None, root / "missing", self.pin)
            )
            self.assertIsNone(
                resolve_optional_full_source("", root / "missing", self.pin)
            )

    def test_wrong_full_source_override_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macgacha-conditional-source-") as raw:
            root = Path(raw)
            wrong = root / "wrong"
            wrong.mkdir()
            (wrong / "unexpected.txt").write_text("not the pinned tree\n", encoding="utf-8")
            with self.assertRaises(AssertionError):
                resolve_optional_full_source(str(wrong), root / "unused", self.pin)
            with self.assertRaises(AssertionError):
                resolve_optional_full_source(
                    str(root / "absent"), root / "unused", self.pin
                )
            with self.assertRaises(AssertionError):
                require_source_pin_match(wrong, self.pin)

    def test_authenticated_full_source_tree_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory(prefix="macgacha-conditional-source-") as raw:
            root = Path(raw)
            tree = root / "tree"
            tree.mkdir()
            (tree / "a.txt").write_text("pinned\n", encoding="utf-8")
            (tree / "DirectX11").mkdir()
            (tree / "DirectX11" / "CommandList.cpp").write_text(
                "// source\n", encoding="utf-8"
            )
            manifest = REBUILD.tree_manifest(tree)
            fake_pin = {
                "cleanTreeSHA256": manifest["sha256"],
                "cleanFileCount": manifest["fileCount"],
            }
            selected = resolve_optional_full_source(str(tree), root / "unused", fake_pin)
            self.assertEqual(selected, tree)

            (tree / "a.txt").write_text("tampered\n", encoding="utf-8")
            with self.assertRaises(AssertionError):
                resolve_optional_full_source(str(tree), root / "unused", fake_pin)

    def test_full_source_patch_chain_matches_fixture(self) -> None:
        if self.full_new_source is None or self.full_new_header is None:
            self.skipTest("pinned full XXMI Libraries source is absent")

        self.assertEqual(
            extract_flow_control(self.full_new_source),
            extract_flow_control(self.new_source),
            "patched ParseFlowControl region differs between the full tree and fixture",
        )
        self.assertEqual(
            extract_block(self.full_new_header, "class IfCommand : public CommandListCommand {"),
            extract_block(self.new_header, "class IfCommand : public CommandListCommand {"),
        )

    def test_patch_applies_after_cursor_patch(self) -> None:
        if self.full_after_cursor_source is None:
            self.skipTest("pinned full XXMI Libraries source is absent")

        self.assertEqual(
            extract_flow_control(self.full_after_cursor_source),
            extract_flow_control(self.new_source),
            "0010 region differs when applied after 0009",
        )


if __name__ == "__main__":
    unittest.main()
