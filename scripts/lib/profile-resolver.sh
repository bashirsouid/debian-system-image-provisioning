#!/usr/bin/env bash
#
# Profile + role resolver.
#
# Layout:
#   mkosi.profiles/<name>/{mkosi.conf,profile.manifest,mkosi.extra/...}
#       Atomic profiles. mkosi scans mkosi.profiles/<name>/ natively
#       whenever <name> appears in --profile=<name>.
#
#   mkosi.roles/<name>.role
#       Plain text list of atomic profile names (comments with #,
#       whitespace-insensitive). Roles are expanded by this resolver
#       BEFORE mkosi is invoked — mkosi never sees a role name.
#       Roles cannot reference other roles (one level only, to keep
#       expansion deterministic and the mental model simple).
#
# Every host-facing entry point that accepts a profile list should run
# it through ab_resolve_profiles() first. Do NOT re-implement role
# handling elsewhere — keeping it in one place means adding a new role
# or changing the role syntax only needs one edit.

# shellcheck disable=SC2034
# Callers set AB_PROFILES_ROOT / AB_ROLES_ROOT via export before
# sourcing this file if their layout differs from the defaults below.

ab_profiles_root() {
  printf '%s' "${AB_PROFILES_ROOT:-$AB_PROJECT_ROOT/mkosi.profiles}"
}

ab_roles_root() {
  printf '%s' "${AB_ROLES_ROOT:-$AB_PROJECT_ROOT/mkosi.roles}"
}

# Token format we accept in profile.default, --profile, and role files.
# Matches both profile names and role names; letters, digits, dot,
# underscore, hyphen. Explicitly rejects shell metacharacters to
# close a token-injection risk when the value gets passed to
# `$PROFILE` / `--profile=$p` downstream.
ab_profile_token_regex='^[A-Za-z0-9._-]+$'

ab_profile_fail() {
  printf '[profile-resolver] ERROR: %s\n' "$*" >&2
  return 1
}

# Read a role file and echo its atomic-profile members, one per line.
# Strips comments and whitespace. Does NOT recurse — role-of-roles is
# rejected by ab_resolve_profiles() itself.
_ab_read_role_members() {
  local role_file="$1"
  sed -e 's/#.*//' "$role_file" | tr -s '[:space:]' '\n' | awk 'NF'
}

# Expand a space-separated raw token list (from profile.default or
# --profile) into a deduped, validated, ordered list of atomic profile
# names. Order is first-occurrence wins.
#
# Exits non-zero and writes the error to stderr on:
#   * invalid token characters
#   * unknown profile/role name
#   * a role file referencing another role (nesting is disallowed)
#   * a role file referencing an unknown profile
# Add one atomic profile to the in-progress resolution, FIRST pulling in any
# profiles it declares via `requires=` in its profile.manifest (so a dependency
# always lands before the profile that needs it). This is what lets a host
# select `kopia-filesystem-backup` alone and get `kopia-base` automatically —
# no need to remember the shared base. Recurses for transitive requires; a
# requires cycle is reported rather than looping forever.
#
# Operates on the module-level _ab_resolved / _ab_seen / _ab_inprogress strings
# that ab_resolve_profiles resets at the start of each call (globals, not
# locals, so this recursive helper can see them — bash 3.2 has no namerefs).
_ab_emit_profile() {
  local p="$1" profiles_root="$2"

  # Already emitted -> nothing to do.
  case "$_ab_seen" in *" $p "*) return 0 ;; esac

  if [[ ! -d "$profiles_root/$p" ]]; then
    ab_profile_fail "unknown profile '$p' (no $profiles_root/$p/)" || return 1
  fi

  # Cycle guard: p is already being expanded higher up the recursion.
  case "$_ab_inprogress" in
    *" $p "*) ab_profile_fail "requires cycle detected at profile '$p'" || return 1 ;;
  esac
  _ab_inprogress+="$p "

  # Emit declared dependencies first. requires= is a space-separated list of
  # atomic profile names, parsed safely (never sourced) via the manifest reader.
  local reqs req _rsplit
  reqs="$(ab_profile_manifest_value "$p" requires)"
  if [[ -n "$reqs" ]]; then
    _rsplit="$(printf '%s' "$reqs" | tr -s '[:space:]' '\n')"
    while IFS= read -r req; do
      [[ -n "$req" ]] || continue
      if [[ ! "$req" =~ $ab_profile_token_regex ]]; then
        ab_profile_fail "profile '$p' lists invalid requires token: '$req'" || return 1
      fi
      if [[ -f "$(ab_roles_root)/$req.role" ]]; then
        ab_profile_fail "profile '$p' requires '$req', which is a role; requires= may only name atomic profiles" || return 1
      fi
      if [[ ! -d "$profiles_root/$req" ]]; then
        ab_profile_fail "profile '$p' requires unknown profile '$req' (no $profiles_root/$req/)" || return 1
      fi
      _ab_emit_profile "$req" "$profiles_root" || return 1
    done <<< "$_rsplit"
  fi

  _ab_inprogress="${_ab_inprogress/ $p / }"

  # A transitive require may already have emitted p; re-check before adding.
  case "$_ab_seen" in
    *" $p "*) : ;;
    *)
      _ab_seen+="$p "
      _ab_resolved+="${_ab_resolved:+ }$p"
      ;;
  esac
}

ab_resolve_profiles() {
  local raw="${1:-}"
  local profiles_root roles_root
  profiles_root="$(ab_profiles_root)"
  roles_root="$(ab_roles_root)"

  # Module-level accumulators (see _ab_emit_profile), reset per call.
  # Deliberately plain space-padded strings rather than `declare -A`, because
  # this library also gets sourced by tooling that runs on macOS's bash 3.2
  # (no associative arrays). The dataset is tiny (max ~25 entries).
  _ab_resolved=""
  _ab_seen=" "
  _ab_inprogress=" "
  local tok member role_file

  # Tokenize via a read loop instead of `for tok in $raw` so this
  # function works correctly when sourced from either bash or zsh —
  # zsh does not word-split unquoted parameter expansions by default,
  # which would otherwise hand the whole space-separated list back as
  # a single token.
  local _split
  _split="$(printf '%s' "$raw" | tr -s '[:space:]' '\n')"
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    if [[ ! "$tok" =~ $ab_profile_token_regex ]]; then
      ab_profile_fail "invalid profile/role token: '$tok' (allowed: A-Z a-z 0-9 . _ -)" || return 1
    fi

    # Role expansion takes precedence over a same-named profile: if a
    # user names both mkosi.roles/foo.role and mkosi.profiles/foo/ then
    # the role wins (a same-named atomic profile is almost certainly a
    # mistake, and erring on the side of "role expansion applied" is
    # the less surprising of the two behaviors).
    role_file="$roles_root/$tok.role"
    if [[ -f "$role_file" ]]; then
      while IFS= read -r member; do
        [[ -n "$member" ]] || continue
        if [[ ! "$member" =~ $ab_profile_token_regex ]]; then
          ab_profile_fail "role '$tok' lists invalid member token: '$member'" || return 1
        fi
        if [[ -f "$roles_root/$member.role" ]]; then
          ab_profile_fail "role '$tok' references role '$member'; roles cannot reference other roles (one level only)" || return 1
        fi
        if [[ ! -d "$profiles_root/$member" ]]; then
          ab_profile_fail "role '$tok' references unknown profile '$member' (no $profiles_root/$member/)" || return 1
        fi
        # Route through _ab_emit_profile so role members also pull in their
        # own requires= dependencies.
        _ab_emit_profile "$member" "$profiles_root" || return 1
      done < <(_ab_read_role_members "$role_file")
      continue
    fi

    if [[ -d "$profiles_root/$tok" ]]; then
      _ab_emit_profile "$tok" "$profiles_root" || return 1
      continue
    fi

    ab_profile_fail "unknown profile or role: '$tok' (no $profiles_root/$tok/ or $roles_root/$tok.role)" || return 1
  done <<< "$_split"

  printf '%s' "$_ab_resolved"
}

# Return the value for a single key in a profile's manifest, or empty.
# Manifest is shell-sourceable key=value; we use a safe awk parse
# rather than sourcing directly so a malformed manifest can't poison
# the caller's shell environment or execute code at build time.
ab_profile_manifest_value() {
  local profile="$1"
  local key="$2"
  local profiles_root manifest
  profiles_root="$(ab_profiles_root)"
  manifest="$profiles_root/$profile/profile.manifest"
  [[ -f "$manifest" ]] || { printf ''; return 0; }

  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    {
      # match lines like "key=..." with optional leading whitespace.
      if (match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/)) {
        name = substr($0, RSTART, RLENGTH)
        sub(/[[:space:]]*=[[:space:]]*$/, "", name)
        sub(/^[[:space:]]+/, "", name)
        if (name == k) {
          val = substr($0, RSTART + RLENGTH)
          # Strip matching outer quotes.
          if (match(val, /^".*"$/) || match(val, /^'\''.*'\''$/)) {
            val = substr(val, 2, length(val) - 2)
          }
          print val
          exit
        }
      }
    }
  ' "$manifest"
}

# Given an expanded profile list, print the space-separated set of
# secret names (union of each profile's uses_secrets, deduped).
ab_collect_required_secrets() {
  local profile_list="$1"
  local seen=" "
  local out=""
  local p s raw
  # Same zsh/bash portability concern as ab_resolve_profiles: split
  # via tr+read instead of relying on `for x in $var` word-splitting.
  local _ps_split _us_split
  _ps_split="$(printf '%s' "$profile_list" | tr -s '[:space:]' '\n')"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    raw="$(ab_profile_manifest_value "$p" uses_secrets)"
    _us_split="$(printf '%s' "$raw" | tr -s '[:space:]' '\n')"
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      case "$seen" in
        *" $s "*) : ;;
        *)
          seen+="$s "
          out+="${out:+ }$s"
          ;;
      esac
    done <<< "$_us_split"
  done <<< "$_ps_split"
  printf '%s' "$out"
}
