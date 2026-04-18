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

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

read_config_value() {
  local key="$1"
  local file="$2"
  local line

  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)"
  printf '%s' "${line#*=}"
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

extract_link_url() {
  local input="${1:-}"
  printf '%s\n' "$input" | grep -Eo 'https://[^[:space:]]*cli_link_nonce[^[:space:]]*' | head -n 1 || true
}

is_link_required_status() {
  local status="${1:-}"
  [[ "$status" == *"not linked"* || "$status" == *"This computer isn't linked"* || "$status" == *"isn't linked to any Dropbox account"* || "$status" == *"/cli_link_nonce"* ]]
}

start_dropbox_daemon() {
  local status

  if pgrep -f "$DROPBOX_DAEMON" >/dev/null 2>&1; then
    return 0
  fi

  if [[ ! -x "$DROPBOX_DAEMON" ]]; then
    error "Dropbox daemon not found at $DROPBOX_DAEMON. Run the installer first."
  fi

  log "Starting Dropbox daemon in background."
  nohup "$DROPBOX_DAEMON" >/tmp/codedrop-dropboxd.log 2>&1 &
  sleep 3

  if pgrep -f "$DROPBOX_DAEMON" >/dev/null 2>&1; then
    return 0
  fi

  status="$("$DROPBOX_CLI" status 2>&1 || true)"
  if [[ "$status" == *"Starting..."* || "$status" == *"Up to date"* || "$status" == *"Syncing"* || "$status" == *"Connecting"* || "$status" == *"Downloading"* || "$status" == *"Indexing"* ]] || is_link_required_status "$status"; then
    return 0
  fi

  error "Dropbox daemon did not start. Check /tmp/codedrop-dropboxd.log"
}

wait_for_dropbox_ready() {
  local max_wait=120
  local elapsed=0
  local status

  while (( elapsed < max_wait )); do
    status="$("$DROPBOX_CLI" status 2>/dev/null || true)"

    case "$status" in
      *"Up to date"*|*"Syncing"*|*"Connecting"*|*"Downloading"*|*"Indexing"*)
        return 0
        ;;
    esac

    if is_link_required_status "$status"; then
      return 10
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

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
    log "No remote entries found under ${PREFIX_PATH_NORMALIZED}."
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

if [[ "${EUID}" -eq 0 ]]; then
  error "Run this script as your Dropbox user, not root."
fi

HOME_DIR="${HOME:-/root}"
CONFIG_DIR="$HOME_DIR/.config/codedrop"
ENV_FILE="$CONFIG_DIR/codedrop.env"
DROPBOX_DIST_DIR="$HOME_DIR/.dropbox-dist"
DROPBOX_DAEMON="$DROPBOX_DIST_DIR/dropboxd"
DROPBOX_CLI="$HOME_DIR/.local/bin/dropbox"

if [[ ! -x "$DROPBOX_CLI" ]]; then
  error "Dropbox CLI not found at $DROPBOX_CLI. Run the installer first."
fi

existing_prefix="/"
existing_sync=""
if [[ -f "$ENV_FILE" ]]; then
  existing_prefix="$(read_config_value "PREFIX_PATH" "$ENV_FILE")"
  existing_sync="$(read_config_value "SYNC_FOLDERS" "$ENV_FILE")"
fi

PREFIX_PATH="$(prompt "PREFIX_PATH (Dropbox base path)" "${existing_prefix:-/}")"
SYNC_FOLDERS="$(prompt "SYNC_FOLDERS (comma-separated first-level folders to sync; empty = unchanged)" "${existing_sync:-}")"

PREFIX_PATH="$(trim "$PREFIX_PATH")"
SYNC_FOLDERS="$(trim "$SYNC_FOLDERS")"
[[ -z "$PREFIX_PATH" ]] && PREFIX_PATH="/"

mkdir -p "$CONFIG_DIR"
cat > "$ENV_FILE" <<CONFIG
# Updated by update-codedrop-sync-lxc.sh on $(date '+%Y-%m-%d %H:%M:%S')
PREFIX_PATH=$PREFIX_PATH
SYNC_FOLDERS=$SYNC_FOLDERS
CONFIG

log "Saved config to $ENV_FILE"

start_dropbox_daemon

status_out="$("$DROPBOX_CLI" status 2>&1 || true)"
if is_link_required_status "$status_out"; then
  link_url="$(extract_link_url "$status_out")"
  if [[ -n "$link_url" ]]; then
    printf '\nDropbox is not linked. Open this URL:\n  %s\n\n' "$link_url"
  else
    printf '\nDropbox is not linked. Run:\n  %s start -i\n\n' "$DROPBOX_CLI"
  fi
  exit 0
fi

wait_rc=0
if wait_for_dropbox_ready; then
  configure_selective_sync
  printf '\nUpdated selective sync with:\n  PREFIX_PATH=%s\n  SYNC_FOLDERS=%s\n\n' "$PREFIX_PATH" "$SYNC_FOLDERS"
  exit 0
else
  wait_rc=$?
fi

if [[ "$wait_rc" -eq 10 ]]; then
  printf '\nDropbox needs account linking before selective sync can be applied.\nRun:\n  %s start -i\n\n' "$DROPBOX_CLI"
  exit 0
fi

error "Dropbox did not become ready. Check /tmp/codedrop-dropboxd.log and '$DROPBOX_CLI status'."
