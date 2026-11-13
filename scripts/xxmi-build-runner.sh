#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0

usage() {
    printf '%s\n' \
        'usage: xxmi-build-runner.sh --source FILE --runtime-root DIR --clang FILE \' \
        '         --lld-link FILE --sdk-root DIR --output FILE \' \
        '         [--lld-library-path DIR] [--expected-sha256 HEX]' >&2
}

fail() { printf 'xxmi-build-runner: %s\n' "$*" >&2; exit 1; }

source_file= runtime_root= clang_bin= lld_link= sdk_root= output= expected= lld_library_path=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) source_file=${2:-}; shift 2 ;;
        --runtime-root) runtime_root=${2:-}; shift 2 ;;
        --clang) clang_bin=${2:-}; shift 2 ;;
        --lld-link) lld_link=${2:-}; shift 2 ;;
        --sdk-root) sdk_root=${2:-}; shift 2 ;;
        --output) output=${2:-}; shift 2 ;;
        --lld-library-path) lld_library_path=${2:-}; shift 2 ;;
        --expected-sha256) expected=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done
[[ -n "$source_file" && -n "$runtime_root" && -n "$clang_bin" && -n "$lld_link" && \
    -n "$sdk_root" && -n "$output" ]] || { usage; exit 2; }

for required in "$source_file" "$clang_bin" "$lld_link" \
    "$runtime_root/include/wine/windows/windows.h" \
    "$runtime_root/lib/wine/x86_64-windows/libkernel32.a" \
    "$runtime_root/lib/wine/x86_64-windows/libuser32.a" \
    "$runtime_root/lib/wine/x86_64-windows/libshell32.a" \
    "$sdk_root/usr/include"; do
    [[ -e "$required" ]] || fail "missing build input: $required"
done
[[ -x "$clang_bin" ]] || fail "clang is not executable: $clang_bin"
[[ -x "$lld_link" ]] || fail "lld-link is not executable: $lld_link"
if [[ -n "$expected" && ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    fail '--expected-sha256 must be a lowercase 64-character SHA-256'
fi

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/macgacha-xxmi-runner.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

"$clang_bin" --target=x86_64-w64-windows-gnu \
    -DWIN32_LEAN_AND_MEAN -D_WINSOCKAPI_ -fms-extensions -fshort-wchar \
    -mno-stack-arg-probe -fno-builtin -Werror -Wall -Wextra \
    -isystem "$sdk_root/usr/include" -I "$runtime_root/include/wine/windows" \
    -c "$source_file" -o "$temp_dir/launcher.obj"

mkdir -p "$(dirname -- "$output")"
link_args=(/entry:srmi_hook_launcher_entry /subsystem:console
    /nodefaultlib /machine:x64 "/out:$output" "$temp_dir/launcher.obj"
    "$runtime_root/lib/wine/x86_64-windows/libkernel32.a"
    "$runtime_root/lib/wine/x86_64-windows/libuser32.a"
    "$runtime_root/lib/wine/x86_64-windows/libshell32.a")
if [[ -n "$lld_library_path" ]]; then
    [[ -d "$lld_library_path" ]] || fail "missing lld library path: $lld_library_path"
    env "DYLD_LIBRARY_PATH=$lld_library_path" "$lld_link" "${link_args[@]}"
else
    "$lld_link" "${link_args[@]}"
fi

file "$output"
actual=$(shasum -a 256 "$output" | awk '{print $1}')
printf 'sha256: %s\n' "$actual"
if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    fail "built runner SHA-256 does not match --expected-sha256"
fi
