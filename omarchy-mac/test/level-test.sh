#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# A recorder that yields 40 ms of silence, 40 ms at peak 0.125 and 40 ms of a
# full-scale sample, then keeps running like a live microphone.
cat >"$work/bin/parec" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$ARGS"
echo $$ >"$PIDFILE"
python3 -c "
import struct, sys
n = 48000 // 25
out = sys.stdout.buffer
out.write(struct.pack('<%df' % n, *([0.0] * n)))
out.write(struct.pack('<%df' % n, *([0.0] * (n - 1) + [-0.125])))
out.write(struct.pack('<%df' % n, *([0.0] * (n - 1) + [1.5])))
out.flush()"
exec sleep 30
SH
printf '#!/bin/bash\nexit 0\n' >"$work/bin/omarchy-hw-apple-silicon"
chmod +x "$work/bin/parec" "$work/bin/omarchy-hw-apple-silicon"
export ARGS="$work/args" PIDFILE="$work/pid"
PATH="$work/bin:$PATH" python3 "$ROOT/bin/omarchy-audio-asahi-mic-level" >"$work/out" &
helper=$!
for _ in $(seq 50); do [[ $(wc -l <"$work/out") -ge 3 ]] && break; sleep 0.1; done
[[ $(head -3 "$work/out" | tr '\n' ' ') == "0.000 0.500 1.000 " ]] || fail 'the level is the cube root of each 40 ms peak, capped at full scale' "$(cat "$work/out")"
pass 'the level is the cube root of each 40 ms peak, capped at full scale'
grep -qx -- '--device=omarchy_asahi_mic' "$ARGS" && grep -qx -- '--property=node.name=omarchy-audio-level' "$ARGS" \
  && grep -qx -- '--property=media.category=Monitor' "$ARGS" || fail 'the mapping is recorded as a named monitor stream' "$(cat "$ARGS")"
pass 'the mapping is recorded as a named monitor stream'
kill "$helper"; wait "$helper" 2>/dev/null || true
recorder=$(cat "$PIDFILE")
for _ in $(seq 30); do kill -0 "$recorder" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$recorder" 2>/dev/null || fail 'stopping the helper stops its recorder'
pass 'stopping the helper stops its recorder'
