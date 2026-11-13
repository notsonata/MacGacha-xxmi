<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# HSR XXMI package notices and provenance

This is a provenance and attribution notice, not a new license and not a
publishing authorization. The generated package contains third-party binaries;
redistribution must satisfy the upstream licenses below and the MacGacha
project's own `LICENSE`/`NOTICE`. No binary or upstream source is committed to
Git by this directory; generated package files live under the ignored
`App/Resources/XXMI/` resource directory.

## Package inputs

The released package version is `2.4.3-macgacha.3` (in v0.3.0-xxmi.1),
which moves the shared core to XXMI Libraries v1.2.3 and adds the
conditional-fold correction. The previous package was `2.4.3-macgacha.2`, built
from XXMI Libraries v1.2.2 (commit `a7847eae82aaac32175c9a7d199673d5c9323bcd`,
signed archive `13034531d4855e05273d9fbaf18539ec390432950ebd5986a115e5d3e5d8e275`).

- **XXMI Libraries v1.2.3**, repository
  <https://github.com/SpectrumQT/XXMI-Libs-Package>, tag `v1.2.3`, commit
  `065dc746c21c71ef48bbc93cb6b90b3dcdf766e6`. Signed archive SHA-256
  `00cb5eafa7fae0848595d15ddff933ff0d6290500a0cf56b73b79a13e7d5a09e`,
  `Manifest.json` SHA-256
  `eec75b28bdb8b1f278d7861410938e84ae7b9ecfeff352614c11f196081cf106`.
  The archive signature and the per-DLL manifest signatures were verified
  against the XXMI Libraries public key pinned in XXMI Launcher. The packaged
  `3dmloader.dll` and `d3dcompiler_47.dll` are those signed release bytes; the
  `d3d11.dll` is rebuilt from the patched source. All are pinned in
  `source-pins.json`.
- **SRMI v2.4.3**, repository <https://github.com/SpectrumQT/SRMI-Package>, tag
  `v2.4.3`. Signed archive SHA-256
  `71a22e633a88c6b8bb2a154d91e2b91e18d8e8124575fe84e34d816f285f3a3e`.
  Provides the `Core/SRMI` configuration, fonts, notifications and shaders plus
  the `d3dx.ini` baseline.
- **XXMI Launcher v2.5.0**, repository
  <https://github.com/SpectrumQT/XXMI-Launcher>, tag `v2.5.0`, commit
  `4f5ef31cc237394568119f9feac2d99f44665466`. Used only to confirm the
  Hook → start → wait → verify lifecycle (unchanged from v2.4.9) and the pinned
  package signing keys. No launcher code, UI
  assets, updater or package downloader is included.
- **ZZMI Package v1.5.2 candidate**, repository
  <https://github.com/leotorrez/ZZMI-Package>, tag `v1.5.2`, commit
  `0f761241b20279849267eb179c7c2a05cff521c4`. The tagged source tarball SHA-256
  is `e9a539b15c477cf6b0fbae3fa6f45c83c41d63b0a4232fa5d97b0b55300241bd` and
  its 49-file tree hashes to
  `dfd1e79c4c6da19619bcdcab60b77eafa3cbd5bd98ab5b5bc8bc98f575d9ed2f`. It is
  GPL-3.0-only; the upstream `LICENSE` hashes to
  `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.
  Only the configuration source is used. The separate signed
  `ZZMI-PACKAGE-v1.5.2.zip` release asset (`dce62cee…`) is not a packaging
  input.
- **Third-party objects** linked into the v1.2.3 `d3d11.dll` (DirectXTK,
  PCRE2, NktHookLib and its x64 assembly helper) were rebuilt from source with
  recorded syntax-only compatibility edits. Their sources, edits, build
  commands, upstream tarballs and license texts are pinned by hash in
  `build/payload-build-plan.json` and are part of the corresponding-source
  archive.
- **Overlay fonts.** `courierbold.spritefont`, `couriersmall.spritefont` and
  `arial.spritefont` are unmodified files of the pinned XXMI Libraries v1.2.3
  source tree, embedded as `DirectX11.rc` SPRITEFONT resources exactly as the
  upstream build embeds them. They are DirectXTK MakeSpriteFont glyph atlases
  that upstream ships without a separate license file (upstream's `Overlay.cpp`
  says the proportional font follows Liberation Sans metrics); MacGacha
  redistributes them only as part of that upstream tree and makes no separate
  license determination for the source typefaces. Their hashes and git blob IDs are pinned
  in `build/payload-build-plan.json` and they are part of the
  corresponding-source archive.
- **MacGacha hook runner**, `runner/srmi_hook_launcher.c`, MacGacha-authored
  under GPL-3.0-only. The verified `hook-runner.exe` starts MacGacha's resolved
  game command and keeps the injector's global hook armed until the game window
  is ready.

## Upstream licensing

The SRMI/XXMI Libraries fork is a fork of 3DMigoto. The clean source tree
includes these upstream notices:

- 3Dmigoto source: GPL-3.0-only (`licenses/3dmigoto-GPL-3.0.txt`), with the
  upstream `COPYING` note about game-fix shaders remaining with their respective
  copyright holders (`licenses/3dmigoto-COPYING.txt`).
- Nektra Deviare-InProcess, used by upstream 3DMigoto: GPL-3.0 per the upstream
  `COPYING` text.
- DirectX Tool Kit: MIT, reproduced in `licenses/DirectXTK-MIT.txt`.
- PCRE2: BSD-3-Clause, reproduced from the source header in `licenses/PCRE2-BSD.txt`.
- crc32c-hw: Zlib license, reproduced from the source header in `licenses/crc32c-Zlib.txt`.
- NVIDIA NGX/DLSS: the NGX boundary shim uses only public interface names and
  independently written declarations. No NVIDIA SDK header, binary or runtime is
  included; the game/runtime supplies any NGX implementation.

The exact source and patch inputs for the GPL-covered DLL are recorded in
`source-pins.json` and `build/payload-build-plan.json`. Anyone redistributing
the generated DLL must be able to provide the corresponding source under the
upstream GPL terms. The package's `license` field is `GPL-3.0-only`.

## Mods and personal data

The package contains no user mods, shader fixes, shader caches, logs, crash
dumps, `d3dx_user.ini`, profile state or game files. The package builder rejects
unexpected payload-root files, symlinks and traversal paths. Mods are imported
separately by the app and never enter this compatibility archive.

## Released artifacts

The public `v0.3.0-xxmi.1` app release has exactly two uploaded assets:
`MacGacha-0.3.0-xxmi.1.dmg`, which already contains the package under
`Contents/Resources/`, and `XXMI-HSR-2.4.3-macgacha.3.zip`. GitHub's
automatic source archive links are not uploaded assets.

The standalone ZIP wraps the verified package in a
`XXMI-HSR-2.4.3-macgacha.3/` folder:

- `manifest.json` and `hsr-srmi.zip` are the verified pair the app imports.
- `README.txt` and `NOTICE.md` are the wrapper documentation and this notice.
- `licenses/` contains the third-party license texts.

The wrapper files are not part of the verified pair and are not covered by the
manifest hashes. The raw `manifest.json` and `hsr-srmi.zip`, the GPL
corresponding-source archive and its checksum sidecar are published on the
separate `xxmi-2.4.3-macgacha.3` compatibility release.

## Runtime boundary

The package is data for the app's own installer. The source tooling does not run
Wine, HSR, XXMI Launcher or the game, does not edit a managed prefix and does not
download or publish anything. The app-side installer resolves the actual
selected D3DMetal runtime path and substitutes it for the neutral
`[System] proxy_d3d11` value; no developer path is embedded in the package.

The app bundles these notices in `Contents/Resources` (from the source folder `App/Resources/XXMILicenses`). The separate `xxmi-2.4.3-macgacha.3` compatibility release provides the raw package pair and the pinned upstream and patched corresponding source. System SDKs and compiler toolchains remain separately licensed inputs.
