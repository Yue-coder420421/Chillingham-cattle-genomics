#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../00_common/config.sh"

repo="${BWA_MEM2_ERT_REPO:-https://github.com/bwa-mem2/bwa-mem2.git}"
branch="${BWA_MEM2_ERT_BRANCH:-ert}"
source_dir="${BWA_MEM2_ERT_SOURCE_DIR:-$PROJECT_ROOT/tools/bwa-mem2-ert}"
build_threads="${BWA_MEM2_ERT_BUILD_THREADS:-16}"
index_threads="${BWA_MEM2_ERT_INDEX_THREADS:-48}"
nice_level="${BWA_MEM2_ERT_NICE_LEVEL:-0}"
index_dir="$(dirname "$BWA_MEM2_ERT_INDEX_PREFIX")"
marker="$BWA_MEM2_ERT_INDEX_PREFIX.complete"
building="$BWA_MEM2_ERT_INDEX_PREFIX.building"
persistent_marker="$BWA_MEM2_ERT_PERSISTENT_PREFIX.complete"
persistent_dir="$(dirname "$BWA_MEM2_ERT_PERSISTENT_PREFIX")"

restore_persistent_index() {
    [[ -s "$persistent_marker" ]] || return 1
    printf 'START_ERT_RESTORE time=%s source=%s target=%s\n' \
        "$(date --iso-8601=seconds)" "$BWA_MEM2_ERT_PERSISTENT_PREFIX" "$BWA_MEM2_ERT_INDEX_PREFIX"
    rm -f -- "$BWA_MEM2_ERT_INDEX_PREFIX".*
    printf '%s\t%s\trestoring\n' "$$" "$(date --iso-8601=seconds)" > "$building"
    trap 'rm -f -- "$building"' EXIT
    while IFS= read -r -d '' source; do
        suffix="${source#"$BWA_MEM2_ERT_PERSISTENT_PREFIX"}"
        destination="$BWA_MEM2_ERT_INDEX_PREFIX$suffix"
        cp --sparse=always --preserve=mode,timestamps "$source" "$destination.part"
        test "$(stat -c %s "$source")" -eq "$(stat -c %s "$destination.part")"
        mv "$destination.part" "$destination"
    done < <(
        find "$persistent_dir" -maxdepth 1 -type f \
            -name "$(basename "$BWA_MEM2_ERT_PERSISTENT_PREFIX").*" \
            ! -name '*.complete' ! -name '*.part' -print0
    )
    find "$index_dir" -maxdepth 1 -type f -name "$(basename "$BWA_MEM2_ERT_INDEX_PREFIX").*" \
        ! -name '*.building' ! -name '*.complete' ! -name '*.part' \
        -printf '%s\t%p\n' | sort -k2,2 > "$marker.part"
    test "$(wc -l < "$marker.part")" -eq "$(wc -l < "$persistent_marker")"
    test "$(awk -F '\t' '{sum += $1} END {printf "%.0f\n", sum}' "$marker.part")" = \
        "$(awk -F '\t' '{sum += $1} END {printf "%.0f\n", sum}' "$persistent_marker")"
    mv "$marker.part" "$marker"
    rm -f -- "$building"
    trap - EXIT
    printf 'DONE_ERT_RESTORE time=%s bytes=%s\n' "$(date --iso-8601=seconds)" \
        "$(awk -F '\t' '{sum += $1} END {printf "%.0f\n", sum}' "$marker")"
}

mkdir -p "$PROJECT_ROOT/tools" "$index_dir" "$PROJECT_ROOT/logs"
exec > >(tee -a "$PROJECT_ROOT/logs/bwa_mem2_ert_install.log") 2>&1

printf 'START_ERT_INSTALL time=%s repo=%s branch=%s source=%s index=%s\n' \
    "$(date --iso-8601=seconds)" "$repo" "$branch" "$source_dir" "$BWA_MEM2_ERT_INDEX_PREFIX"

if [[ ! -d "$source_dir/.git" ]]; then
    git clone --recursive --branch "$branch" "$repo" "$source_dir"
else
    git -C "$source_dir" submodule update --init --recursive
fi

commit="$(git -C "$source_dir" rev-parse HEAD)"
printf '%s\n' "$commit" > "$PROJECT_ROOT/tools/bwa-mem2-ert.commit.txt"

compat_patch="$script_dir/bwa_mem2_ert_gcc11.patch"
if git -C "$source_dir" apply --reverse --check "$compat_patch" >/dev/null 2>&1; then
    printf 'SKIP_COMPAT_PATCH already_applied=%s\n' "$compat_patch"
else
    git -C "$source_dir" apply --check "$compat_patch"
    git -C "$source_dir" apply "$compat_patch"
fi
sha256sum "$compat_patch" > "$PROJECT_ROOT/tools/bwa-mem2-ert.compat.sha256"

if [[ ! -x "$BWA_MEM2_ERT_BIN" ]]; then
    make -C "$source_dir" clean
    nice -n "$nice_level" make -C "$source_dir" -j "$build_threads" arch=avx512
fi
test -x "$BWA_MEM2_ERT_BIN"

if [[ -s "$marker" ]]; then
    printf 'SKIP_ERT_INDEX marker=%s\n' "$marker"
elif restore_persistent_index; then
    printf 'SKIP_ERT_REBUILD restored=%s\n' "$persistent_marker"
else
    rm -f -- "$BWA_MEM2_ERT_INDEX_PREFIX".*
    printf '%s\t%s\n' "$$" "$(date --iso-8601=seconds)" > "$building"
    trap 'rm -f -- "$building"' EXIT
    nice -n "$nice_level" "$BWA_MEM2_ERT_BIN" index -a ert -t "$index_threads" \
        -p "$BWA_MEM2_ERT_INDEX_PREFIX" "$REFERENCE"
    find "$index_dir" -maxdepth 1 -type f -name "$(basename "$BWA_MEM2_ERT_INDEX_PREFIX").*" \
        ! -name '*.building' ! -name '*.complete' ! -name '*.part' \
        -printf '%s\t%p\n' | sort -k2,2 > "$marker.part"
    test "$(wc -l < "$marker.part")" -gt 1
    mv "$marker.part" "$marker"
    rm -f -- "$building"
    trap - EXIT
fi

printf 'DONE_ERT_INSTALL time=%s commit=%s bytes=%s\n' \
    "$(date --iso-8601=seconds)" "$commit" \
    "$(awk -F '\t' '{sum += $1} END {printf "%.0f\n", sum}' "$marker")"
