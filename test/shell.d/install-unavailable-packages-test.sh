#!/bin/bash

# install.sh keeps a list of packages with no qualified aarch64 build and asks
# whether to try them when it has a terminal. OMARCHY_TRY_UNAVAILABLE settles
# the question without one: 1 tries them, 0 keeps the exclusion. The guided
# setup relies on 0 so a boot that runs install.sh on tty1 never stops there.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Lift the two functions out of install.sh so nothing else in it runs.
eval "$(sed -n '/^load_unavailable_packages() {/,/^}/p' "$ROOT/install.sh")"
eval "$(sed -n '/^should_attempt_unavailable() {/,/^}/p' "$ROOT/install.sh")"
# shellcheck disable=SC2034  # read by the lifted load_unavailable_packages
checkout=$ROOT
warn() { :; }
confirm() {
  printf '%s\n' "$1" >>"$work/prompts"
  return 1
}
prompts() {
  if [[ -f $work/prompts ]]; then wc -l <"$work/prompts"; else echo 0; fi
}

load_unavailable_packages
(( ${#unavailable_packages[@]} > 0 )) || fail 'the exclusion list is read' "no packages loaded from install/omarchy-aarch64-unavailable.packages"
pass 'the exclusion list is read from the checkout'

if OMARCHY_TRY_UNAVAILABLE=0 should_attempt_unavailable; then
  fail '0 keeps the exclusion'
fi
[[ $(prompts) == 0 ]] || fail '0 does not prompt'
pass 'OMARCHY_TRY_UNAVAILABLE=0 keeps the exclusion without asking'

OMARCHY_TRY_UNAVAILABLE=1 should_attempt_unavailable || fail '1 tries the packages'
[[ $(prompts) == 0 ]] || fail '1 does not prompt'
pass 'OMARCHY_TRY_UNAVAILABLE=1 tries the packages without asking'

# Unset, with a readable /dev/tty, the question is still asked; without one it
# is not. Both cases run in a subshell that redirects /dev/tty's readability
# through the test: [[ -r /dev/tty ]] is true on a terminal and in most CI
# sandboxes, so only the prompting path is asserted when it is. An answer
# exported by whoever runs the tests would be inherited here and turn this into
# a check of their shell, so it is dropped first.
unset OMARCHY_TRY_UNAVAILABLE
if [[ -r /dev/tty ]]; then
  if should_attempt_unavailable; then
    fail 'the scripted "no" is honoured'
  fi
  [[ $(prompts) == 1 ]] || fail 'without an answer, a terminal is asked' "$(prompts) prompts"
  pass 'without OMARCHY_TRY_UNAVAILABLE a terminal is still asked'
else
  if should_attempt_unavailable; then
    fail 'no terminal means no attempt'
  fi
  [[ $(prompts) == 0 ]] || fail 'no terminal means no prompt'
  pass 'without OMARCHY_TRY_UNAVAILABLE and no terminal the exclusion stands'
fi

unavailable_packages=()
if OMARCHY_TRY_UNAVAILABLE=1 should_attempt_unavailable; then
  fail 'an empty list is never attempted'
fi
pass 'an empty exclusion list short-circuits before any answer'
