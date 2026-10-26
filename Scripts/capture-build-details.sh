#!/bin/sh
set -eu

# Record the source checkout, not a containing workspace or the time the app opens.
project_root=$(cd "${SRCROOT}" && pwd -P)
repo_root=$(git -C "$project_root" rev-parse --show-toplevel 2>/dev/null || true)
commit=unknown
dirty=false
if [ "$repo_root" = "$project_root" ]; then
    commit=$(git -C "$project_root" rev-parse --short HEAD)
    status=$(git -C "$project_root" status --porcelain -- .)
    if [ -n "$status" ]; then
        dirty=true
    fi
fi

output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GlookoBuild.plist"
mkdir -p "$(dirname "$output")"
if [ ! -f "$output" ]; then
    plutil -create xml1 "$output"
fi
plutil -replace commit -string "$commit" "$output"
plutil -replace dirty -bool "$dirty" "$output"
plutil -replace date -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$output"
