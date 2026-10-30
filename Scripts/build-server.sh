#!/usr/bin/env bash
#
# Builds the ShellyLanMan server binary (Go, web UI embedded) from the upstream
# sources at github.com/wimmme/shellylanman. Upstream only publishes Docker
# images, no macOS binaries, so we build it ourselves.
#
# Go and Node are fetched as official tarballs into ./.toolchain (checksums
# verified against go.dev / nodejs.org) — no Homebrew, nothing installed
# system-wide. Node is only needed at build time for the frontend bundle.
#
# Output:
#   Vendored/shellylanman          darwin/arm64 binary
#   Vendored/shellylanman.version  upstream tag + commit (read by make-app.sh)
#
# Env overrides:
#   UPSTREAM_REF   tag/branch/commit to build   (default: v1.0.0)
#   GO_VERSION     Go toolchain                 (default: 1.27.3)
#   NODE_VERSION   Node.js toolchain            (default: 26.13.0)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$ROOT/.toolchain"
UPSTREAM="$ROOT/.upstream"
VENDORED="$ROOT/Vendored"

UPSTREAM_URL="https://github.com/wimmme/shellylanman.git"
UPSTREAM_REF="${UPSTREAM_REF:-v1.0.0}"
GO_VERSION="${GO_VERSION:-1.27.3}"
NODE_VERSION="${NODE_VERSION:-26.13.0}"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: this builds for Apple Silicon (arm64); host is $(uname -m)." >&2
  exit 1
fi

mkdir -p "$TOOLCHAIN" "$VENDORED"

# Download $1 to $2 and verify it against the sha256 $3.
fetch_verified() {
  local url="$1" out="$2" sha="$3"
  curl -fsSL "$url" -o "$out.part"
  local got
  got="$(shasum -a 256 "$out.part" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then
    rm -f "$out.part"
    echo "error: checksum mismatch for $url" >&2
    echo "       expected $sha, got $got" >&2
    exit 1
  fi
  mv "$out.part" "$out"
}

# ── Go ───────────────────────────────────────────────────────────────────────
GO_DIR="$TOOLCHAIN/go-$GO_VERSION"
if [[ ! -x "$GO_DIR/bin/go" ]]; then
  echo "==> Fetching Go $GO_VERSION"
  asset="go$GO_VERSION.darwin-arm64.tar.gz"
  sha="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
for rel in json.load(sys.stdin):
    for f in rel["files"]:
        if f["filename"] == name:
            print(f["sha256"]); sys.exit(0)
sys.exit("not listed on go.dev: " + name)' "$asset")"
  fetch_verified "https://go.dev/dl/$asset" "$TOOLCHAIN/$asset" "$sha"
  rm -rf "$GO_DIR" "$TOOLCHAIN/go"
  tar -xzf "$TOOLCHAIN/$asset" -C "$TOOLCHAIN"
  mv "$TOOLCHAIN/go" "$GO_DIR"
  rm -f "$TOOLCHAIN/$asset"
fi

# ── Node ─────────────────────────────────────────────────────────────────────
NODE_DIR="$TOOLCHAIN/node-v$NODE_VERSION-darwin-arm64"
if [[ ! -x "$NODE_DIR/bin/node" ]]; then
  echo "==> Fetching Node.js $NODE_VERSION"
  asset="node-v$NODE_VERSION-darwin-arm64.tar.gz"
  sha="$(curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" | awk -v a="$asset" '$2 == a { print $1 }')"
  [[ -n "$sha" ]] || { echo "error: $asset not listed in SHASUMS256.txt" >&2; exit 1; }
  fetch_verified "https://nodejs.org/dist/v$NODE_VERSION/$asset" "$TOOLCHAIN/$asset" "$sha"
  rm -rf "$NODE_DIR"
  tar -xzf "$TOOLCHAIN/$asset" -C "$TOOLCHAIN"
  rm -f "$TOOLCHAIN/$asset"
fi

export PATH="$GO_DIR/bin:$NODE_DIR/bin:$PATH"
# Keep Go's module and build caches inside the toolchain folder as well.
export GOPATH="$TOOLCHAIN/gopath"
export GOCACHE="$TOOLCHAIN/gocache"
export GOTOOLCHAIN=local
export npm_config_cache="$TOOLCHAIN/npm-cache"
echo "    go:   $(go version)"
echo "    node: $(node --version)"

# ── Sources ──────────────────────────────────────────────────────────────────
echo "==> Checking out upstream $UPSTREAM_REF"
if [[ ! -d "$UPSTREAM/.git" ]]; then
  git clone --quiet "$UPSTREAM_URL" "$UPSTREAM"
fi
git -C "$UPSTREAM" fetch --quiet --tags origin
git -C "$UPSTREAM" checkout --quiet --force "$UPSTREAM_REF"
git -C "$UPSTREAM" clean -fdxq -e web/node_modules
COMMIT="$(git -C "$UPSTREAM" rev-parse --short HEAD)"
VERSION="$(git -C "$UPSTREAM" describe --tags --always)"
VERSION="${VERSION#v}"
echo "    $VERSION ($COMMIT)"

# ── Frontend (same steps as upstream's Dockerfile) ───────────────────────────
echo "==> Building web UI"
(
  cd "$UPSTREAM/web"
  npm ci --no-audit --no-fund --loglevel=error
  npm run --silent build
)
rm -rf "$UPSTREAM/internal/web/dist"
cp -R "$UPSTREAM/web/dist" "$UPSTREAM/internal/web/dist"

# ── Binary ───────────────────────────────────────────────────────────────────
echo "==> Building Go binary"
(
  cd "$UPSTREAM"
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath \
    -ldflags="-s -w -X github.com/wimmme/shellylanman/internal/version.Version=$VERSION -X github.com/wimmme/shellylanman/internal/version.Commit=$COMMIT" \
    -o "$VENDORED/shellylanman" ./cmd/shellylanman
)
printf '%s\n%s\n' "$VERSION" "$COMMIT" > "$VENDORED/shellylanman.version"

echo "==> Done: $VENDORED/shellylanman ($VERSION, $(du -h "$VENDORED/shellylanman" | cut -f1))"
