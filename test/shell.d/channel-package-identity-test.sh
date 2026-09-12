#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# Exercise libalpm's provider resolution without installing packages or touching
# the host database. Ubuntu CI lacks pacman; the ARM install guest has it.
if ! command -v pacman >/dev/null; then
  pass 'pacman unavailable; native channel identity regression requires pacman'
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export CHANNEL_TEST_PACMAN="$(command -v pacman)"
export CHANNEL_TEST_CONFIG="$test_tmp/pacman.conf"
mkdir -p "$test_tmp/bin" "$test_tmp/db/local"
printf '9\n' > "$test_tmp/db/local/ALPM_DB_VERSION"
cat > "$CHANNEL_TEST_CONFIG" <<CONF
[options]
Architecture = auto
DBPath = $test_tmp/db
LogFile = $test_tmp/pacman.log
CONF
cat > "$test_tmp/bin/pacman" <<'STUB'
#!/bin/bash
exec "$CHANNEL_TEST_PACMAN" --config "$CHANNEL_TEST_CONFIG" "$@"
STUB
cat > "$test_tmp/bin/omarchy-version-channel" <<'STUB'
#!/bin/bash
printf '%s\n' "$CHANNEL_TEST_CHANNEL"
STUB
chmod +x "$test_tmp/bin/"*

write_package() {
  local name="$1" provider="${2:-}" directory="$test_tmp/db/local/$1-1-1"
  mkdir -p "$directory"
  {
    printf '%%NAME%%\n%s\n\n%%VERSION%%\n1-1\n\n%%ARCH%%\nany\n\n' "$name"
    if [[ -n $provider ]]; then printf '%%PROVIDES%%\n%s\n\n' "$provider"; fi
  } > "$directory/desc"
  : > "$directory/files"
}

current_channel() {
  CHANNEL_TEST_CHANNEL="$1" OMARCHY_PATH="${2:-/usr/share/omarchy}" \
    PATH="$test_tmp/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-channel-current"
}

write_package omarchy-dev omarchy
write_package omarchy-settings-dev omarchy-settings
[[ $(current_channel edge) == "edge" ]] || fail 'native development packages identify edge'
for channel in stable rc; do
  [[ $(current_channel "$channel") == "unknown" ]] || fail 'development providers cannot identify stable or RC'
done
[[ $(current_channel stable "$test_tmp/checkout") == "dev" ]] || fail 'linked source retains precedence over package identity'
pass 'native development providers require edge; linked source still identifies dev'

rm -rf "$test_tmp/db/local/omarchy-dev-1-1"
write_package omarchy
for channel in stable rc edge; do
  [[ $(current_channel "$channel") == "unknown" ]] || fail 'mixed native package flavors cannot identify a channel'
done
pass 'native mixed package flavors report unknown'

rm -rf "$test_tmp/db/local/omarchy-settings-dev-1-1"
write_package omarchy-settings
for channel in stable rc; do
  [[ $(current_channel "$channel") == "$channel" ]] || fail 'native stable packages retain the configured channel'
done
[[ $(current_channel edge) == "unknown" ]] || fail 'native stable packages cannot identify edge'
pass 'native stable package pair identifies stable or RC only'

rm -rf "$test_tmp/db/local/omarchy-settings-1-1"
for channel in stable rc edge; do
  [[ $(current_channel "$channel") == "unknown" ]] || fail 'incomplete native package pair cannot identify a channel'
done
pass 'native missing package reports unknown even when the query emits partial output'
