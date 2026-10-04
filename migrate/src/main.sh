#!/bin/bash -p

# omarchy:summary=Move this Mac onto Omarchy's official packages through a journaled, resumable migration
# omarchy:args=status | check | run [--target FILE] | verify
# omarchy:requires-sudo=true
# omarchy:hidden=true

# GENERATED from migrate/src by migrate/build: edit the sources there, then run
# migrate/build. One self-contained file, so it runs the same from a quattro
# checkout, from omarchy-mx-mac's final release and as a downloaded release
# asset, and needs no migration code in any package.
#
# It moves an Apple Silicon Mac running an Omarchy fork (omarchy-mac quattro,
# omarchy-mx-mac, a quattro-upstream test image) onto the official packages of
# the channel it follows: the Omarchy runtime pair from pkgs.omarchy.org (the
# omarchy-dev pair on edge), omarchy-mac and omarchy-mac-boot, and the Aurora
# boot chain, under the core Apple Silicon pacman configuration. A channel
# whose repository has no qualified Mac packages yet defers (75) with nothing
# changed; so does anything preflight refuses.
#
#   status        what this Mac's migration is doing
#   check         preflight only: says what run would do, changes nothing
#   run           migrate, or resume a migration cut short
#   verify        after the reboot: verify the new boot chain and finish
#
# Exit 0: migrated (or waiting for its reboot), or nothing to migrate. Exit 75:
# deferred, nothing changed. Any other status: a step failed part way; running
# it again resumes.
#
# Root starts over in an empty environment with a fixed PATH and reads only the
# live system. Unprivileged tests name a fixture root in
# OMARCHY_MAC_MIGRATE_ROOT.

if (( EUID == 0 )) && [[ ${1:-} != "--clean-environment" ]]; then
  exec /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/bin HOME=/root /bin/bash -p -- "${BASH_SOURCE[0]}" --clean-environment "$@"
fi
[[ ${1:-} != "--clean-environment" ]] || shift

set -euo pipefail

# shellcheck disable=SC2034 # R, fixture and self are the engine's inputs
if (( EUID == 0 )); then
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin
  R=""
  fixture=0
else
  R=${OMARCHY_MAC_MIGRATE_ROOT:-}
  if [[ $R != /?* ]]; then
    echo "omarchy-mac-migrate: run it as root: sudo omarchy-mac-migrate ${*:-status}" >&2
    exit 1
  fi
  R=${R%/}
  fixture=1
fi
self=$(realpath -- "${BASH_SOURCE[0]}")
