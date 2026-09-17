#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2329

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

upgrade_script="$ROOT/bin/omarchy-upgrade-to-quattro-mac"
manifest="$ROOT/default/system-paths.tsv"
real_install=$(command -v ginstall || command -v install)
real_ln=$(command -v gln || command -v ln)
real_tee=$(command -v tee)
realpath_bin=$(command -v grealpath || command -v realpath)
gnu_bin=/opt/homebrew/opt/coreutils/libexec/gnubin
[[ -d $gnu_bin ]] || gnu_bin=""
test_bash=$(command -v bash)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
fake_root="$test_root/root"
calls="$test_root/sudo-calls"
mkdir -p "$fake_bin" "$fake_root"

# This is the only replaced command. It rewrites absolute system destinations
# into a scratch root, then invokes the host's real install, ln, and tee.
cat >"$fake_bin/sudo" <<'SH'
#!/bin/bash
set -euo pipefail

rewrite_path() {
  case "$1" in
    /etc/*|/usr/*) printf '%s%s' "$FAKE_ROOT" "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

printf '%s\n' "$*" >>"$CALLS"
call_number=$(wc -l <"$CALLS")
if [[ -n ${FAIL_AT:-} && $call_number == "$FAIL_AT" ]]; then
  exit 42
fi
command_name="$1"
shift
args=()
for arg in "$@"; do
  args+=("$(rewrite_path "$arg")")
done

case "$command_name" in
  install) exec "$REAL_INSTALL" "${args[@]}" ;;
  ln|tee)
    last_arg_index=$((${#args[@]} - 1))
    parent_dir=${args[$last_arg_index]%/*}
    mkdir -p "$parent_dir"
    if [[ $command_name == "ln" ]]; then
      exec "$REAL_LN" "${args[@]}"
    else
      exec "$REAL_TEE" "${args[@]}"
    fi
    ;;
  *) exec "$command_name" "${args[@]}" ;;
esac
SH
chmod +x "$fake_bin/sudo"

extract_function() {
  local start="$1" end="$2"
  awk -v start="$start" -v end="$end" '
    $0 == start { inside = 1 }
    inside && $0 ~ end { exit }
    inside { print }
  ' "$upgrade_script"
}

loader_definition=$(extract_function 'load_system_path_manifest() {' '^# A 3.x machine')
wire_definition=$(extract_function 'wire_system_paths() {' '^update_bashrc')
[[ -n $loader_definition && -n $wire_definition ]] || fail "extracted the exact manifest loader and wiring functions"
pass "extracted the exact manifest loader and wiring functions"

run_wire() {
  local selected_checkout="$1"
  local fail_at="${2:-}"
  (
    set -e
    export PATH="$fake_bin${gnu_bin:+:$gnu_bin}:$PATH"
    export FAKE_ROOT="$fake_root" CALLS="$calls" FAIL_AT="$fail_at" REAL_INSTALL="$real_install" REAL_LN="$real_ln" REAL_TEE="$real_tee"
    checkout="$selected_checkout"
    log() { :; }
    fail() {
      printf 'Error: %s\n' "$*" >&2
      exit 1
    }
    system_path_sources=()
    system_path_destinations=()
    system_path_policies=()
    system_path_source_paths=()
    declare -A system_path_seen_destinations=()
    eval "$loader_definition"
    eval "$wire_definition"
    wire_system_paths
  )
}

map_rows=()
while IFS= read -r map_row; do
  map_rows+=("$map_row")
done < <(grep -v '^#' "$manifest")
((${#map_rows[@]} == 19)) || fail "manifest has the expected 19 fixed-path rows" "rows: ${#map_rows[@]}"
pass "manifest has the expected 19 fixed-path rows"

run_wire "$ROOT"

while IFS=$'\t' read -r source destination policy; do
  target="$fake_root$destination"
  if [[ $policy == "copy" ]]; then
    [[ -f $target && ! -L $target ]] || fail "copy row creates a regular file" "$destination"
    cmp -s "$ROOT/$source" "$target" || fail "copy row preserves source bytes" "$destination"
  else
    [[ -L $target ]] || fail "link row creates a symlink" "$destination"
    [[ $(readlink "$target") == "$ROOT/$source" ]] || fail "link row points at checkout source" "$destination"
  fi
done < <(grep -v '^#' "$manifest")
pass "wiring applies every manifest row with its declared policy"

command_count=0
non_executable_command_count=0
for command_path in "$ROOT/bin"/omarchy-*; do
  if [[ -f $command_path && ! -L $command_path ]]; then
    ((command_count += 1))
    command_relpath=${command_path#"$ROOT"}
    command_relpath=${command_relpath#/}
    command_mode=$(git -C "$ROOT" ls-files -s -- "$command_relpath")
    if [[ ${command_mode%% *} == "100644" ]]; then
      ((non_executable_command_count += 1))
    fi
    command_name=${command_path##*/}
    command_target="$fake_root/usr/bin/$command_name"
    [[ -L $command_target ]] || fail "every regular bin command gets a /usr/bin link" "$command_name"
    [[ $(readlink "$command_target") == "$("$realpath_bin" -e -- "$command_path")" ]] ||
      fail "every regular bin command link uses its resolved source" "$command_name"
  fi
done
((command_count > 0)) || fail "the checkout has regular bin/omarchy-* commands"
((non_executable_command_count > 0)) || fail "the fixture covers a non-executable regular bin command"
pass "every regular bin/omarchy-* file is linked, including mode-0644 files"

zram_target="$fake_root/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf"
[[ -f $zram_target && ! -L $zram_target ]] || fail "zram drop-in is a regular file after first run"
run_wire "$ROOT"
[[ -f $zram_target && ! -L $zram_target ]] || fail "zram drop-in remains a regular file after rerun"
pass "wiring is idempotent and preserves regular-file zram behavior"

make_checkout() {
  local destination="$1"
  mkdir -p "$destination"
  cp -R "$ROOT/default" "$destination/"
  cp -R "$ROOT/etc" "$destination/"
  mkdir -p "$destination/bin"
  printf '#!/bin/bash\n' >"$destination/bin/omarchy-test"
  chmod +x "$destination/bin/omarchy-test"
}

run_rejected_manifest() {
  local label="$1" mutation="$2" fixture="$test_root/checkout-$3" invalid_calls="$test_root/calls-$3"
  make_checkout "$fixture"
  eval "$mutation"
  : >"$invalid_calls"
  if (
    export PATH="$fake_bin${gnu_bin:+:$gnu_bin}:$PATH"
    export FAKE_ROOT="$fake_root" CALLS="$invalid_calls" REAL_INSTALL="$real_install" REAL_LN="$real_ln" REAL_TEE="$real_tee"
    checkout="$fixture"
    log() { :; }
    fail() { exit 1; }
    system_path_sources=()
    system_path_destinations=()
    system_path_policies=()
    system_path_source_paths=()
    declare -A system_path_seen_destinations=()
    eval "$loader_definition"
    eval "$wire_definition"
    wire_system_paths
  ); then
    fail "invalid manifest is rejected" "$label"
  fi
  [[ ! -s $invalid_calls ]] || fail "invalid manifest fails before mutating sudo" "$label"
  pass "invalid manifest is rejected before sudo: $label"
}

first_source=${map_rows[0]%%$'\t'*}
first_destination=${map_rows[0]#*$'\t'}
first_destination=${first_destination%%$'\t'*}
mutate_manifest() {
  local fixture="$1" mutation="$2"
  local manifest_path="$fixture/default/system-paths.tsv" temporary="$fixture/default/system-paths.tsv.tmp"
  case "$mutation" in
    arbitrary-destination)
      awk -F $'\t' -v source="$first_source" 'BEGIN { OFS = "\t" } $1 == source { $2 = "/usr/lib/omarchy-arbitrary-fixed-path" } { print }' "$manifest_path" >"$temporary"
      ;;
    non-zram-omission)
      awk -F $'\t' -v source="$first_source" 'BEGIN { OFS = "\t" } $1 == source { next } { print }' "$manifest_path" >"$temporary"
      ;;
  esac
  mv "$temporary" "$manifest_path"
}
run_rejected_manifest "arbitrary valid destination" 'mutate_manifest "$fixture" arbitrary-destination' arbitrary-destination
run_rejected_manifest "non-zram row omission" 'mutate_manifest "$fixture" non-zram-omission' non-zram-omission
run_rejected_manifest "non-absolute destination" 'printf "default/uwsm/default\tusr/lib/invalid\tcopy\n" >>"$fixture/default/system-paths.tsv"' nonabsolute-destination
run_rejected_manifest "destination traversal" 'printf "default/uwsm/default\t../usr/lib/invalid\tcopy\n" >>"$fixture/default/system-paths.tsv"' destination-traversal
run_rejected_manifest "destination terminal parent" 'printf "default/uwsm/default\t/usr/lib/..\tcopy\n" >>"$fixture/default/system-paths.tsv"' destination-terminal-parent
run_rejected_manifest "unknown policy" 'printf "default/uwsm/default\t/usr/lib/invalid\tmove\n" >>"$fixture/default/system-paths.tsv"' unknown-policy
run_rejected_manifest "late malformed row" 'printf "%s\n" "bad-row" >>"$fixture/default/system-paths.tsv"' late-malformed
run_rejected_manifest "CRLF row" 'sed -i.bak "s/$/$(printf "\\r")/" "$fixture/default/system-paths.tsv"; rm -f "$fixture/default/system-paths.tsv.bak"' crlf
run_rejected_manifest "empty field" 'printf "\t/usr/lib/invalid	copy\n" >>"$fixture/default/system-paths.tsv"' empty-field
run_rejected_manifest "extra field" 'printf "default/uwsm/default	/usr/lib/invalid	copy	extra\n" >>"$fixture/default/system-paths.tsv"' extra-field
run_rejected_manifest "traversal source" 'printf "../invalid	/usr/lib/invalid	copy\n" >>"$fixture/default/system-paths.tsv"' traversal
run_rejected_manifest "repeated source separator" 'printf "default//uwsm/default	/usr/lib/invalid	copy\n" >>"$fixture/default/system-paths.tsv"' repeated-separator
run_rejected_manifest "path whitespace" 'printf "default/uwsm/bad name	/usr/lib/invalid	copy\n" >>"$fixture/default/system-paths.tsv"' whitespace
run_rejected_manifest "duplicate destination" 'printf "%s\t%s\tcopy\n" "$first_source" "$first_destination" >>"$fixture/default/system-paths.tsv"' duplicate-destination
run_rejected_manifest "missing source" 'rm -f "$fixture/$first_source"' missing-source
run_rejected_manifest "source symlink" 'rm -f "$fixture/$first_source"; ln -s "$ROOT/$first_source" "$fixture/$first_source"' source-symlink
run_rejected_manifest "source FIFO" 'rm -f "$fixture/$first_source"; mkfifo "$fixture/$first_source"' source-fifo
run_rejected_manifest "source parent symlink escape" 'outside="$test_root/outside-source"; mkdir -p "$outside"; cp "$fixture/$first_source" "$outside/10-omarchy"; rm -rf "$fixture/default/uwsm/env.d"; ln -s "$outside" "$fixture/default/uwsm/env.d"' source-parent-symlink
run_rejected_manifest "source directory" 'rm -f "$fixture/$first_source"; mkdir -p "$fixture/$first_source"' source-directory
run_rejected_manifest "broken source symlink" 'rm -f "$fixture/$first_source"; ln -s "$fixture/missing" "$fixture/$first_source"' broken-source-symlink
run_rejected_manifest "escaping profile symlink" 'outside="$test_root/outside-profile"; mkdir -p "$outside"; cp "$fixture/etc/profile.d/omarchy.sh" "$outside/omarchy.sh"; rm "$fixture/etc/profile.d/omarchy.sh"; ln -s "$outside/omarchy.sh" "$fixture/etc/profile.d/omarchy.sh"' profile-symlink
run_rejected_manifest "escaping executable command symlink" 'outside="$test_root/outside-command"; mkdir -p "$outside"; cp "$fixture/bin/omarchy-test" "$outside/omarchy-test"; rm "$fixture/bin/omarchy-test"; ln -s "$outside/omarchy-test" "$fixture/bin/omarchy-test"' command-symlink

zram_source="default/systemd/zram-generator.conf.d/90-omarchy.conf"
zram_destination="/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf"
mutate_zram_manifest() {
  local fixture="$1" mutation="$2"
  local manifest_path="$fixture/default/system-paths.tsv" temporary="$fixture/default/system-paths.tsv.tmp"
  awk -F $'\t' -v mutation="$mutation" -v source="$zram_source" -v destination="$zram_destination" 'BEGIN { OFS = "\t" } $1 == source && $2 == destination && $3 == "copy" { if (mutation == "policy") $3 = "link"; if (mutation == "source") $1 = "default/uwsm/env.d/10-omarchy"; if (mutation == "destination") $2 = "/usr/lib/systemd/zram-generator.conf" } { print }' "$manifest_path" >"$temporary"
  mv "$temporary" "$manifest_path"
}
run_rejected_manifest "zram policy mutation" 'mutate_zram_manifest "$fixture" policy' zram-policy
run_rejected_manifest "zram source mutation" 'mutate_zram_manifest "$fixture" source' zram-source
run_rejected_manifest "zram destination mutation" 'mutate_zram_manifest "$fixture" destination' zram-destination
run_rejected_manifest "zram row missing" 'grep -v "^default/systemd/zram-generator.conf.d/90-omarchy.conf" "$fixture/default/system-paths.tsv" >"$fixture/default/system-paths.tsv.tmp"; mv "$fixture/default/system-paths.tsv.tmp" "$fixture/default/system-paths.tsv"' zram-missing

: >"$calls"
set +e
run_wire "$ROOT" 3
wire_status=$?
set -e
((wire_status != 0)) || fail "injected sudo failure propagates from wiring"
pass "injected sudo failure propagates from wiring"

rm -f "$zram_target"
ln -s "$ROOT/$zram_source" "$zram_target"
run_wire "$ROOT"
[[ -f $zram_target && ! -L $zram_target ]] || fail "a prior zram symlink is replaced by a regular file"
pass "wiring replaces a prior zram symlink with a regular file"

copy_destination_dir="$fake_root/usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf"
rm -f "$copy_destination_dir"
mkdir -p "$copy_destination_dir"
: >"$calls"
set +e
run_wire "$ROOT"
wire_status=$?
set -e
((wire_status != 0)) || fail "copy wiring rejects an existing destination directory"
[[ ! -e "$copy_destination_dir/90-omarchy.conf" ]] || fail "install -T does not create a child in a copy destination directory"
pass "copy wiring fails closed on an existing destination directory"

rm -rf "$copy_destination_dir"
hostile_checkout="$test_root/checkout space * ' \" ; \$()"
make_checkout "$hostile_checkout"
run_wire "$hostile_checkout"
serialized=$(<"$fake_root/etc/omarchy.conf")
parsed=$("$test_bash" -c "$serialized; printf '%s' \"\$OMARCHY_PATH\"")
[[ $parsed == "$hostile_checkout" ]] || fail "OMARCHY_PATH serialization preserves one hostile checkout path"
pass "OMARCHY_PATH serialization is Bash-safe for hostile checkout paths"

destination_dir="$fake_root/usr/lib/systemd/user/omarchy-sleep-lock.service"
rm -f "$destination_dir"
mkdir -p "$destination_dir"
: >"$calls"
set +e
run_wire "$ROOT"
wire_status=$?
set -e
if ((wire_status == 0)); then
  fail "wiring rejects an existing real destination directory"
fi
[[ ! -e "$destination_dir/omarchy-sleep-lock.service" ]] ||
  fail "ln -sfnT does not create a child inside a destination directory"
pass "wiring fails closed on an existing destination directory"

pass "Mac fixed-path wiring rejects unsafe and non-regular manifest sources"
