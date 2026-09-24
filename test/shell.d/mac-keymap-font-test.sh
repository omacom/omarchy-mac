#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir "$tmp_dir/bin"

cat >"$tmp_dir/bin/loadkeys" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$tmp_dir/bin/systemd-firstboot" <<'EOF'
#!/bin/bash
if [[ ${FIRSTBOOT_FAIL:-} == 1 ]]; then
  exit 1
fi
printf 'KEYMAP=fr\nXKBLAYOUT=fr\n' >"$OMARCHY_VCONSOLE_CONF"
EOF

cat >"$tmp_dir/bin/localectl" <<'EOF'
#!/bin/bash
if [[ $1 == set-keymap ]]; then
  sed -i "s|^KEYMAP=.*|KEYMAP=$2|" "$OMARCHY_VCONSOLE_CONF"
fi
EOF

chmod +x "$tmp_dir/bin"/*

export PATH="$tmp_dir/bin:$PATH"
export OMARCHY_VCONSOLE_CONF="$tmp_dir/vconsole.conf"

source "$ROOT/bin/omarchy-mac-setup"

write_vconsole() {
  cat >"$OMARCHY_VCONSOLE_CONF" <<'EOF'
KEYMAP=us
FONT=ter-132b
 FONT_MAP = "8859-1_to_uni"
FONT_UNIMAP=latin1
EOF
}

font_records_once() {
  [[ $(grep -Ec '^[[:space:]]*FONT[[:space:]]*=' "$OMARCHY_VCONSOLE_CONF") == 1 ]] &&
    [[ $(grep -Ec '^[[:space:]]*FONT_MAP[[:space:]]*=' "$OMARCHY_VCONSOLE_CONF") == 1 ]] &&
    [[ $(grep -Ec '^[[:space:]]*FONT_UNIMAP[[:space:]]*=' "$OMARCHY_VCONSOLE_CONF") == 1 ]]
}

fonts_preserved() {
  grep -qx 'FONT=ter-132b' "$OMARCHY_VCONSOLE_CONF" &&
    grep -qx ' FONT_MAP = "8859-1_to_uni"' "$OMARCHY_VCONSOLE_CONF" &&
    grep -qx 'FONT_UNIMAP=latin1' "$OMARCHY_VCONSOLE_CONF"
}

write_vconsole
apply_keymap fr

grep -qx 'KEYMAP=fr' "$OMARCHY_VCONSOLE_CONF" || fail 'firstboot updates the console keymap'
fonts_preserved || fail 'firstboot overwrite keeps console font records'
font_records_once || fail 'firstboot overwrite leaves one record per console font setting'
pass 'keymap setup restores all console font records after firstboot overwrites vconsole.conf'

apply_keymap fr
font_records_once || fail 're-running keymap setup duplicates console font records'
pass 're-running keymap setup leaves one record per console font setting'

write_vconsole
FIRSTBOOT_FAIL=1 apply_keymap fr
fonts_preserved || fail 'localectl fallback keeps console font records'
font_records_once || fail 'localectl fallback duplicates console font records'
pass 'localectl fallback leaves one record per console font setting'

printf 'KEYMAP=us\nXKBLAYOUT=us\n' >"$OMARCHY_VCONSOLE_CONF"
apply_keymap fr

grep -qx 'KEYMAP=fr' "$OMARCHY_VCONSOLE_CONF" || fail 'vconsole.conf without fonts still receives the keymap'
if grep -Eq '^[[:space:]]*FONT(_MAP|_UNIMAP)?[[:space:]]*=' "$OMARCHY_VCONSOLE_CONF"; then
  fail 'vconsole.conf without fonts does not add font records'
fi
pass 'vconsole.conf without fonts does not add font records'

rm -f "$OMARCHY_VCONSOLE_CONF"
apply_keymap fr
grep -qx 'KEYMAP=fr' "$OMARCHY_VCONSOLE_CONF" || fail 'missing vconsole.conf still receives the keymap'
pass 'missing vconsole.conf does not block keymap setup'
