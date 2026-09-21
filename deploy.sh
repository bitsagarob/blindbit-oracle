#!/usr/bin/env bash
#
# Build and install what blindbit-oracle.service actually runs.
#
# This exists because the service used to run a bare binary at a path in this
# repository, built by hand, with nothing recording where it came from. The only
# evidence of its provenance was a file timestamp, and on 2026-09-21 a session
# came within one command of deleting the branch it was built from after
# concluding the branch held nothing unique.
#
# So: one script, and it refuses to guess. It builds only from the `deploy`
# branch, only with a clean tree, and it stamps the commit into the binary, so
# `./blindbit-oracle --version` answers "what is running" instead of "0.0.0".
# main.go already declares that Version variable with an upstream `//todo LD
# flags` comment; this fills the blank rather than patching anything.
#
#     ./deploy.sh            build, install, restart, verify
#     ./deploy.sh --dry-run  build and verify, install nothing
#
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

BRANCH="deploy"
SERVICE="blindbit-oracle.service"
TARGET="blindbit-oracle"
DRY_RUN="${1:-}"

# Go is not on the PATH of a non-interactive shell on this box: ~/.bashrc
# returns before the line that would add it. Resolve it rather than inherit it.
GO="${GO:-}"
if [ -z "$GO" ]; then
  for candidate in "$(command -v go 2>/dev/null || true)" \
                   "$HOME/.local/go/bin/go" /usr/local/go/bin/go; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then GO="$candidate"; break; fi
  done
fi
[ -n "$GO" ] || { echo "no go toolchain found; set GO=/path/to/go" >&2; exit 1; }

# The two refusals that are the point of this script.
here="$(git rev-parse --abbrev-ref HEAD)"
if [ "$here" != "$BRANCH" ]; then
  echo "refusing: on '$here', and only '$BRANCH' is what this service runs." >&2
  echo "  git checkout $BRANCH" >&2
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "refusing: tracked files are modified, so the stamp would name a commit" >&2
  echo "that is not what gets built. Commit or stash first:" >&2
  git status --short >&2
  exit 1
fi

SHA="$(git rev-parse --short HEAD)"
echo "building $BRANCH at $SHA with $($GO version)"

mkdir -p bin
"$GO" build -ldflags "-X main.Version=$SHA" -o "bin/$TARGET.new" ./cmd/blindbit-oracle

# A binary that cannot say what it is has failed the one job this adds.
stamped="$("bin/$TARGET.new" --version 2>&1 | head -1)"
case "$stamped" in
  *"$SHA"*) echo "stamp verified: $stamped" ;;
  *) echo "refusing: built binary reports '$stamped', which does not name $SHA" >&2
     rm -f "bin/$TARGET.new"; exit 1 ;;
esac

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "dry run: leaving bin/$TARGET.new, installing nothing"
  exit 0
fi

# Swap with a way back. The hand-kept rollback binaries were deleted on
# 2026-09-21, so the previous one is held only for the length of this restart
# and removed once the service is confirmed up.
if [ -f "$TARGET" ]; then cp -p "$TARGET" "$TARGET.prev"; fi
mv "bin/$TARGET.new" "$TARGET"

echo "restarting $SERVICE"
sudo systemctl restart "$SERVICE"
sleep 3

if systemctl is-active --quiet "$SERVICE"; then
  rm -f "$TARGET.prev"
  echo "$SERVICE is active, running $SHA"
  echo "  $("./$TARGET" --version 2>&1 | head -1)"
else
  echo "$SERVICE did not come up; restoring the previous binary" >&2
  if [ -f "$TARGET.prev" ]; then mv "$TARGET.prev" "$TARGET"; sudo systemctl restart "$SERVICE"; fi
  systemctl status "$SERVICE" --no-pager --lines=20 >&2 || true
  exit 1
fi
