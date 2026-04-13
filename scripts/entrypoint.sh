#!/usr/bin/env bash
set -euo pipefail

DROPBOX_CLI="/usr/local/bin/dropbox"
DROPBOX_DAEMON="/root/.dropbox-dist/dropboxd"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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
    ALLOW+=("$token")
  done
}

wait_for_dropbox_ready() {
  local max_wait=300
  local elapsed=0

  log "Waiting for Dropbox daemon to initialize..."
  while (( elapsed < max_wait )); do
    if status="$($DROPBOX_CLI status 2>/dev/null || true)"; then
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

  log "Dropbox did not become ready in ${max_wait}s. Current status: $($DROPBOX_CLI status 2>/dev/null || true)"
  return 1
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

configure_selective_sync() {
  parse_sync_folders
  normalize_prefix_path

  if [[ "${#ALLOW[@]}" -eq 0 ]]; then
    log "SYNC_FOLDERS is empty. Leaving selective sync unchanged."
    return 0
  fi

  log "Prefix path: ${PREFIX_PATH_NORMALIZED}"
  log "Allow-list from SYNC_FOLDERS: ${ALLOW[*]}"

  # Build a top-level directory list from the configured prefix path.
  mapfile -t remote_entries < <($DROPBOX_CLI ls "$PREFIX_PATH_NORMALIZED" 2>/dev/null || true)

  if [[ "${#remote_entries[@]}" -eq 0 ]]; then
    log "No remote entries found under ${PREFIX_PATH_NORMALIZED}. This can happen before account linking or initial listing."
    return 0
  fi

  local name
  local normalized
  local full_path

  for name in "${remote_entries[@]}"; do
    normalized="${name%/}"
    normalized="${normalized#/}"
    [[ -z "$normalized" ]] && continue
    full_path="$(build_full_path "$normalized")"

    if is_allowed "$normalized"; then
      log "Including ${full_path}"
      $DROPBOX_CLI exclude remove "${full_path}" >/dev/null 2>&1 || true
    else
      log "Excluding ${full_path}"
      $DROPBOX_CLI exclude add "${full_path}" >/dev/null 2>&1 || true
    fi
  done

  log "Selective sync configuration finished."
}

show_link_hint_if_needed() {
  local out
  out="$($DROPBOX_CLI status 2>&1 || true)"
  if [[ "$out" == *"not linked"* || "$out" == *"This computer isn't linked"* ]]; then
    log "Dropbox account is not linked yet. Run 'docker logs <container>' and open the link URL shown by Dropbox."
  fi
}

log "Starting Dropbox daemon..."
"$DROPBOX_DAEMON" &
DAEMON_PID=$!

sleep 3
show_link_hint_if_needed

if wait_for_dropbox_ready; then
  configure_selective_sync
fi

log "Dropbox container is running. Daemon PID: ${DAEMON_PID}"
wait "$DAEMON_PID"
