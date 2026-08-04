#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <MacDrop.app> <version> <output-directory>" >&2
  exit 64
fi

app_path="$1"
version="$2"
output_dir="$3"
staging_dir="$(mktemp -d /tmp/macdrop-dmg.XXXXXX)"
rw_dmg="$staging_dir/MacDrop-rw.dmg"
mounted_device=""

cleanup() {
  if [[ -n "$mounted_device" ]]; then
    hdiutil detach "$mounted_device" -quiet -force 2>/dev/null || true
  fi
  rm -rf "$staging_dir"
}
trap cleanup EXIT

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
background_path="$project_dir/Resources/DMG/background.png"

if [[ ! -f "$background_path" ]]; then
  swift "$script_dir/generate-dmg-background.swift" "$background_path"
fi

mkdir -p "$output_dir"
payload_dir="$staging_dir/payload"
mkdir -p "$payload_dir/.background"
ditto "$app_path" "$payload_dir/MacDrop.app"
ditto "$background_path" "$payload_dir/.background/background.png"
ln -s /Applications "$payload_dir/Applications"

if [[ -f "$app_path/Contents/Resources/AppIcon.icns" ]]; then
  ditto "$app_path/Contents/Resources/AppIcon.icns" "$payload_dir/.VolumeIcon.icns"
fi

dmg_path="$output_dir/MacDrop-$version-universal.dmg"
rm -f "$dmg_path"
volume_name="MacDrop $version"
hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$payload_dir" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$rw_dmg" >/dev/null

attach_output="$(hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen -nobrowse)"
mounted_device="$(print -r -- "$attach_output" | awk '/^\/dev\// {print $1; exit}')"
mount_dir="$(print -r -- "$attach_output" | sed -n 's#^.*\t\(/Volumes/.*\)$#\1#p' | tail -1)"

if [[ -z "$mounted_device" || -z "$mount_dir" ]]; then
  echo "could not mount temporary DMG" >&2
  exit 1
fi

if command -v SetFile >/dev/null 2>&1 && [[ -f "$mount_dir/.VolumeIcon.icns" ]]; then
  SetFile -a V "$mount_dir/.background" "$mount_dir/.VolumeIcon.icns" || true
  SetFile -a C "$mount_dir" || true
fi

if ! osascript "$script_dir/layout-dmg.applescript" "$volume_name"; then
  echo "warning: Finder layout unavailable; creating DMG with standard icon layout" >&2
fi

sync
hdiutil detach "$mounted_device" -quiet
mounted_device=""

hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path" >/dev/null
shasum -a 256 "$dmg_path" > "$dmg_path.sha256"
echo "created: $dmg_path"
