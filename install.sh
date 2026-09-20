#!/usr/bin/env bash
#
# install.sh - install or repair deployment-scripts on a Pacefactory server.
#
#   curl -fsSL https://get.pacefactory.dev/install.sh | bash
#
# Idempotent: run it on a fresh server, on a server that still holds the old
# git checkout (converted in place), or on a broken install to repair it.
# It never prompts (stdin is this script when piped) and takes no positional
# arguments; configuration is by environment variables only:
#
#   PF_INSTALL_DIR   install root            default $HOME/scv2/git_clones/deployment-scripts
#   PF_IMAGE         release image           default pacefactory/deployment-scripts
#   PF_RELEASE       tag to install          default latest (a vX.Y.Z tag pins or rolls back)
#   PF_REMOVE_GIT    true removes a converted checkout's .git directory; default false
#   PF_OAT_FILE      Docker Hub token file   default $HOME/scv2/docker_oat.sh
#   PF_DOCKER_USER   user for a token login  default pacefactory
#   PF_DOCKER_AUTH   credentials to use      default auto (auto|oat|existing, see below)
#   DOCKER_OAT       honoured if already exported (never pass it as an argument)
#
# Flags (for testing; not needed on servers):
#   --dry-run        print the resolved configuration and the steps; run nothing
#   --help           this text
#
# What it does:
#   1. preflight: docker on PATH, `docker info` works for this user without
#      sudo, `docker compose version` works
#   2. Docker Hub authentication: this server's Organization Access Token, or
#      a developer's own Docker Hub login (see below); never `docker logout`
#   3. docker pull $PF_IMAGE:$PF_RELEASE
#   4. docker create + docker cp into a temporary directory, docker rm
#   5. hand off to the updater shipped in the image:
#        scripts/release/fetch-release.sh --from <tmp>
#      which syncs the tree into PF_INSTALL_DIR by manifest (site files such
#      as .env, .settings, docker-compose.yml, credentials, custom compose
#      fragments are never touched) and prints the next steps
#      (./build.sh, ./update.sh). This script runs neither.
#
# Docker Hub authentication. Two supported routes:
#   Server (production convention, Pacefactory Deployment Guide): the server has
#   its own non-expiring Docker Organization Access Token with image-pull scope,
#   stored as `export DOCKER_OAT=dckr_oat_...` in ~/scv2/docker_oat.sh (mode 700).
#   Developer machine: a personal Docker Hub account that is a member of the
#   Pacefactory organization with pull access, logged in with `docker login`.
# Order of precedence (PF_DOCKER_AUTH=auto, the default):
#   PF_OAT_FILE exists  -> source it in a subshell, docker login --password-stdin
#   DOCKER_OAT exported -> docker login --password-stdin
#   already logged in as $PF_DOCKER_USER -> proceed
#   logged in as legacy pfclient         -> warn, proceed if the pull succeeds
#   logged in as any other user          -> proceed on that account's access
#   not logged in at all                 -> fail with remediation
# PF_DOCKER_AUTH=oat rejects a login that is not $PF_DOCKER_USER (the strict
# server posture); PF_DOCKER_AUTH=existing uses the login the daemon already
# holds and ignores PF_OAT_FILE and DOCKER_OAT.
# The token is never echoed, never written, never passed on a command line.
#
# Network: only Docker Hub, through the docker CLI. No curl inside. Nothing is
# written outside the temporary directory and PF_INSTALL_DIR.
#
# Everything is in functions and main runs from the very last line, so a
# truncated download executes nothing.
set -euo pipefail

PF_INSTALL_DIR="${PF_INSTALL_DIR:-$HOME/scv2/git_clones/deployment-scripts}"
PF_IMAGE="${PF_IMAGE:-pacefactory/deployment-scripts}"
PF_RELEASE="${PF_RELEASE:-latest}"
PF_REMOVE_GIT="${PF_REMOVE_GIT:-false}"
PF_OAT_FILE="${PF_OAT_FILE:-$HOME/scv2/docker_oat.sh}"
PF_DOCKER_USER="${PF_DOCKER_USER:-pacefactory}"
PF_DOCKER_AUTH="${PF_DOCKER_AUTH:-auto}"

DRY_RUN=false
TMP_DIR=""
CONTAINER_ID=""

# ---- output helpers --------------------------------------------------------

log()  { printf '[pacefactory install] %s\n' "$*"; }
warn() { printf '[pacefactory install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[pacefactory install] ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" 2>/dev/null | sed '$d' | sed 's/^# \{0,1\}//'; }

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
    CONTAINER_ID=""
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
    TMP_DIR=""
  fi
}

# ---- arguments and configuration -------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument '$1'. This script takes no positional arguments; configure it with environment variables (see --help)." ;;
    esac
    shift
  done
}

validate_config() {
  [[ "$PF_INSTALL_DIR" == /* ]] || die "PF_INSTALL_DIR must be an absolute path (got '$PF_INSTALL_DIR')"
  [[ "$PF_IMAGE" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || die "PF_IMAGE '$PF_IMAGE' is not a valid image repository name"
  [[ "$PF_RELEASE" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "PF_RELEASE '$PF_RELEASE' is not a valid image tag"
  case "$PF_REMOVE_GIT" in true|false) ;; *) die "PF_REMOVE_GIT must be 'true' or 'false' (got '$PF_REMOVE_GIT')" ;; esac
  [[ "$PF_OAT_FILE" == /* ]] || die "PF_OAT_FILE must be an absolute path (got '$PF_OAT_FILE')"
  [[ "$PF_DOCKER_USER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "PF_DOCKER_USER '$PF_DOCKER_USER' is not a valid Docker Hub user name"
  case "$PF_DOCKER_AUTH" in auto|oat|existing) ;; *) die "PF_DOCKER_AUTH must be 'auto', 'oat' or 'existing' (got '$PF_DOCKER_AUTH')" ;; esac
}

print_config() {
  local oat_state="unset"
  [[ -n "${DOCKER_OAT:-}" ]] && oat_state="set (not shown)"
  log "image        : $PF_IMAGE:$PF_RELEASE"
  log "install dir  : $PF_INSTALL_DIR"
  log "token file   : $PF_OAT_FILE ($([[ -f "$PF_OAT_FILE" ]] && echo present || echo absent))"
  log "DOCKER_OAT   : $oat_state"
  log "auth mode    : $PF_DOCKER_AUTH (token login user '$PF_DOCKER_USER')"
  log "remove .git  : $PF_REMOVE_GIT"
}

# ---- 1. preflight ----------------------------------------------------------

preflight() {
  if ! command -v docker >/dev/null 2>&1; then
    die "docker is not on PATH. Install Docker Engine with the compose plugin (https://docs.docker.com/engine/install/), then re-run."
  fi
  if ! docker info >/dev/null 2>&1; then
    cat >&2 <<EOF
[pacefactory install] ERROR: 'docker info' failed for user '$(id -un)'. This script does not use sudo.
  If the daemon is running, add this user to the docker group and log in again:
    sudo usermod -aG docker $(id -un)     # then log out and back in (or run: newgrp docker)
  If the daemon is not running:
    sudo systemctl enable --now docker
EOF
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    die "'docker compose' is not available. Install the Docker Compose plugin (https://docs.docker.com/compose/install/linux/), then re-run."
  fi
  log "preflight ok: $(docker --version | tr -d ',' | cut -d' ' -f1-3), $(docker compose version --short 2>/dev/null | sed 's/^/compose /')"
}

# ---- 2. authentication -----------------------------------------------------

# Both routes, minus the one the auth mode has ruled out.
remediation() {
  {
    echo
    echo "Docker Hub credentials with pull access to the Pacefactory repositories are"
    echo "required and none were found."
    echo "Remediation:"
    if [[ "$PF_DOCKER_AUTH" != "existing" ]]; then
      echo "  Server - per-server Organization Access Token:"
      echo "    1. Obtain an Organization Access Token (image-pull scope) for this server,"
      echo "       following the Pacefactory Deployment Guide."
      echo "    2. Store it as $PF_OAT_FILE (mode 700) containing one line:"
      echo "         export DOCKER_OAT=dckr_oat_..."
    fi
    if [[ "$PF_DOCKER_AUTH" != "oat" ]]; then
      echo "  Developer machine - your own Docker Hub account:"
      echo "    1. Have your account added to the Pacefactory organization with pull"
      echo "       access on the repositories you need."
      echo "    2. Log in with it:  docker login"
      echo "       Where a token file is also present and you want your own account"
      echo "       used instead, set PF_DOCKER_AUTH=existing."
    fi
    echo "  Then re-run:  curl -fsSL https://get.pacefactory.dev/install.sh | bash"
  } >&2
}

# The user Docker Hub reports this machine as logged in as, '' if none.
#
# A --format template that names a field the struct does not have fails the
# whole command, so a non-zero exit means "wrong field name for this CLI", not
# "logged out". Docker CLI 29 renamed the field from .Username to .UserName;
# older CLIs have only .Username. Asking a 29 CLI for .Username therefore
# reports every machine as logged out, whatever `docker info` prints.
# Both are tried, then the line the human-readable output carries, which is
# what an operator sees when they check by hand.
docker_username() {
  local u t
  for t in '{{.UserName}}' '{{.Username}}'; do
    if u="$(docker info --format "$t" 2>/dev/null)" && [[ -n "$u" ]]; then
      printf '%s\n' "$u"
      return 0
    fi
  done
  docker info 2>/dev/null | sed -n 's/^[[:space:]]*Username:[[:space:]]*//p' | head -1
  return 0
}

# Login with the token exported in the environment; stdout ("Login Succeeded")
# is dropped, stderr is kept for the real error.
login_with_env_token() {
  printf '%s' "$DOCKER_OAT" | docker login -u "$PF_DOCKER_USER" --password-stdin >/dev/null
}

# Source the token file in a subshell: the token never enters this shell,
# tracing is forced off, and the file cannot change our options or cwd.
login_with_token_file() {
  local file="$1"
  [[ -r "$file" ]] || { warn "cannot read $file"; return 1; }
  (
    set +x
    set +e
    # shellcheck disable=SC1090
    . "$file" >/dev/null 2>&1
    set -e
    if [[ -z "${DOCKER_OAT:-}" ]]; then
      echo "[pacefactory install] ERROR: $file does not export DOCKER_OAT" >&2
      exit 1
    fi
    printf '%s' "$DOCKER_OAT" | docker login -u "$PF_DOCKER_USER" --password-stdin >/dev/null
  )
}

authenticate() {
  local user
  if [[ "$PF_DOCKER_AUTH" != "existing" ]]; then
    if [[ -f "$PF_OAT_FILE" ]]; then
      log "logging in to Docker Hub as '$PF_DOCKER_USER' with $PF_OAT_FILE"
      if login_with_token_file "$PF_OAT_FILE"; then
        return 0
      fi
      warn "docker login with $PF_OAT_FILE failed: the token may have been revoked or lack image-pull scope."
      remediation
      exit 1
    fi
    if [[ -n "${DOCKER_OAT:-}" ]]; then
      log "logging in to Docker Hub as '$PF_DOCKER_USER' with DOCKER_OAT from the environment"
      if login_with_env_token; then
        return 0
      fi
      warn "docker login with DOCKER_OAT failed: the token may have been revoked or lack image-pull scope."
      remediation
      exit 1
    fi
  fi
  user="$(docker_username)"
  case "$user" in
    "$PF_DOCKER_USER")
      log "already logged in to Docker Hub as '$user'"
      ;;
    pfclient)
      warn "this machine is logged in to Docker Hub as the legacy user 'pfclient' (device-code login)."
      warn "servers move to a per-server Organization Access Token in $PF_OAT_FILE (Pacefactory Deployment Guide). Continuing."
      ;;
    "")
      if [[ "$PF_DOCKER_AUTH" == "existing" ]]; then
        warn "not logged in to Docker Hub (PF_DOCKER_AUTH=existing ignores $PF_OAT_FILE and DOCKER_OAT)"
      else
        warn "not logged in to Docker Hub and no token file at $PF_OAT_FILE"
      fi
      remediation
      exit 1
      ;;
    *)
      if [[ "$PF_DOCKER_AUTH" == "oat" ]]; then
        warn "logged in to Docker Hub as '$user', not '$PF_DOCKER_USER', and no token file at $PF_OAT_FILE (PF_DOCKER_AUTH=oat)"
        remediation
        exit 1
      fi
      log "using the existing Docker Hub login '$user' (a personal account; it needs pull"
      log "  access to the Pacefactory repositories)"
      ;;
  esac
}

# ---- 3. pull ---------------------------------------------------------------

pull_release() {
  local ref="$PF_IMAGE:$PF_RELEASE"
  log "pulling $ref"
  if ! docker pull "$ref"; then
    cat >&2 <<EOF
[pacefactory install] ERROR: could not pull $ref.
  The credentials in use may lack image-pull scope on $PF_IMAGE, or the release
  tag '$PF_RELEASE' may not exist.
  On a server: the Organization Access Token in $PF_OAT_FILE may have been
  revoked (Pacefactory Deployment Guide).
  On a developer machine: the account logged in may not be a member of the
  Pacefactory organization, or may not have pull access on $PF_IMAGE.
  Fix the credentials or the tag, then re-run:
    curl -fsSL https://get.pacefactory.dev/install.sh | bash
EOF
    exit 1
  fi
}

# ---- 4. extract ------------------------------------------------------------

extract_release() {
  local ref="$PF_IMAGE:$PF_RELEASE"
  TMP_DIR="$(mktemp -d)"
  # The image is FROM scratch and has no command; docker create needs one but
  # never runs it.
  CONTAINER_ID="$(docker create "$ref" /pf-release)" || die "docker create $ref failed"
  docker cp "$CONTAINER_ID:/." "$TMP_DIR/" || die "docker cp from $ref failed"
  docker rm -f "$CONTAINER_ID" >/dev/null
  CONTAINER_ID=""
  [[ -f "$TMP_DIR/.pf-release/MANIFEST" ]] || die "$ref is not a deployment-scripts release image (no .pf-release/MANIFEST)"
  [[ -f "$TMP_DIR/scripts/release/fetch-release.sh" ]] || die "$ref does not contain scripts/release/fetch-release.sh; cannot hand off"
  log "extracted release $(sed -n 's/^TAG=//p' "$TMP_DIR/.pf-release/VERSION" | head -1) ($(wc -l < "$TMP_DIR/.pf-release/MANIFEST") files)"
}

# ---- 5. hand off -----------------------------------------------------------

hand_off() {
  mkdir -p "$PF_INSTALL_DIR"
  export PF_INSTALL_DIR PF_IMAGE PF_RELEASE PF_REMOVE_GIT PF_OAT_FILE PF_DOCKER_USER PF_DOCKER_AUTH
  log "handing off to scripts/release/fetch-release.sh --from $TMP_DIR"
  # Not exec'd on purpose: the EXIT trap must still remove the temp dir. stdin
  # is /dev/null so the updater can never read from the pipe this script came in on.
  local rc=0
  bash "$TMP_DIR/scripts/release/fetch-release.sh" --from "$TMP_DIR" </dev/null || rc=$?
  return "$rc"
}

# ---- entry point -----------------------------------------------------------

main() {
  parse_args "$@"
  validate_config
  print_config
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry run: would run preflight (docker info, docker compose version),"
    log "  authenticate (PF_DOCKER_AUTH=$PF_DOCKER_AUTH: token file / DOCKER_OAT / existing login),"
    log "  docker pull $PF_IMAGE:$PF_RELEASE,"
    log "  docker create + docker cp + docker rm, then fetch-release.sh --from <tmp> into $PF_INSTALL_DIR."
    log "dry run: nothing executed."
    return 0
  fi
  trap cleanup EXIT INT TERM
  preflight
  authenticate
  pull_release
  extract_release
  hand_off
}

main "$@"
