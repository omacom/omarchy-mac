# shellcheck shell=bash
#
# omacom/omarchy-pkgs as the Mac release tools see it: recipes on master, the
# published aarch64 channel databases, and the repository's own interfaces.
# Publishing is CI's bin/publish-artifact on merge (a package publishes to
# every channel bin/build-matrix gives it); promotion is bin/repo advance on
# the build host. Nothing here signs, uploads or advances by itself.
#
# The caller sets $work (a scratch directory) and defines say, stop and die.

omacom_repo=${MAC_RELEASE_PKGS_REPO:-omacom/omarchy-pkgs}
omacom_git=${MAC_RELEASE_PKGS_GIT:-https://github.com/$omacom_repo.git}
omacom_branch=${MAC_RELEASE_PKGS_BRANCH:-master}
db_base=${MAC_RELEASE_DB_BASE:-https://pkgs.omarchy.org}
mac_arch=aarch64
channel_order=(edge rc stable)
# Packages that decide what a Mac boots: VM acceptance boots a generic kernel
# and cannot qualify them, so a promotion that moves one needs a record from
# a real Mac. The same rule as the fork lane's.
boot_package_pattern='^(linux-.+|m1n1.*|uboot-.+|asahi-fwextract|asahi-scripts|omarchy-apple-boot|omarchy-mac-boot|limine-mkinitcpio-hook|.+-dkms)$'

sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# ── settings ────────────────────────────────────────────────────────────────
# Read as data, never sourced. MAC_RELEASE_* keys, and the fork lane's
# ASAHI_RELEASE_* keys so one operator file serves both lanes; the
# environment wins over the file.
load_mac_settings() {
  local file=$1 line key value n=0 name
  local known=" MAC_RELEASE_AUTHOR_NAME MAC_RELEASE_AUTHOR_EMAIL ASAHI_RELEASE_AUTHOR_NAME ASAHI_RELEASE_AUTHOR_EMAIL ASAHI_RELEASE_SSH_USER ASAHI_RELEASE_VM_HOST ASAHI_RELEASE_UPDATE_HOSTS "
  declare -gA setting=()
  if [[ -e $file ]]; then
    [[ -f $file && -r $file ]] || die "$file is not a readable file"
    while IFS= read -r line || [[ -n $line ]]; do
      n=$((n + 1))
      line=${line%$'\r'}
      [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
      [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]] ||
        die "$file:$n: not a KEY=value line"
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}
      [[ $known == *" $key "* ]] || die "$file:$n: unknown key $key"
      if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
      setting[$key]=$value
    done <"$file"
  fi
  for key in $known; do
    [[ -z ${!key:-} ]] || setting[$key]=${!key}
  done
  for name in AUTHOR_NAME AUTHOR_EMAIL; do
    [[ -n ${setting[MAC_RELEASE_$name]:-} ]] || setting[MAC_RELEASE_$name]=${setting[ASAHI_RELEASE_$name]:-}
  done
  [[ -z ${setting[MAC_RELEASE_AUTHOR_NAME]} || ${setting[MAC_RELEASE_AUTHOR_NAME]} =~ ^[^\<\>]*[^\<\>[:space:]][^\<\>]*$ ]] ||
    die "MAC_RELEASE_AUTHOR_NAME is not a name"
  [[ -z ${setting[MAC_RELEASE_AUTHOR_EMAIL]} || ${setting[MAC_RELEASE_AUTHOR_EMAIL]} =~ ^[^\<\>@[:space:]]+@[^\<\>@[:space:]]+$ ]] ||
    die "MAC_RELEASE_AUTHOR_EMAIL is not an email address"
  author_name=${setting[MAC_RELEASE_AUTHOR_NAME]}
  author_email=${setting[MAC_RELEASE_AUTHOR_EMAIL]}
}

# ── the packages repository ─────────────────────────────────────────────────
omacom_clone() {
  pkgs=$work/omacom-pkgs
  if [[ ! -d $pkgs/.git ]]; then
    git clone --quiet --filter=blob:none --no-checkout --sparse --branch "$omacom_branch" "$omacom_git" "$pkgs" 2>"$work/git.err" ||
      die "could not clone $omacom_git: $(tail -n 3 "$work/git.err")"
  fi
  git -C "$pkgs" fetch --quiet origin "+refs/heads/$omacom_branch:refs/remotes/origin/$omacom_branch" 2>"$work/git.err" ||
    die "could not fetch $omacom_branch of $omacom_git: $(tail -n 3 "$work/git.err")"
  pkgs_head=$(git -C "$pkgs" rev-parse "refs/remotes/origin/$omacom_branch")
}

recipe_exists() {
  [[ -n $(git -C "$pkgs" ls-tree "$pkgs_head" -- "pkgbuilds/$1/PKGBUILD" 2>/dev/null) ]]
}

# pkgbuilds/NAME at master's head, as files under $work/recipes/NAME.
recipe_dir() {
  local name=$1 dir=$work/recipes/$1 entry
  recipe=$dir
  [[ -f $dir/PKGBUILD ]] && return 0
  mkdir -p "$dir"
  while IFS=$'\t' read -r _ entry; do
    mkdir -p "$dir/$(dirname "${entry#pkgbuilds/$name/}")"
    git -C "$pkgs" show "$pkgs_head:$entry" >"$dir/${entry#pkgbuilds/$name/}" 2>/dev/null ||
      die "could not read $entry on $omacom_branch"
  done < <(git -C "$pkgs" ls-tree -r "$pkgs_head" -- "pkgbuilds/$name/" | awk -F'\t' '$1 ~ / blob / { print "x\t" $2 }')
  [[ -f $dir/PKGBUILD ]] || die "pkgbuilds/$name has no PKGBUILD on $omacom_branch"
}

# One variable of a PKGBUILD the way makepkg sees it (CARCH set, arrays
# joined with spaces), as helpers/package-metadata.sh reads it; "version" is
# the version pacman records, [epoch:]pkgver-pkgrel.
pkgbuild_var() {
  (cd "$1" && env -u OMARCHY_SRC CARCH="$mac_arch" "$BASH" -c '
    source ./PKGBUILD >/dev/null 2>&1
    if [[ $1 == version ]]; then
      printf "%s\n" "${epoch:+$epoch:}$pkgver-$pkgrel"
    else
      declare -n value=$1
      printf "%s\n" "${value[*]}"
    fi
  ' _ "$2")
}

# The first element of a PKGBUILD array.
pkgbuild_first() {
  (cd "$1" && env -u OMARCHY_SRC CARCH="$mac_arch" "$BASH" -c '
    source ./PKGBUILD >/dev/null 2>&1
    declare -n value=$1
    printf "%s\n" "${value[0]:-}"
  ' _ "$2")
}

metadata() {
  local file=$1/.omarchy/package.json
  [[ -f $file ]] || { printf '%s\n' "${3:-}"; return 0; }
  jq -r --arg default "${3:-}" "$2 // \$default" "$file"
}

metadata_has_channels() {
  [[ -f $1/.omarchy/package.json ]] && jq -e 'has("channels")' "$1/.omarchy/package.json" >/dev/null
}

# Channels the recipe may be published to (no key: all of them).
recipe_channels() {
  if metadata_has_channels "$1"; then
    jq -r '(.channels // [])[]' "$1/.omarchy/package.json" | tr '\n' ' ' | sed 's/ $//'
  else
    printf '%s\n' "${channel_order[*]}"
  fi
}

# Whether CHANNEL gets its own build of a package rather than a copy, once
# the package is a member there: package_builds_for_mirror and
# package_moves_to_channel in helpers/package-metadata.sh. rc builds the rc
# pins and the fast ring; stable builds the fast ring but never a pin. What
# builds natively is what bin/repo advance never copies over. Takes the
# package's release_ring and pinned values.
native_build() {
  local channel=$1 ring=$2 pinned=$3
  case $channel in
    rc) [[ $pinned == true || $ring == fast ]] ;;
    stable) [[ $pinned != true && $ring == fast ]] ;;
    *) return 1 ;;
  esac
}

# ── channel databases ───────────────────────────────────────────────────────
# CHANNEL/ARCH's omarchy.db into $work/db/CHANNEL-ARCH.db. Returns 1 when
# the channel has no database for that architecture (HTTP 404, or no such
# path); anything else that goes wrong, an unreadable file included, is a
# stop, never an empty channel.
# Over HTTP the query string keeps a cached copy from answering, so a check
# after an advance reads what the repository serves now.
fetch_db() {
  local channel=$1 arch=$2 out=$work/db/$1-$2.db url code status=0
  mkdir -p "$work/db"
  [[ -s $out ]] && return 0
  url=$db_base/$channel/$arch/omarchy.db.tar.zst
  if [[ $url == file://* ]]; then
    [[ ${url#file://} == /* && $url != *%* ]] || die "$db_base: a local database base must be file:///<absolute path>, without escapes"
    [[ -e ${url#file://} ]] || return 1
  fi
  [[ $url != http* ]] || url+="?fresh=$(date +%s)$RANDOM"
  code=$(curl --silent --show-error --location --max-time 120 -H 'Cache-Control: no-cache' \
    -o "$out" -w '%{http_code}' "$url" 2>"$work/curl.err") || status=$?
  if (( status == 0 )) && [[ $code == 200 || ($url == file://* && -s $out) ]]; then
    return 0
  fi
  rm -f "$out"
  [[ $url == file://* || $code != 404 ]] || return 1
  die "could not read $channel/$arch/omarchy.db (curl exit $status, HTTP $code): $(head -c 300 "$work/curl.err")"
}

# Every entry of a database: name, base, version, filename, sha256 (tabs).
db_entries() {
  local db=$1 dir
  dir=$(mktemp -d "$work/dbx.XXXXXX")
  tar -xf "$db" -C "$dir" 2>/dev/null || die "could not read $db"
  find "$dir" -name desc -type f -print0 | sort -z | xargs -0 awk '
    function emit() { if (name != "") printf "%s\t%s\t%s\t%s\t%s\n", name, (base == "" ? name : base), version, filename, sha; name = base = version = filename = sha = "" }
    FNR == 1 { emit() }
    /^%NAME%$/ { getline; name = $0; next }
    /^%BASE%$/ { getline; base = $0; next }
    /^%VERSION%$/ { getline; version = $0; next }
    /^%FILENAME%$/ { getline; filename = $0; next }
    /^%SHA256SUM%$/ { getline; sha = $0; next }
    END { emit() }'
  rm -rf "$dir"
}

# The entries of CHANNEL/aarch64 whose name or base is one of PACKAGES, into
# the file OUT, sorted. An unpublished channel has none.
channel_set() {
  local channel=$1 out=$2
  shift 2
  : >"$out"
  fetch_db "$channel" "$mac_arch" || return 0
  db_entries "$work/db/$channel-$mac_arch.db" | awk -F'\t' -v want=" $* " 'index(want, " " $1 " ") || index(want, " " $2 " ")' |
    LC_ALL=C sort >"$out"
}

# The digest a promotion is qualified against: the Mac set in the source
# channel, one "name version filename sha256" line per package, sorted.
set_digest() {
  awk -F'\t' '{ print $1, $3, $4, $5 }' "$1" | LC_ALL=C sort >"$1.lines"
  sha256_of "$1.lines"
}

# ── pins ────────────────────────────────────────────────────────────────────
# The archive a recipe sources for COMMIT, hashed the way makepkg will:
# github.com/<repo>/archive/<sha>.tar.gz, never gh api's /tarball/<sha>, which
# is a different archive. Retries on 429, authenticated when gh has a token.
archive_sha256() {
  local url=$1 dest=$work/archive.tar.gz attempt=0 delay=2 code token=${GH_TOKEN:-}
  local headers=(-H 'Accept: application/vnd.github+json')
  [[ -n $token ]] || token=$(gh auth token 2>/dev/null || true)
  [[ -z $token ]] || headers+=(-H "Authorization: Bearer $token")
  while (( attempt < 7 )); do
    attempt=$((attempt + 1))
    # curl -L drops Authorization when github.com redirects to codeload;
    # --location-trusted keeps it, so authenticated retries survive.
    code=$(curl -sS --location-trusted -o "$dest" -w '%{http_code}' --retry 0 "${headers[@]}" "$url" || true)
    if [[ $code == 200 && -s $dest ]]; then
      tar -tzf "$dest" >/dev/null 2>&1 || die "$url is not a gzip tarball"
      sha256_of "$dest"
      return 0
    fi
    if [[ $code == 429 || $code == 000 ]]; then
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi
    die "could not download $url (HTTP $code)"
  done
  die "could not download $url after retries (HTTP 429)"
}

# Whether version B sorts after A the way pacman orders them: vercmp when it
# is installed, else sort -V, which agrees on the versions these recipes use.
version_newer() {
  [[ $1 != "$2" ]] || return 1
  if command -v vercmp >/dev/null; then
    (( $(vercmp "$2" "$1") > 0 ))
  else
    [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$2" ]]
  fi
}

replace_line() {
  local file=$1 pattern=$2 line=$3
  LINE=$line awk -v pattern="$pattern" '$0 ~ pattern { print ENVIRON["LINE"]; next } { print }' "$file" >"$file.new" &&
    cat "$file.new" >"$file" && rm -f "$file.new"
}

# Move the recipe in DIR to COMMIT: _commit, the first sha256sums entry when
# source[0] is that commit's archive (hashed here unless ARCHIVE_SHA256 is
# given), and a new package version: pkgrel + 1, or pkgrel=1 when
# VERSION_VAR is given and moves to VERSION. Refuses a version that is not
# newer. Sets pin_old_version, pin_new_version and pin_archive.
pin_recipe() {
  local dir=$1 commit=$2 archive=${3:-} version_var=${4:-} version=${5:-}
  local file=$dir/PKGBUILD pattern old_rel new_rel source0 sum0
  for pattern in '^_commit=[0-9a-f]{40}$' '^pkgrel='; do
    [[ $(grep -cE "$pattern" "$file") == 1 ]] || die "$file does not have exactly one line matching $pattern"
  done
  pin_old_version=$(pkgbuild_var "$dir" version)
  old_rel=$(pkgbuild_var "$dir" pkgrel)
  [[ $old_rel =~ ^[1-9][0-9]*$ ]] || die "pkgrel of $file is not a positive integer: $old_rel"
  new_rel=$((old_rel + 1))
  if [[ -n $version_var ]]; then
    [[ $(grep -c "^$version_var=" "$file") == 1 ]] || die "$file does not have exactly one $version_var line"
    if [[ $(pkgbuild_var "$dir" "$version_var") != "$version" ]]; then
      replace_line "$file" "^$version_var=" "$version_var=$version"
      new_rel=1
    fi
  fi
  replace_line "$file" '^_commit=' "_commit=$commit"
  replace_line "$file" '^pkgrel=' "pkgrel=$new_rel"
  source0=$(pkgbuild_first "$dir" source)
  sum0=$(pkgbuild_first "$dir" sha256sums)
  pin_archive=""
  if [[ $source0 == *"$commit"*.tar.gz && $sum0 =~ ^[0-9a-f]{64}$ ]]; then
    [[ $(grep -cE "^sha256sums=\('[0-9a-f]{64}'" "$file") == 1 ]] ||
      die "$file does not start sha256sums=('<archive sha256>' on one line"
    pin_archive=${source0##*::}
    [[ -n $archive ]] || archive=$(archive_sha256 "$pin_archive")
    [[ $archive =~ ^[0-9a-f]{64}$ ]] || die "invalid archive sha256: $archive"
    sed -E "s/^sha256sums=\('[0-9a-f]{64}'/sha256sums=('$archive'/" "$file" >"$file.new" && cat "$file.new" >"$file" && rm -f "$file.new"
    [[ $(pkgbuild_first "$dir" sha256sums) == "$archive" ]] || die "$file did not take the archive sha256"
  fi
  [[ $(pkgbuild_var "$dir" _commit) == "$commit" ]] || die "$file did not take the pin $commit"
  pin_new_version=$(pkgbuild_var "$dir" version)
  version_newer "$pin_old_version" "$pin_new_version" ||
    die "pinning $commit would move $(basename "$dir") backwards ($pin_old_version -> $pin_new_version); pacman never installs an older version over a newer one"
}

# ── pull requests ───────────────────────────────────────────────────────────
# The latest pull request from BRANCH into master: sets pr_state (OPEN,
# MERGED, CLOSED or NONE) and pr_number.
pr_lookup() {
  local out
  out=$(gh pr list -R "$omacom_repo" --head "$1" --base "$omacom_branch" --state all --json number,state \
    --jq 'sort_by(.number) | last | select(. != null) | "\(.state) \(.number)"' 2>"$work/gh.err") ||
    die "could not list the pull requests of $1: $(head -c 300 "$work/gh.err")"
  pr_state=NONE
  pr_number=""
  [[ -z $out ]] || read -r pr_state pr_number <<<"$out"
}

# Commit the working tree of $pkgs on BRANCH from master's head, push it to
# omacom and open a pull request; prints its number.
open_pr() {
  local branch=$1 title=$2 body=$3 output
  [[ -n $author_name && -n $author_email ]] ||
    die "a pull request needs MAC_RELEASE_AUTHOR_NAME and MAC_RELEASE_AUTHOR_EMAIL (settings file or environment)"
  GIT_AUTHOR_NAME=$author_name GIT_AUTHOR_EMAIL=$author_email GIT_COMMITTER_NAME=$author_name \
    GIT_COMMITTER_EMAIL=$author_email git -C "$pkgs" commit --quiet -am "$title" ||
    die "could not commit $title"
  git -C "$pkgs" push --quiet --force origin "HEAD:refs/heads/$branch" 2>"$work/git.err" ||
    die "could not push $branch: $(tail -n 3 "$work/git.err")"
  output=$(gh pr create -R "$omacom_repo" --base "$omacom_branch" --head "$branch" --title "$title" --body "$body" 2>&1) ||
    die "could not open the pull request for $branch: $output"
  grep -oE 'pull/[0-9]+' <<<"$output" | tail -n 1 | cut -d/ -f2
}

# Master's head checked out in $pkgs on BRANCH with only the directories
# DIRS in the working tree. A sparse checkout keeps every other path in the
# index, so a commit changes only what was edited.
checkout_sparse() {
  local branch=$1
  shift
  git -C "$pkgs" sparse-checkout set "$@" 2>"$work/git.err" &&
    git -C "$pkgs" checkout --quiet -B "$branch" "$pkgs_head" 2>>"$work/git.err" ||
    die "could not check out $omacom_branch: $(tail -n 3 "$work/git.err")"
}

# A short digest of words, to name a branch after the change it carries.
words_digest() {
  printf '%s\n' "$@" | LC_ALL=C sort >"$work/words"
  sha256_of "$work/words" | cut -c1-8
}
