#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

script="$ROOT/bin/omarchy-capture-screenrecording"
line=$(grep -F 'loudnorm=I=-14' "$script" || true)

[[ -n $line ]] || fail "screen recording finalize still normalizes audio"
[[ $line == *'-ar 48000'* ]] || fail "finalize pins AAC at 48 kHz so loudnorm cannot write 96 kHz" "$line"

pass "screen recording finalize pins audio at 48 kHz"
