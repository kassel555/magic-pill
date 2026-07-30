#!/bin/bash
#
# Turns a fresh clone into an openable Xcode project.
#
# The .xcodeproj is generated from project.yml rather than committed, so a clone
# has no project file until this runs. One script rather than three README
# steps, because "clone and it doesn't open" is a bad first minute.
#
#   ./Scripts/bootstrap.sh

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Checking for Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Xcode not found. Install it from the App Store, then run:"
    echo "  sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi
xcodebuild -version | head -1

echo "==> Checking for XcodeGen"
if ! command -v xcodegen >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "Installing XcodeGen via Homebrew…"
        brew install xcodegen
    else
        echo "XcodeGen is required and Homebrew isn't installed."
        echo "Install Homebrew from https://brew.sh, then: brew install xcodegen"
        exit 1
    fi
fi

echo "==> Generating MagicPill.xcodeproj from project.yml"
xcodegen generate

cat <<'DONE'

==> Ready.

    open MagicPill.xcodeproj

Then in Xcode:
  1. Select the MagicPill target → Signing & Capabilities.
  2. Set Team to your own Apple Developer team. If it is not
     "Rahul Kassel (BAMVK6LBVP)", also change `bundleIdPrefix` and the
     identifiers in project.yml — see "Building this yourself" in the README —
     and run this script again.
  3. Pick your iPhone as the run destination and press Run.

Note: your device must be running iOS 26.0 or later, and your Xcode must be new
enough to support your device's iOS version. An iPhone on a newer major iOS
than Xcode supports will refuse to install, which is an Xcode upgrade, not a
code change.
DONE
