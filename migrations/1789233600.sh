echo "Add the MLX capability reporter to existing installations"

# The caller tests this function, so bash ignores errexit inside it.
migrate_mlx_info() (
  set -euo pipefail
  local bin="$HOME/.local/bin" runner info temporary
  if [[ -e "$bin/mlx-omarchy-info" || -L "$bin/mlx-omarchy-info" ]]; then
    return 0
  fi
  runner="$bin/mlx-omarchy"
  [[ -x "$runner" ]] || return 0

  info=$("$runner" -I -c 'import os, mlx
print(next(p for root in mlx.__path__
           if os.access(p := os.path.join(root, "bin", "mlx-omarchy-info"), os.X_OK)))') || return 1
  [[ -n $info && -f $info && -x $info ]] || return 1
  temporary=$(mktemp "$bin/.mlx-omarchy-info.XXXXXX") || return 1
  trap 'rm -f "$temporary"' EXIT
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$info" >"$temporary" || return 1
  chmod 0755 "$temporary" || return 1
  mv -n "$temporary" "$bin/mlx-omarchy-info" || return 1
)

# A broken venv (orphaned by a Python minor bump, missing openblas) is a
# routine Arch state, not a reason to block every later migration at each
# login over an optional AI demo. Record and continue.
migrate_mlx_info ||
  echo "Skipping: MLX is installed but its capability reporter could not be installed." >&2
