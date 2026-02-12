#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dexter_root="${DEXTER_ROOT:-${repo_root}/node_modules/dexter-ts}"

if [[ ! -d "$dexter_root" ]]; then
  echo "Dexter package is not installed at $dexter_root. Run bun install first." >&2
  exit 1
fi

if [[ ! -f "${dexter_root}/package.json" ]]; then
  echo "Dexter package at $dexter_root is invalid (missing package.json)." >&2
  exit 1
fi

printf '%s\n' "$dexter_root"
