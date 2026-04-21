#!/usr/bin/env bash
# Build llmos and launch an interactive REPL against it.
set -euo pipefail
cd "$(dirname "$0")"
make
exec python3 demo/bridge.py --image build/llmos.img repl
