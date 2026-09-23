#!/bin/bash
set -euo pipefail
python3 "$(dirname -- "${BASH_SOURCE[0]}")/test-collect-e2e.py"
