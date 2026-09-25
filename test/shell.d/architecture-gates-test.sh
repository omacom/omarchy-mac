#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A CPU architecture says nothing about the machine: aarch64 is an Apple Silicon
# Mac, a Snapdragon laptop, a Raspberry Pi or a VM. Platform decisions go through
# omarchy-hw-platform and its predicates. An architecture check is only right
# for ABI, binary availability or a repository's $arch, and each one shipped is
# listed below after review. A new one fails here until it is reviewed.
#
# Each entry is a path and text that its line contains; one entry covers one
# line, and an entry that covers nothing is stale.
reviewed_exceptions=$(cat <<'LIST'
# The detector: a vendor device tree only counts on the CPU it belongs to.
bin/omarchy-hw-platform machine=$(uname -m)

# The MSSQL container image is published for x86_64 only.
bin/omarchy-install-docker-dbs if [[ $(uname -m) != aarch64 ]]; then
bin/omarchy-install-docker-dbs if [[ $(uname -m) == aarch64 ]]; then

# obsidian-bin is x86_64 only; every aarch64 machine installs obsidian-appimage.
bin/omarchy-install-preinstalls if [[ $(uname -m) == aarch64 ]]; then
bin/omarchy-remove-preinstalls if [[ $(uname -m) == aarch64 ]]; then
default/omarchy/omarchy-menu.jsonc "install.preinstalls":

# Vendor browser and VPN builds exist only for these CPU architectures.
default/omarchy/omarchy-menu.jsonc "install.browser.chrome":
default/omarchy/omarchy-menu.jsonc "install.browser.edge":
default/omarchy/omarchy-menu.jsonc "install.browser.brave":
default/omarchy/omarchy-menu.jsonc "install.browser.brave-origin":
default/omarchy/omarchy-menu.jsonc "install.browser.zen":
default/omarchy/omarchy-menu.jsonc "install.service.nordvpn":

# The menu reads uname once per guard batch for the rows above; it decides nothing.
shell/plugins/menu/MenuModel.js "uname -m"

# Node.js release tarballs are named for the CPU architecture.
install/user/mise-work.sh case $(uname -m) in
install/user/mise-work.sh echo "Error: unsupported Node.js architecture: $(uname -m)" >&2

# linux-omarchy is an x86_64 kernel package.
migrations/1789325478.sh [[ $(uname -m) == "x86_64" ]] || exit 0
LIST
)

architecture_pattern='uname[[:space:]]+(-[[:alpha:]]*m|--machine)|\$\([[:space:]]*arch[[:space:]]*\)|`arch`|HOSTTYPE|MACHTYPE|CARCH|process\.arch|platform\.machine|os\.uname|/proc/sys/kernel/arch|pacman-conf.*Architecture|ConditionArchitecture'

# Shipped code only: tests stub uname, and prose may mention it.
architecture_checks() {
  local root="$1" dir
  local -a dirs=()

  for dir in bin install migrations default config etc applications shell packages; do
    [[ -d $root/$dir ]] && dirs+=("$dir")
  done
  (( ${#dirs[@]} > 0 )) || return 0

  (cd "$root" && grep -rnIE "$architecture_pattern" "${dirs[@]}" || true) |
    grep -vE '^[^:]*/test/|^[^:]*\.md:|^[^:]*:[0-9]+:[[:space:]]*(#|//|--)' || true
}

# Prints each architecture check no exception covers, then each exception that
# covers nothing. Silent when every check is reviewed.
unreviewed_architecture_checks() {
  local root="$1" exceptions="$2" path pattern line file text i matched
  local -a paths=() patterns=() used=()

  while read -r path pattern; do
    [[ -z $path || $path == "#"* ]] && continue
    paths+=("$path")
    patterns+=("$pattern")
    used+=(0)
  done <<<"$exceptions"

  while IFS= read -r line; do
    file=${line%%:*}
    text=${line#*:}
    text=${text#*:}
    matched=0
    for i in "${!paths[@]}"; do
      if (( used[i] == 0 )) && [[ ${paths[i]} == "$file" && $text == *"${patterns[i]}"* ]]; then
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
  "$scratch/default/hypr" "$scratch/packages/omarchy-mac/test" "$scratch/docs"
printf '%s\n' '[[ $(uname -m) == aarch64 ]] || return 0' >"$scratch/install/user/hardware/apple/new.sh"
printf '%s\n' '#!/bin/bash' 'if [[ $HOSTTYPE == aarch64 ]]; then' '  echo qualcomm' 'fi' >"$scratch/bin/omarchy-snapdragon-thing"
printf '%s\n' 'if io.popen("uname -m"):read("l") == "aarch64" then' >"$scratch/default/hypr/apple.lua"
printf '%s\n' '# Only Apple Silicon; uname -m alone is not enough.' 'omarchy-hw-apple-silicon || exit 0' >"$scratch/migrations/1.sh"
printf '%s\n' 'printf "%s\n" "$(uname -m)"' >"$scratch/packages/omarchy-mac/test/wifi-test.sh"
printf '%s\n' 'Run `uname -m` to see the architecture.' >"$scratch/default/README.md"

report=$(unreviewed_architecture_checks "$scratch" "")
for flagged in 'install/user/hardware/apple/new.sh:1:' 'bin/omarchy-snapdragon-thing:2:' 'default/hypr/apple.lua:1:'; do
  grep -Fq "unreviewed: $flagged" <<<"$report" || fail "the lint flags $flagged" "$report"
done
(( $(grep -c . <<<"$report") == 3 )) || fail "the lint ignores comments, tests and prose" "$report"
pass "the lint flags architecture-only gates and ignores comments, tests and prose"

report=$(unreviewed_architecture_checks "$scratch" 'bin/omarchy-snapdragon-thing if [[ $HOSTTYPE == aarch64 ]]; then
migrations/1.sh uname -m')
! grep -Fq 'bin/omarchy-snapdragon-thing' <<<"$report" || fail "a reviewed exception covers its line" "$report"
grep -Fq 'stale exception: migrations/1.sh uname -m' <<<"$report" || fail "an exception that covers nothing is stale" "$report"
pass "reviewed exceptions cover their lines and stale ones are reported"

report=$(unreviewed_architecture_checks "$ROOT" "$reviewed_exceptions")
[[ -z $report ]] || fail "every architecture check is a reviewed ABI exception; gate platforms on omarchy-hw-platform" "$report"
pass "every architecture check is a reviewed ABI exception"
