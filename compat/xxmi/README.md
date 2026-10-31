<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# HSR XXMI compatibility package

This directory owns the HSR-only XXMI compatibility inputs: the C hook runner,
focused SRMI patches, source pins, notices, the explicit build plan and the
offline package recipe. The app consumes the generated package under
`App/Resources/XXMI/`; no game, Wine runtime or installed state is modified by
these tools.

## Verified baseline

The package preserves the user-confirmed working configuration:

| Artifact | SHA-256 |
| --- | --- |
| SRMI `d3d11.dll` payload | `52bac2fe330559cb2896b23214881f567ffe01eea79f38769d912ece39fdff77` |
| Numeric `TextPrinter.hlsl` | `c5071500a8fb3f9ce8f2f86464ef410a83c0074145d87fc761237ec04c93d313` |
| `3dmloader.dll` injector | `6713ad15447ed94467f6e72570b530b509f0c4e3c107c853c5e0c8bfeb8d02c4` |
| `hook-runner.exe` | `7fde32d324bd1a9cd9a22995058157301b6470464ae46a9891040449c0ea565f` |
| `d3dcompiler_47.dll` | `86110ac1986ff0e4f35e1a797a3ede99233c4a5bd12edacc6dd45750e22b4171` |

The runner source in `runner/srmi_hook_launcher.c` is the MacGacha-authored
source for the verified helper. A rebuild is a new artifact: it is not assumed
byte-identical to the checked binary because lld embeds a PE timestamp, and any
new runner must be validated before it replaces the pinned hash.

## Upstream pins

- **XXMI Libraries v1.2.2**, commit
  `a7847eae82aaac32175c9a7d199673d5c9323bcd`, signed archive SHA-256
  `13034531d4855e05273d9fbaf18539ec390432950ebd5986a115e5d3e5d8e275`.
  Provides `3dmloader.dll`, the SRMI source base and `d3dcompiler_47.dll`.
- **SRMI v2.4.3**, signed archive SHA-256
  `71a22e633a88c6b8bb2a154d91e2b91e18d8e8124575fe84e34d816f285f3a3e`.
  Provides `Core/SRMI` runtime configuration and shaders plus the `d3dx.ini`
  baseline.
- **XXMI Launcher v2.4.9** is a lifecycle reference only (Hook, start, wait and
  verify order). No launcher UI, Python package code or downloader is shipped.

`source-pins.json` is the machine-readable pin and digest record. It must be
updated deliberately; nothing here fetches, merges or installs upstream code.

## Patch order

Apply with `patch -p1 --fuzz=0` from the clean XXMI Libraries source tree:

1. `0001-srmi-chain-path-overflow.patch`
2. `0002-srmi-dxgi-factory-reentrancy.patch`
3. `0003-srmi-global-lock-initialization.patch`
4. `0004-srmi-device-identity-fallback.patch`
5. `0005-srmi-resizebuffers-argument-diagnostic.patch`
6. `0006-srmi-resource-release-callback.patch`
7. `0007-srmi-ngx-context-boundary.patch` (applies after 1–6)
8. `0008-srmi-text-printer-vkd3d-all-literals.patch` (applies to the payload
   `Core/SRMI/Shaders/TextPrinter.hlsl`, not to the DLL build)

Patches 1–6 produce the verified base candidate
`c563d40c29bd039b4b22219488996218cf5e87dc176020a728914ccc9e89dff1`; patch 7
produces the final `52bac2fe…` DLL. Patch 8 produces the numeric shader used by
the live baseline. The build plan records the expected clean and patched tree
hashes, object hashes and final candidate hashes.

## Rebuild dependencies

The source build is deliberately not self-fetching. Provide every input by
path; the tools fail with a complete missing-input report instead of falling
back to a prebuilt DLL:

- macOS 27 and Apple Clang (`clang++`) for the `x86_64-pc-windows-msvc` target.
- The Clang resource include directory (for example the Xcode toolchain's
  `usr/lib/clang/<version>/include`).
- `lld-link` (the Rust toolchain's bundled copy is sufficient) and, when its
  sibling `libLLVM.dylib` is not discoverable, `--lld-library-path`.
- MSVC 14.44 headers and libraries, and Windows SDK 10.0.26100.0 headers and
  x64 import libraries.
- The clean pinned XXMI Libraries source tree.
- The authenticated third-party object tree used by the verified build
  (`DirectXTK`, `NktHookLib`, PCRE2, the MASM helper). These objects are
  hash-checked, not rebuilt; this limitation is recorded in the build manifest.
- `DirectXTK/Inc/SimpleMath.inl`, which the clean archive omits.

The checked-in `build/payload-build-plan.json` contains only tokenized paths and
recorded hashes. It never contains a temporary build root, a developer home
directory, or a developer-specific checkout path. The plan records the expected
object and candidate hashes, so a different compiler or SDK version fails closed
instead of silently producing an unverified DLL.

## Commands

### Runner

```sh
scripts/xxmi-build-runner.sh \
  --source compat/xxmi/runner/srmi_hook_launcher.c \
  --runtime-root "$MACGACHA_WINE_RUNTIME_ROOT" \
  --clang /usr/bin/clang \
  --lld-link "$LLD_LINK" \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --output "$OUTPUT_DIR/hook-runner.exe"
```

Add `--lld-library-path DIR` when `lld-link` needs its sibling LLVM library.
`--expected-sha256` makes a rebuild fail unless it matches a pinned artifact.

### Payload DLL

Validate all source, patch, SDK and object inputs without compiling:

```sh
scripts/xxmi-rebuild-payload.py --check \
  --source "$XXMI_LIBS_SOURCE" \
  --generated-assets "$REFERENCE_SOURCE" \
  --third-party-objects "$REFERENCE_OBJECTS" \
  --clangxx /usr/bin/clang++ \
  --clang-resource "$CLANG_RESOURCE_INCLUDE" \
  --msvc-include "$MSVC_INCLUDE" \
  --msvc-lib "$MSVC_LIB" \
  --windows-sdk-include "$WINDOWS_SDK_INCLUDE" \
  --windows-sdk-lib "$WINDOWS_SDK_LIB" \
  --lld-link "$LLD_LINK" \
  --lld-library-path "$LLVM_LIB_DIR"
```

Use the same arguments with `--output-dir "$OUTPUT"` to build stage 1 (base
`c563…`) and stage 2 (final `52bac2fe…`). The command verifies the clean source
tree, every patch, every compiled object and both linked candidates. It does not
run Wine or the game.

### Shader

From the repository root, applying into the payload root (the directory
containing `Core/` and `d3dx.ini`):

```sh
patch -d "$SRMI_PAYLOAD_DIR" -p1 --fuzz=0 \
  -i "$REPO_ROOT/compat/xxmi/patches/0008-srmi-text-printer-vkd3d-all-literals.patch"
```

The packaged shader must hash to `c5071500…`; the package builder rejects a
different baseline.

### Package and verification

```sh
python3 -I scripts/xxmi-package.py build \
  --runner "$OUTPUT_DIR/hook-runner.exe" \
  --injector "$XXMI_LIBS_EXTRACT/3dmloader.dll" \
  --payload-dir "$SRMI_PAYLOAD_DIR" \
  --output-dir App/Resources/XXMI \
  --pins compat/xxmi/source-pins.json

python3 -I scripts/xxmi-package.py verify \
  --directory App/Resources/XXMI \
  --pins compat/xxmi/source-pins.json
```

The payload directory may be a working PoC payload that also contains `Mods/`,
`ShaderFixes/`, `ShaderCache/`, `d3dx_user.ini` and logs. Those entries are
ignored and never packaged. Any other unexpected root file is an error, so a
personal file cannot become part of the package by accident. Symlinks, traversal
paths and case-insensitive duplicate paths are rejected.

Run the focused host tests:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -I scripts/tests/test_xxmi_package.py -v
```

## Generated artifact contract

`App/Resources/XXMI/manifest.json` (schema version 1) has:

- `schemaVersion`, `id` (`hsr-srmi`), `version`, `gameID` (`starrail`);
- `supportedRuntimeBundleIDs` (`d3dmetal-wine11.20-gptk4.0b3` only);
- `runnerPath` (`hook-runner.exe`), `injectorPath` (`3dmloader.dll`) and
  `payloadPath` (`payload/d3d11.dll`), all relative;
- `archiveSize` (Int64) and `archiveSHA256`;
- `files` (path, size, sha256 for every archive member);
- `sources` (pinned source provenance) and `license` (`GPL-3.0-only`).

`hsr-srmi.zip` contains exactly the declared regular files, no directory
entries, no symlinks and no manifest. Entries are sorted, use DEFLATE, fixed
1980-01-01 timestamps, Unix creator system and mode `0644`. The manifest is an
external sidecar and never describes or contains itself. Versioned manifests
let the app import an independently updated XXMI package without an app update.

The bundled `d3dx.ini` is normalized: `[Loader]` targets `StarRail.exe`,
`hook-runner.exe` and `d3d11.dll`; `[System] proxy_d3d11 =` is empty so the app
can substitute the actual selected runtime backend at install/snapshot time;
PoC API logging is off; developer absolute paths are rejected.

## Source updates

1. Read and authenticate the desired upstream release and source commit outside
   this repository; record the release archive and manifest hashes.
2. Replace `source-pins.json` and the patch files; keep patches in the documented
   order and update their hashes.
3. Apply the patches to a clean source copy, rebuild with the explicit toolchain
   inputs, and verify the expected output hash. Never merge an unreviewed
   upstream tree into the app.
4. Regenerate `build/payload-build-plan.json` from the new verified build
   manifest. The plan is derived data; do not hand-edit command arrays.
5. Generate the new package, run the focused tests, and keep the previous
   generated package until the new one verifies. The app-side installer keeps
   user mods, settings and previous versions; this tooling never deletes them.

A failed update must leave the previous package and all user data untouched.

## Fork app maintenance and release gate

Keep MacGacha integration in `App/Model/*ModSupport*`, `XXMIPanel`, and the
optional Launch injection adapter. Compare upstream MacGacha changes before
applying them; preserve these integration points, this fork’s update feed and
its independent signing key. Run `scripts/test.sh` after an upstream update.

Clean source checkouts can build the app without generated binary resources.
The three bundled-package app tests and the generated-package integration test
are skipped in that case; synthetic installer/import/launch tests still run.
A distributable build must supply and verify `App/Resources/XXMI` first:
`scripts/package-dmg.sh` refuses to package a missing or invalid payload.
For CI releases, publish the generated `manifest.json` and `hsr-srmi.zip` as
assets on a separate `xxmi-*` compatibility release in this fork. Supply that
tag as the draft-release workflow’s `xxmi_package_tag` input. The workflow
downloads only from its own repository and verifies against the checked-in
source pins before building. It does not download a toolchain or rebuild DLLs.

To activate app updates, provision a fork-owned Sparkle public key in
`project.yml`, the corresponding private key as the GitHub Actions
`SPARKLE_ED_PRIVATE_KEY` secret, and set `MacGachaForkUpdatesEnabled` in
`App/Info.plist` to true. Do not reuse upstream’s signing identity. The existing
release workflow verifies the signed DMG and creates a draft release; publication
is an explicit maintainer action. No fork release or signing key is provisioned
by this change.

## Corresponding-source release asset

`scripts/xxmi-source-release.py` builds a verified source archive from the pinned
clean XXMI Libraries tree, generated SimpleMath input and compatibility plan.
It includes upstream and patched sources, pins, patches, notices and rebuild
scripts. Upload it alongside the DMG and compatibility payload. The fork's
own app source is the matching GitHub release tag. Compiler toolchains and
system SDKs are separate build inputs and are not redistributed.
