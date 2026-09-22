#!/bin/bash

# Shared inert installer driver. Caller provides ROOT and a disposable work directory.
# Execute real main/option parsing with inert leaf stubs. In particular, never
# source an installed environment or run a real updater in these fixtures.
python3 - "$ROOT/install.sh" "$work/functions" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
names = ['main', 'parse_install_options', 'verify_published_pair', 'run_system_setup']
open(sys.argv[2], 'w').write('\n'.join(re.search(r'^' + name + r'\(\) \{.*?^}', text, re.M | re.S)[0] for name in names))
PY
cat >"$work/driver" <<'DRIVER'
set -euo pipefail
source "$FUNCTIONS"
checkout="$TEST_ROOT"
install_channel="${CHANNEL:-}"
channel_stage=""
log() { :; }
fail() { echo "$*" >&2; exit 1; }
step() { echo "$*" >>"$CALLS"; [[ ${FAIL_AT:-} != "$1" ]]; }
check_preconditions() { step preconditions; }
omarchy_arm_channel_stage_new() { echo "$STAGE"; }
omarchy_arm_channel_prepare() { step "prepare $2 $3"; printf '4.0.3rc1-1\n' >"$1/pair-version"; }
omarchy_arm_channel_apply_prepared() { step apply; }
cleanup_channel_install() { step cleanup; }
ensure_utf8_locale() { step locale; }
load_installed_environment() { step environment; }
protect_published_pair() { step protect; }
unprotect_published_pair() { step unprotect; }
omarchy_arm_prepare_package_sources() { step trust; }
ensure_arm_package_repo() { step repositories; }
ensure_gum() { step gum; }
ensure_aur_helper() { step aur; }
ensure_package_sources() { step recipes; }
build_omarchy_packages() { step build; }
install_omarchy_packages() { step local-install; }
install_default_package_set() { step defaults; }
seed_user_defaults() { step seed; }
run_system_setup() { step setup; }
snapshot_factory_baseline() { step snapshot; }
pacman() { echo "$2 ${PAIR_VERSION:-4.0.3rc1-1}"; }
main "$@"
DRIVER
export FUNCTIONS="$work/functions" STAGE="$work/stage" CALLS="$work/calls" TEST_ROOT="$ROOT"
mkdir "$STAGE"
run_case() {
  : >"$CALLS"
  bash "$work/driver" "$@" >"$work/out" 2>&1
}
