#!/usr/bin/env bash
set -euo pipefail

if [[ -f App/Resources/XXMI/manifest.json ]]; then
  python3 -I scripts/xxmi-package.py verify --directory App/Resources/XXMI --pins compat/xxmi/source-pins.json
else
  printf 'note: bundled XXMI package is absent; see compat/xxmi/README.md before packaging a release.\n' >&2
fi
xcodegen generate
