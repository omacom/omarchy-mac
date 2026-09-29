#!/bin/bash
# Tests of the packages against the Omarchy runtime. ROOT is the runtime checkout
# OMARCHY_TEST_RUNTIME names, with its own test helpers; without one the test skips.
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
requires_runtime "$(basename -- "$0")" || exit 0
source "$OMARCHY_TEST_RUNTIME/test/shell.d/base-test.sh"
