#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The MLX rows must answer from the durable mlx-omarchy launcher. The chat demo
# is optional and a skipped shim migration can leave mlx-omarchy-info absent
# while MLX itself works; keying on either left Install selectable and Remove
# hidden over a working install. This runs the shipped guards exactly as the
# menu batch would, on a PATH that holds only the repo's real helpers plus a
# stub dir, so the host's installed state cannot leak into either case.

guards=$(node -e '
  const fs = require("fs")
  const path = require("path")
  const menu = require(path.join(process.env.ROOT, "shell/plugins/menu/MenuModel.js"))
  const items = menu.parseMenuJsonc(fs.readFileSync(path.join(process.env.ROOT, "default/omarchy/omarchy-menu.jsonc"), "utf8"))
  const install = items.find(item => item.id === "install.ai.mlx")
  const remove = items.find(item => item.id === "remove.ai.mlx")
  if (!install || !install.disabled || !remove || !remove.when) process.exit(1)
  process.stdout.write(install.disabled + "\n" + remove.when + "\n")
') || fail "the shipped menu declares guards on both MLX rows"

install_disabled=${guards%%$'\n'*}
remove_when=${guards#*$'\n'}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin"

evaluate() {
  # $BASH keeps the hermetic PATH from hiding the interpreter itself.
  PATH="$sandbox/bin:$ROOT/bin" "$BASH" -c "{ $1; } >/dev/null 2>&1"
}

# Installed: the launcher answers present, the optional demo and the shim are
# gone. Install must be dimmed and Remove must be shown.
printf '#!/bin/bash\nexit 0\n' >"$sandbox/bin/mlx-omarchy"
chmod +x "$sandbox/bin/mlx-omarchy"

evaluate "$install_disabled" || fail "Install dims when only the launcher is installed" \
  "guard exits nonzero with mlx-omarchy present and mlx-omarchy-info absent: $install_disabled"
pass "Install dims when only the launcher is installed"

evaluate "$remove_when" || fail "Remove shows when only the launcher is installed" \
  "guard exits nonzero with mlx-omarchy present and mlx-omarchy-info absent: $remove_when"
pass "Remove shows when only the launcher is installed"

# Not installed: Install must be selectable and Remove hidden.
rm -f "$sandbox/bin/mlx-omarchy"

if evaluate "$install_disabled"; then
  fail "Install is selectable when nothing is installed" "guard passes on an empty PATH sandbox"
fi
pass "Install is selectable when nothing is installed"

if evaluate "$remove_when"; then
  fail "Remove stays hidden when nothing is installed" "guard passes on an empty PATH sandbox"
fi
pass "Remove stays hidden when nothing is installed"
