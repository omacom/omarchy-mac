#!/usr/bin/env bash
# Test harness: simulate running fix-mirrors.sh and omarchy-refresh-pacman-mirrorlist
# using temporary files to show before/after without touching system files.

set -euo pipefail

ROOT="/workspaces/omarchy-mac"
WORKDIR=$(mktemp -d)
echo "Working dir: $WORKDIR"

SRC="$WORKDIR/src_mirrorlist"
DEST="$WORKDIR/dest_mirrorlist"

# Use the repository's bundled default mirrorlist as the SRC
cp "$ROOT/default/pacman/aarch64/mirrorlist" "$SRC"

# Create sample existing system mirrorlist
cat >"$DEST" <<'EOF'
# System mirrorlist
# Some comment
Server = http://old.mirror.example/$arch/$repo
Server = http://mirror.archlinux.org/$repo/os/$arch
EOF

# Prepare patched copies of the scripts (remove sudo and set SRC/DEST to temp files)
FIX_ORIG="$ROOT/fix-mirrors.sh"
REFRESH_ORIG="$ROOT/bin/omarchy-refresh-pacman-mirrorlist"
FIX_TEST="$WORKDIR/fix-mirrors-test.sh"
REFRESH_TEST="$WORKDIR/refresh-test.sh"

cp "$FIX_ORIG" "$FIX_TEST"
cp "$REFRESH_ORIG" "$REFRESH_TEST"

# Replace SRC and DEST definitions in the copies and remove sudo invocations
sed -i "s|SRC=.*|SRC=\"$SRC\"|" "$FIX_TEST"
sed -i "s|DEST=.*|DEST=\"$DEST\"|" "$FIX_TEST"
sed -i "s|sudo ||g" "$FIX_TEST"

sed -i "s|SRC=.*|SRC=\"$SRC\"|" "$REFRESH_TEST"
sed -i "s|DEST=.*|DEST=\"$DEST\"|" "$REFRESH_TEST"
sed -i "s|sudo ||g" "$REFRESH_TEST"

chmod +x "$FIX_TEST" "$REFRESH_TEST"

# Show initial state
echo
echo "--- bundled SRC (what Omarchy provides) ---"
cat "$SRC"

echo
echo "--- DEST before (system mirrorlist) ---"
cat "$DEST"

# Run fix-mirrors (default behavior: remove Omarchy servers, ensure Arch Linux ARM present)
echo
echo "--- Running fix-mirrors (apply) ---"
"$FIX_TEST" --backup

echo
echo "--- DEST after fix-mirrors ---"
cat "$DEST"

# Show backup created by fix-mirrors
echo
echo "--- Backups created (fix-mirrors) ---"
ls -l "$WORKDIR" | sed -n '1,200p'

# Reset DEST to original sample for the refresh test
cat >"$DEST" <<'EOF'
# System mirrorlist
# Some comment
Server = http://old.mirror.example/$arch/$repo
Server = http://mirror.archlinux.org/$repo/os/$arch
EOF

echo
echo "--- DEST reset to original for refresh test ---"
cat "$DEST"

# Run refresh with --prefer
echo
echo "--- Running omarchy-refresh-pacman-mirrorlist --prefer (apply) ---"
"$REFRESH_TEST" --prefer --backup

echo
echo "--- DEST after refresh --prefer ---"
cat "$DEST"

echo
echo "--- Backups created (refresh) ---"
ls -l "$WORKDIR" | sed -n '1,200p'

echo
echo "Test complete. Temp workdir: $WORKDIR"
