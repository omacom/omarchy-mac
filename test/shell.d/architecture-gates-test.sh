#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A CPU architecture says nothing about the machine: aarch64 is an Apple Silicon
# Mac, a Snapdragon laptop, a Raspberry Pi or a VM. Platform decisions go through
# omarchy-hw-platform and its predicates. An architecture check is only right
# for ABI, binary availability or a repository's $arch, and each one shipped is
# listed below after review. A new one fails here until it is reviewed.
#
# Each entry is a path and text that its line contains, including the whole
# architecture expression and what it guards. An entry covers one line, and only
# when its text holds every architecture check on that line; an entry that
# covers nothing is stale.
reviewed_exceptions=$(cat <<'LIST'
# The detector: a vendor device tree only counts on the CPU it belongs to.
bin/omarchy-hw-platform if ! machine=$(uname -m) || [[ -z $machine ]]; then

# linux-omarchy is an x86_64 kernel package.
migrations/1789325478.sh [[ $(uname -m) == "x86_64" ]] || exit 0
LIST
)

architecture_pattern='uname[^|;&)`]*[[:space:]](-[[:alpha:]]*[am]|--machine|--all)|(\$\(|`)[[:space:]]*(command[[:space:]]+|/usr/bin/)?arch[[:space:]]*(\)|`)|HOSTTYPE|MACHTYPE|CARCH|process\.arch|platform\.machine|os\.uname|/proc/sys/kernel/arch|pacman-conf.*Architecture|ConditionArchitecture'

# Shipped code only: tests stub uname, and prose may mention it.
architecture_checks() {
  local root="$1" dir
  local -a dirs=()

  for dir in bin install migrations default config etc applications shell; do
    [[ -d $root/$dir ]] && dirs+=("$dir")
  done
  (( ${#dirs[@]} > 0 )) || return 0

  (cd "$root" && grep -rnIE "$architecture_pattern" "${dirs[@]}" || true) |
    grep -vE '^[^:]*/test/|^[^:]*\.md:|^[^:]*:[0-9]+:[[:space:]]*(#|//|--)' || true
}

count_architecture_checks() {
  { grep -oE "$architecture_pattern" <<<"$1" || true; } | wc -l
}

# Prints each architecture check no exception covers, then each exception that
# covers nothing. Silent when every check is reviewed.
unreviewed_architecture_checks() {
  local root="$1" exceptions="$2" path pattern line file text checks i matched
  local -a paths=() patterns=() used=() pattern_checks=()

  while read -r path pattern; do
    [[ -z $path || $path == "#"* ]] && continue
    paths+=("$path")
    patterns+=("$pattern")
    pattern_checks+=("$(count_architecture_checks "$pattern")")
    used+=(0)
  done <<<"$exceptions"

  while IFS= read -r line; do
    file=${line%%:*}
    text=${line#*:}
    text=${text#*:}
    checks=$(count_architecture_checks "$text")
    matched=0
    for i in "${!paths[@]}"; do
      if (( used[i] == 0 && pattern_checks[i] == checks )) && [[ ${paths[i]} == "$file" && $text == *"${patterns[i]}"* ]]; then
        used[i]=1
        matched=1
        break
      fi
    done
    (( matched )) || printf 'unreviewed: %s\n' "$line"
  done < <(architecture_checks "$root")

  for i in "${!paths[@]}"; do
    (( used[i] )) || printf 'stale exception: %s %s\n' "${paths[i]}" "${patterns[i]}"
  done
}

# The lint has to catch the gates it exists for, in every form they took.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/install/user/hardware/apple" "$scratch/bin" "$scratch/migrations" \
  "$scratch/default/hypr" "$scratch/install/test" "$scratch/docs"
printf '%s\n' '[[ $(uname -m) == aarch64 ]] || return 0' >"$scratch/install/user/hardware/apple/new.sh"
printf '%s\n' '#!/bin/bash' 'if [[ $HOSTTYPE == aarch64 ]]; then' '  echo qualcomm' 'fi' >"$scratch/bin/omarchy-snapdragon-thing"
printf '%s\n' 'if io.popen("uname -m"):read("l") == "aarch64" then' >"$scratch/default/hypr/apple.lua"
printf '%s\n' 'case $(uname -s -m) in' '[[ $(uname --kernel-name --machine) == *aarch64 ]]' '[[ $(command arch) == aarch64 ]]' \
  'kernel=$(uname --kernel-name)' 'uname -r | grep -m1 asahi' 'uname -r && grep -m1 asahi /proc/version' >"$scratch/install/forms.sh"
printf '%s\n' '  "install.browser.chrome": {"action":"install chrome","when":"[[ $(uname -m) == \"aarch64\" ]]"},' >"$scratch/default/menu.jsonc"
printf '%s\n' '# Only Apple Silicon; uname -m alone is not enough.' 'omarchy-hw-apple-silicon || exit 0' >"$scratch/migrations/1.sh"
printf '%s\n' 'printf "%s\n" "$(uname -m)"' >"$scratch/install/test/wifi-test.sh"
printf '%s\n' 'Run `uname -m` to see the architecture.' >"$scratch/default/README.md"

report=$(unreviewed_architecture_checks "$scratch" "")
for flagged in 'install/user/hardware/apple/new.sh:1:' 'bin/omarchy-snapdragon-thing:2:' 'default/hypr/apple.lua:1:' \
  'install/forms.sh:1:' 'install/forms.sh:2:' 'install/forms.sh:3:' 'default/menu.jsonc:1:'; do
  grep -Fq "unreviewed: $flagged" <<<"$report" || fail "the lint flags $flagged" "$report"
done
(( $(grep -c . <<<"$report") == 7 )) || fail "the lint ignores comments, tests, prose and other uname fields" "$report"
pass "the lint flags architecture-only gates and ignores comments, tests, prose and other uname fields"

report=$(unreviewed_architecture_checks "$scratch" 'bin/omarchy-snapdragon-thing if [[ $HOSTTYPE == aarch64 ]]; then
migrations/1.sh uname -m')
! grep -Fq 'bin/omarchy-snapdragon-thing' <<<"$report" || fail "a reviewed exception covers its line" "$report"
grep -Fq 'stale exception: migrations/1.sh uname -m' <<<"$report" || fail "an exception that covers nothing is stale" "$report"
pass "reviewed exceptions cover their lines and stale ones are reported"

# An exception pins the reviewed expression, so turning a reviewed ABI check
# into a platform gate on the same line fails.
report=$(unreviewed_architecture_checks "$scratch" 'default/menu.jsonc "install chrome","when":"[[ $(uname -m) == \"x86_64\" ]]"}')
grep -Fq 'unreviewed: default/menu.jsonc:1:' <<<"$report" || fail "a changed architecture expression is no longer covered" "$report"
printf '%s\n' '  "install.browser.chrome": {"disabled":"[[ $(uname -m) == aarch64 ]]","action":"install chrome","when":"[[ $(uname -m) == \"x86_64\" ]]"},' >"$scratch/default/menu.jsonc"
report=$(unreviewed_architecture_checks "$scratch" 'default/menu.jsonc "install chrome","when":"[[ $(uname -m) == \"x86_64\" ]]"}')
grep -Fq 'unreviewed: default/menu.jsonc:1:' <<<"$report" || fail "a second architecture check on a reviewed line is not covered" "$report"
pass "a changed or added architecture check on a reviewed line is no longer covered"

report=$(unreviewed_architecture_checks "$ROOT" "$reviewed_exceptions")
[[ -z $report ]] || fail "every architecture check is a reviewed ABI exception; gate platforms on omarchy-hw-platform" "$report"
pass "every architecture check is a reviewed ABI exception"
