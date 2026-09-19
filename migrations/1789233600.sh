echo "Add the MLX capability reporter to existing installations"

migrate_mlx_info() (
  set -euo pipefail
  local bin="$HOME/.local/bin" runner info temporary
  [[ -e "$bin/mlx-omarchy-info" || -L "$bin/mlx-omarchy-info" ]] && return 0
  runner="$bin/mlx-omarchy"
  [[ -x "$runner" ]] || return 0
  info=$("$runner" -I -c 'import os, mlx
print(next(p for root in mlx.__path__
           if os.access(p := os.path.join(root, "bin", "mlx-omarchy-info"), os.X_OK)))')
  temporary=$(mktemp "$bin/.mlx-omarchy-info.XXXXXX")
  trap 'rm -f "$temporary"' EXIT
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$info" >"$temporary"
  chmod 0755 "$temporary"
  mv -n "$temporary" "$bin/mlx-omarchy-info"
)

# A broken venv (orphaned by a Python minor bump, missing openblas) is a
# routine Arch state, not a reason to block every later migration at each
# login over an optional AI demo. Record and continue.
migrate_mlx_info ||
  echo "Skipping: MLX is installed but its venv did not answer." >&2
