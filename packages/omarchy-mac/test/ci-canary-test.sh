#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"
fail "CI canary: this test must fail the check"
