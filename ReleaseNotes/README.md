<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
Keep one Markdown file per numeric version, named `<version>.md`.
Write plain English release notes for users. Do not use semicolons in prose.

A fork tag such as `v0.1.3-xxmi.3` still uses `ReleaseNotes/0.1.3.md`. The
release workflow and `scripts/package-dmg.sh` take only the numeric part, so the
fork suffix belongs in the tag and asset names, not the notes filename.

Reference repository images with raw GitHub URLs pinned to a commit, as
`ReleaseNotes/0.1.3.md` does. Do not depend on images attached to the release.


For this fork, state the numeric app version, fork tag, XXMI Libraries version,
SRMI version and compatibility-package version separately. Include New, Fixes,
Changes, Limitations and Install/Downloads. Do not call the standalone core the
full XXMI Launcher or equate successful rendering with account safety.

The current `v0.1.3-xxmi.3` release is regular/latest, with exactly the DMG and
complete standalone XXMI ZIP uploaded. Source/checksums belong to the separate
compatibility release. GitHub's automatic source links are expected. The current
release was prepared manually, not by the legacy signed-appcast draft workflow.
