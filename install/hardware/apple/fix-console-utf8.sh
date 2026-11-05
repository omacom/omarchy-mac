# UTF-8 mode for the Apple Silicon console. setfont does not turn parsing on,
# and getty deallocates the VT before it starts, which drops a mode set too
# early. The helper reapplies the vconsole.conf font after that reset and
# skips a graphical VT so Hyprland on tty1 is left alone.

if [[ -z ${OMARCHY_CONSOLE_UTF8_BIN:-} && $(uname -m) != "aarch64" ]]; then
  exit 0
fi

bin=${OMARCHY_CONSOLE_UTF8_BIN:-/usr/local/bin/omarchy-mac-console-utf8}
dropin=${OMARCHY_GETTY_UTF8_DROPIN:-/etc/systemd/system/getty@.service.d/omarchy-console-utf8.conf}
unit=${OMARCHY_CONSOLE_UTF8_UNIT:-/etc/systemd/system/omarchy-console-utf8.service}
source=${OMARCHY_CONSOLE_UTF8_SOURCE:-$OMARCHY_PATH/bin/omarchy-mac-console-utf8}

[[ -f $source ]] || {
  echo "omarchy-mac-console-utf8 is missing at $source" >&2
  exit 1
}

install -D -m 755 "$source" "$bin"
install -d -m 755 "$(dirname "$dropin")" "$(dirname "$unit")"

cat >"$dropin" <<EOF
[Service]
ExecStart=
ExecStart=-$bin --agetty %I linux
EOF

cat >"$unit" <<EOF
[Unit]
Description=UTF-8 mode and console font for virtual consoles
Documentation=man:vconsole.conf(5)
DefaultDependencies=no
After=local-fs.target systemd-vconsole-setup.service
Before=getty.target
ConditionPathExists=/dev/tty0
ConditionPathExists=$bin

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$bin

[Install]
WantedBy=sysinit.target
EOF

if [[ -z ${OMARCHY_CONSOLE_UTF8_SKIP_ENABLE:-} ]]; then
  systemctl daemon-reload
  systemctl enable omarchy-console-utf8.service
  "$bin" || true
fi
