#!/usr/bin/env bash
set -euo pipefail

echo "run.sh is kept for compatibility. Use ./install.sh for new installs."
exec "$(dirname "$0")/install.sh" "$@"
