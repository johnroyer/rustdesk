#!/usr/bin/env bash
# Launch the Flutter desktop UI in debug mode for previewing Dart changes.
# Press `r` in the terminal for hot reload, `R` for hot restart, `q` to quit.
#
#   ./test-flutter.sh            prepare what is missing, then `flutter run`
#   ./test-flutter.sh --rebuild  force rebuilding the Rust library first
#
# The Rust library is built in the `rustdesk-builder` docker image (see
# run-builder.sh). The flutter_rust_bridge files are gitignored and must not be
# generated locally, so they are downloaded from upstream CI (`bridge-artifact`).
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# Use the Flutter version pinned in mise.toml, regardless of where the script is run from.
MISE=$(command -v mise || echo "$HOME/.local/bin/mise")
[[ -x "$MISE" ]] && eval "$("$MISE" env -s bash)"

UPSTREAM_REPO="rustdesk/rustdesk"
LIB="target/debug/liblibrustdesk.so"
BRIDGE_FILES=(src/bridge_generated.rs src/bridge_generated.io.rs
  flutter/lib/generated_bridge.dart flutter/lib/generated_bridge.freezed.dart)

rebuild=0
[[ "${1:-}" == "--rebuild" ]] && rebuild=1

die() { echo "error: $*" >&2; exit 1; }

for cmd in flutter docker gh git unzip nm; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

fetch_bridge() {
  echo "==> Looking for an upstream bridge-artifact matching this tree"
  local list sha id=""
  list=$(gh api "repos/${UPSTREAM_REPO}/actions/artifacts?name=bridge-artifact&per_page=100" \
    --jq '.artifacts[] | select(.expired == false and .workflow_run.head_branch == "master")
          | "\(.id) \(.workflow_run.head_sha)"') || die "GitHub API request failed (check GH_TOKEN)"

  while read -r aid asha; do
    [[ -z "$aid" ]] && continue
    if git cat-file -e "${asha}^{commit}" 2>/dev/null && git merge-base --is-ancestor "$asha" HEAD; then
      id=$aid; sha=$asha; break
    fi
  done <<< "$list"

  [[ -n "$id" ]] || die "no unexpired master bridge-artifact is an ancestor of HEAD; run 'git fetch rustdesk' and retry"

  echo "    artifact $id from upstream commit ${sha:0:9}"
  if ! git diff --quiet "$sha" HEAD -- src/flutter_ffi.rs; then
    echo "    warning: src/flutter_ffi.rs changed since ${sha:0:9}; the bridge may not match" >&2
  fi

  local tmp
  tmp=$(mktemp -d)
  gh api "repos/${UPSTREAM_REPO}/actions/artifacts/${id}/zip" > "$tmp/bridge.zip"
  unzip -q -o "$tmp/bridge.zip" "${BRIDGE_FILES[@]}" -d . || die "bridge files not found in artifact"
  rm -rf "$tmp"
  rebuild=1
}

missing=0
for f in "${BRIDGE_FILES[@]}"; do
  [[ -f "$f" ]] || missing=1
done
[[ $missing -eq 1 ]] && fetch_bridge

# A library built without `--features flutter` (e.g. by run-builder.sh) lacks the bridge symbols.
if [[ $rebuild -eq 0 ]] && { [[ ! -f "$LIB" ]] || ! nm -D --defined-only "$LIB" | grep 'store_dart_post_cobject' >/dev/null; }; then
  rebuild=1
fi

if [[ $rebuild -eq 1 ]]; then
  echo "==> Building Rust library with the flutter feature (docker: rustdesk-builder)"
  docker run --rm -v "$PWD":/home/user/rustdesk \
    -v rustdesk-git-cache:/home/user/.cargo/git \
    -v rustdesk-registry-cache:/home/user/.cargo/registry \
    -e PUID="$(id -u)" -e PGID="$(id -g)" \
    rustdesk-builder --features flutter --lib
fi

echo "==> Starting Flutter (r = hot reload, R = hot restart, q = quit)"
cd flutter
flutter pub get
exec flutter run -d linux
