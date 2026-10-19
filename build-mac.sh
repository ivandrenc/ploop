#!/usr/bin/env bash
# One-command macOS build: generates the Xcode project, builds an ad-hoc-signed NOOP.app,
# and opens it. Needs Xcode; installs XcodeGen with Homebrew if it's missing.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "XcodeGen is required: install Homebrew (https://brew.sh) then run: brew install xcodegen" >&2
    exit 1
  fi
fi

xcodegen generate

xcodebuild \
  -project Strand.xcodeproj \
  -scheme Strand \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  build | { command -v xcpretty >/dev/null 2>&1 && xcpretty || cat; }

APP="build/Build/Products/Debug/NOOP.app"
echo
echo "Built: $(pwd)/$APP"
open "$APP"
