#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$project_dir/build}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
staging="$(mktemp -d "${TMPDIR:-/tmp}/meetingnotes-build.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
app_dir="$staging/MeetingNotes.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$staging/module-cache" "$staging/sources"
cp "$project_dir"/Sources/*.swift "$staging/sources/"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/MeetingNotes.icns" "$app_dir/Contents/Resources/"
xcrun swiftc -swift-version 5 -parse-as-library -O -whole-module-optimization -target arm64-apple-macosx26.0 \
    -module-cache-path "$staging/module-cache" "$staging"/sources/*.swift \
    -o "$app_dir/Contents/MacOS/MeetingNotes"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
ditto --norsrc --noextattr "$app_dir" "$output_dir/MeetingNotes.app"
echo "$output_dir/MeetingNotes.app"
