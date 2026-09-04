#!/usr/bin/env bash
# Standalone binaries for the four targets, into dist/bin/.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/bin
for target in bun-darwin-arm64 bun-darwin-x64 bun-linux-x64 bun-linux-arm64; do
  out="dist/bin/tower-${target#bun-}"
  bun build src/cli.ts --compile --target="$target" --outfile "$out"
  echo "built $out"
done
