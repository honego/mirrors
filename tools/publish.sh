#!/usr/bin/env bash

set -Eexuo pipefail

PROJECT_TOP="$(git rev-parse --show-toplevel 2> /dev/null)"
cd "$PROJECT_TOP" || exit 1
rm -rf publish 2> dev/null || true
mkdir -p publish

rsync -av ./ publish/ \
    --exclude ".*" \
    --exclude "*.json" \
    --exclude "tools/" \
    --exclude "templates/"

find publish -maxdepth 4 -type f | sort
