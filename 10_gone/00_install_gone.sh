#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

tool_dir="$PROJECT_ROOT/tools/GONE"
gone_commit="${GONE_COMMIT:-2288c61d21a1fd21ad01b693f59990f117566448}"
archive="$PROJECT_ROOT/tools/GONE.$gone_commit.tar.gz"
stage="$PROJECT_ROOT/tools/GONE.install.part"

if [[ ! -s "$tool_dir/.gone_commit" || "$(<"$tool_dir/.gone_commit")" != "$gone_commit" ]]; then
    curl -fL --retry 20 --retry-all-errors --retry-delay 5 \
        --output "$archive.part" \
        "https://codeload.github.com/esrud/GONE/tar.gz/$gone_commit"
    gzip -t "$archive.part"
    mv "$archive.part" "$archive"
    rm -rf "$stage"
    mkdir -p "$stage"
    tar -xzf "$archive" --strip-components=1 -C "$stage"
    test -s "$stage/Linux/script_GONE.sh"
    printf '%s\n' "$gone_commit" > "$stage/.gone_commit"
    rm -rf "$tool_dir.previous"
    if [[ -d "$tool_dir" ]]; then
        mv "$tool_dir" "$tool_dir.previous"
    fi
    mv "$stage" "$tool_dir"
    rm -rf "$tool_dir.previous"
fi
chmod +x "$tool_dir/Linux/script_GONE.sh" "$tool_dir/Linux/PROGRAMMES/"*
printf '%s\n' "$gone_commit" > "$DELIVERY_ROOT/results/GONE_git_commit.txt"
sha256sum "$archive" > "$DELIVERY_ROOT/results/GONE_archive.sha256"
