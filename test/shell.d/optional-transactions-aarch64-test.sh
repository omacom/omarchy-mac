#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

OMARCHY_TEST_ARCH=aarch64 run_node_test < "$SHELL_TEST_DIR/optional-transactions.js"
