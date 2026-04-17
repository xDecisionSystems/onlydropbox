#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

prompt() {
  local label="$1"
  local default_value="${2:-}"
  local input

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " input || true
    if [[ -z "${input:-}" ]]; then
      input="$default_value"
    fi
  else
    read -r -p "$label: " input || true
  fi

  printf '%s' "$input"
}

run_privileged() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    error "Privilege escalation required for: $* (install sudo or run as root)"
  fi
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

normalize_prefix_path() {
  local raw="${PREFIX_PATH:-/}"
  raw="$(trim "$raw")"

  if [[ -z "$raw" || "$raw" == "/" ]]; then
    PREFIX_PATH_NORMALIZED="/"
    return
  fi

  raw="${raw#/}"
  raw="${raw%/}"
  PREFIX_PATH_NORMALIZED="/$raw"
}

build_full_path() {
  local child="$1"
  if [[ "$PREFIX_PATH_NORMALIZED" == "/" ]]; then
    printf '/%s' "$child"
  else
    printf '%s/%s' "$PREFIX_PATH_NORMALIZED" "$child"
  fi
}

parse_sync_folders() {
  local raw="${SYNC_FOLDERS:-}"
  local token
  IFS=',' read -ra parts <<< "$raw"

  ALLOW=()
  for token in "${parts[@]:-}"; do
    token="$(trim "$token")"
    [[ -z "$token" ]] && continue
    token="${token#/}"
    token="${token%%/*}"
    token="${token%/}"
    [[ -z "$token" ]] && continue
    ALLOW+=("$token")
  done
}

is_allowed() {
  local candidate="$1"
  local allowed
  for allowed in "${ALLOW[@]:-}"; do
    if [[ "$candidate" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

wait_for_dropbox_ready() {
  local max_wait=300
  local elapsed=0
  local status

  log "Waiting for Dropbox daemon to initialize..."
  while (( elapsed < max_wait )); do
    if status="$("$DROPBOX_CLI" status 2>/dev/null || true)"; then
      case "$status" in
        *"Up to date"*|*"Syncing"*|*"Connecting"*|*"Downloading"*|*"Indexing"*)
          log "Dropbox is responding: $status"
          return 0
          ;;
      esac
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  log "Dropbox did not become ready in ${max_wait}s. Current status: $("$DROPBOX_CLI" status 2>/dev/null || true)"
  return 1
}

configure_selective_sync() {
  parse_sync_folders
  normalize_prefix_path

  if [[ "${#ALLOW[@]}" -eq 0 ]]; then
    log "SYNC_FOLDERS is empty. Leaving selective sync unchanged."
    return 0
  fi

  log "Prefix path: ${PREFIX_PATH_NORMALIZED}"
  log "Allow-list from SYNC_FOLDERS: ${ALLOW[*]}"

  mapfile -t remote_entries < <("$DROPBOX_CLI" ls "$PREFIX_PATH_NORMALIZED" 2>/dev/null || true)
  if [[ "${#remote_entries[@]}" -eq 0 ]]; then
    log "No remote entries found under ${PREFIX_PATH_NORMALIZED}. This can happen before account linking or initial listing."
    return 0
  fi

  local name
  local normalized
  local full_path
  local exclude_line
  local exclude_item
  local exclude_output

  for name in "${remote_entries[@]}"; do
    normalized="${name%/}"
    normalized="${normalized#/}"
    [[ -z "$normalized" ]] && continue
    full_path="$(build_full_path "$normalized")"

    if is_allowed "$normalized"; then
      log "Including ${full_path}"
      "$DROPBOX_CLI" exclude remove "${full_path}" >/dev/null 2>&1 || true
    else
      log "Excluding ${full_path}"
      "$DROPBOX_CLI" exclude add "${full_path}" >/dev/null 2>&1 || true
    fi
  done

  if exclude_output="$("$DROPBOX_CLI" exclude list 2>/dev/null || true)"; then
    while IFS= read -r exclude_line; do
      exclude_item="$(trim "$exclude_line")"
      [[ "$exclude_item" != /* ]] && continue
      exclude_item="${exclude_item%/}"

      for normalized in "${ALLOW[@]}"; do
        full_path="$(build_full_path "$normalized")"
        if [[ "$exclude_item" == "$full_path" || "$exclude_item" == "$full_path/"* ]]; then
          log "Including nested excluded path ${exclude_item}"
          "$DROPBOX_CLI" exclude remove "$exclude_item" >/dev/null 2>&1 || true
          break
        fi
      done
    done <<< "$exclude_output"
  fi

  log "Selective sync configuration finished."
}

HOME_DIR="${HOME:-/root}"
CONFIG_DIR="$HOME_DIR/.config/onlydropbox"
ENV_FILE="$CONFIG_DIR/onlydropbox.env"
DROPBOX_DIST_DIR="$HOME_DIR/.dropbox-dist"
DROPBOX_DAEMON="$DROPBOX_DIST_DIR/dropboxd"
DROPBOX_CLI="$HOME_DIR/.local/bin/dropbox"
DROPBOX_DOWNLOAD_URL="https://www.dropbox.com/download?plat=lnx.x86_64"
DROPBOX_CLI_URL="https://www.dropbox.com/download?dl=packages/dropbox.py"

if ! command -v apt-get >/dev/null 2>&1; then
  error "apt-get not found. This installer currently supports Debian/Ubuntu-based LXC containers."
fi

log "Installing required packages (curl + runtime dependencies)."
run_privileged apt-get update
run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  tar \
  python3 \
  procps

PREFIX_PATH="$(prompt "PREFIX_PATH (Dropbox base path)" "/")"
SYNC_FOLDERS="$(prompt "SYNC_FOLDERS (comma-separated first-level folders to sync; empty = unchanged)" "")"

mkdir -p "$CONFIG_DIR" "$HOME_DIR/.local/bin"

cat > "$ENV_FILE" <<EOF
# Generated by install-onlydropbox-lxc.sh on $(date '+%Y-%m-%d %H:%M:%S')
PREFIX_PATH=$PREFIX_PATH
SYNC_FOLDERS=$SYNC_FOLDERS
EOF

log "Saved config to $ENV_FILE"

ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
  error "Dropbox headless Linux binary from this script currently supports x86_64. Detected: $ARCH"
fi

if [[ ! -x "$DROPBOX_DAEMON" ]]; then
  log "Installing Dropbox headless daemon to $DROPBOX_DIST_DIR"
  TMP_TAR="$(mktemp)"
  curl -fsSL "$DROPBOX_DOWNLOAD_URL" -o "$TMP_TAR"
  tar -xzf "$TMP_TAR" -C "$HOME_DIR"
  rm -f "$TMP_TAR"
fi

if [[ ! -f "$DROPBOX_CLI" ]]; then
  log "Installing Dropbox CLI to $DROPBOX_CLI"
  curl -fsSL "$DROPBOX_CLI_URL" -o "$DROPBOX_CLI"
  chmod +x "$DROPBOX_CLI"
fi

if pgrep -f "$DROPBOX_DAEMON" >/dev/null 2>&1; then
  log "Dropbox daemon is already running."
else
  log "Starting Dropbox daemon in background."
  nohup "$DROPBOX_DAEMON" >/tmp/onlydropbox-dropboxd.log 2>&1 &
  sleep 3
fi

status_out="$("$DROPBOX_CLI" status 2>&1 || true)"
if [[ "$status_out" == *"not linked"* || "$status_out" == *"This computer isn't linked"* ]]; then
  cat <<EOF

Dropbox is not linked yet.
Run this command to get the pairing URL:
  $DROPBOX_CLI start -i

After linking completes, re-run this installer to apply selective sync using:
  PREFIX_PATH=$PREFIX_PATH
  SYNC_FOLDERS=$SYNC_FOLDERS

EOF
  exit 0
fi

if wait_for_dropbox_ready; then
  configure_selective_sync
fi

cat <<EOF

Install complete (headless Dropbox, no Docker).

Dropbox daemon binary:
  $DROPBOX_DAEMON
Dropbox CLI:
  $DROPBOX_CLI
Saved config:
  $ENV_FILE

Configured values:
  PREFIX_PATH=$PREFIX_PATH
  SYNC_FOLDERS=$SYNC_FOLDERS

Useful commands:
  $DROPBOX_CLI status
  $DROPBOX_CLI exclude list
  $DROPBOX_CLI start
  $DROPBOX_CLI stop

EOF
