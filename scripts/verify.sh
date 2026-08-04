#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

swiftc -parse $(find Sources -name '*.swift' -print)
swiftc -parse $(find Tests -name '*.swift' -print)
plutil -lint Resources/Info.plist Resources/MacDrop.entitlements Resources/ExportOptions.plist
python3 -m json.tool Assets.xcassets/Contents.json >/dev/null
python3 -m json.tool Assets.xcassets/AppIcon.appiconset/Contents.json >/dev/null

if command -v xcodegen >/dev/null && xcode-select -p 2>/dev/null | grep -q 'Xcode.app'; then
  xcodegen generate
  xcodebuild -project MacDrop.xcodeproj -scheme MacDrop -configuration Debug test CODE_SIGNING_ALLOWED=NO
else
  echo "Swift parsing and metadata validation passed. Full Xcode 26 + XcodeGen are required for build/test."
fi

