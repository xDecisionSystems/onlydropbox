#!/usr/bin/env bash
set -euo pipefail

DROPBOX_USER="${DROPBOX_USER:-dropbox}"
DROPBOX_HOME="$(getent passwd "$DROPBOX_USER" | cut -d: -f6)"
DROPBOX_CLI="${DROPBOX_HOME}/.local/bin/dropbox"
DROPBOX_DAEMON="${DROPBOX_HOME}/.dropbox-dist/dropboxd"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

run_as_dropbox_shell() {
  local cmd="$1"
  su - "$DROPBOX_USER" -c "$cmd"
}

run_dropbox_cli() {
  local escaped
  printf -v escaped '%q ' "$DROPBOX_CLI" "$@"
  escaped="${escaped% }"
  run_as_dropbox_shell "$escaped"
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
    token="${token%/}"
    while [[ "$token" == *"//"* ]]; do
      token="${token//\/\//\/}"
    done
    [[ -z "$token" ]] && continue
    ALLOW+=("$token")
  done
}

wait_for_dropbox_ready() {
  local max_wait=300
  local elapsed=0
  local status

  log "Waiting for Dropbox daemon to initialize..."
  while (( elapsed < max_wait )); do
    if status="$(run_dropbox_cli status 2>/dev/null || true)"; then
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

  log "Dropbox did not become ready in ${max_wait}s. Current status: $(run_dropbox_cli status 2>/dev/null || true)"
  return 1
}

is_allowed() {
  local candidate="$1"
  local allowed
  for allowed in "${ALLOW[@]:-}"; do
    if [[ "$candidate" == "$allowed" || "$allowed" == "$candidate/"* || "$candidate" == "$allowed/"* ]]; then
      return 0
    fi
  done
  return 1
}

is_ancestor_of_allowed() {
  local candidate="$1"
  local allowed
  for allowed in "${ALLOW[@]:-}"; do
    if [[ "$allowed" == "$candidate/"* ]]; then
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

  local -a queue=("")
  local current_rel
  local current_full
  local current_trimmed
  local -a remote_entries
  local name
  local normalized
  local rel_path
  local full_path
  local exclude_line
  local exclude_item

  while [[ "${#queue[@]}" -gt 0 ]]; do
    current_rel="${queue[0]}"
    queue=("${queue[@]:1}")

    if [[ -z "$current_rel" ]]; then
      current_full="$PREFIX_PATH_NORMALIZED"
    else
      current_full="$(build_full_path "$current_rel")"
    fi
    current_trimmed="${current_full#/}"

    mapfile -t remote_entries < <(run_dropbox_cli ls "$current_full" 2>/dev/null || true)
    [[ "${#remote_entries[@]}" -eq 0 ]] && continue

    for name in "${remote_entries[@]}"; do
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        normalized="${name%/}"
        normalized="${normalized#/}"
        normalized="$(trim "$normalized")"
        [[ -z "$normalized" ]] && continue
        if [[ "$normalized" == *" (File doesn't exist!)" ]]; then
          continue
        fi
        if [[ "$normalized" == *" (The 'path' argument does not exist)"* ]]; then
          continue
        fi

        if [[ -n "$current_trimmed" && "$current_trimmed" != "/" ]]; then
          if [[ "$normalized" == "$current_trimmed/"* ]]; then
            normalized="${normalized#"$current_trimmed"/}"
          elif [[ "$normalized" == "$current_trimmed" ]]; then
            normalized=""
          fi
        fi
        [[ -z "$normalized" ]] && continue

        if [[ -z "$current_rel" ]]; then
          rel_path="$normalized"
        else
          rel_path="$current_rel/$normalized"
        fi
        rel_path="${rel_path#/}"
        rel_path="${rel_path%/}"
        while [[ "$rel_path" == *"//"* ]]; do
          rel_path="${rel_path//\/\//\/}"
        done
        [[ -z "$rel_path" ]] && continue

        full_path="$(build_full_path "$rel_path")"
        if is_allowed "$rel_path"; then
          log "Including ${full_path}"
          run_dropbox_cli exclude remove "${full_path}" >/dev/null 2>&1 || true
        else
          log "Excluding ${full_path}"
          run_dropbox_cli exclude add "${full_path}" >/dev/null 2>&1 || true
        fi

        if is_ancestor_of_allowed "$rel_path"; then
          queue+=("$rel_path")
        fi
      done < <(printf '%s\n' "$name" | awk 'BEGIN{FS="  +"} {for(i=1;i<=NF;i++) if(length($i)) print $i}')
    done
  done

  # If child paths were excluded earlier, clear them for allowed first-level folders
  # so each allowed folder/path syncs recursively.
  if exclude_output="$(run_dropbox_cli exclude list 2>/dev/null || true)"; then
    while IFS= read -r exclude_line; do
      exclude_item="$(trim "$exclude_line")"
      [[ "$exclude_item" != /* ]] && continue
      exclude_item="${exclude_item%/}"

      for normalized in "${ALLOW[@]}"; do
        full_path="$(build_full_path "$normalized")"
        if [[ "$exclude_item" == "$full_path" || "$exclude_item" == "$full_path/"* ]]; then
          log "Including nested excluded path ${exclude_item}"
          run_dropbox_cli exclude remove "$exclude_item" >/dev/null 2>&1 || true
          break
        fi
      done
    done <<< "$exclude_output"
  fi

  log "Selective sync configuration finished."
}

show_link_hint_if_needed() {
  local out
  out="$(run_dropbox_cli status 2>&1 || true)"
  if [[ "$out" == *"not linked"* || "$out" == *"This computer isn't linked"* ]]; then
    log "Dropbox account is not linked yet. Run 'docker logs <container>' and open the link URL shown by Dropbox."
  fi
}

if [[ -z "${DROPBOX_HOME:-}" || ! -d "$DROPBOX_HOME" ]]; then
  log "Dropbox user '$DROPBOX_USER' does not exist in container."
  exit 1
fi

if [[ ! -x "$DROPBOX_DAEMON" ]]; then
  log "Dropbox daemon not found at $DROPBOX_DAEMON"
  exit 1
fi

if [[ ! -x "$DROPBOX_CLI" ]]; then
  log "Dropbox CLI not found at $DROPBOX_CLI"
  exit 1
fi

log "Starting Dropbox daemon..."
run_as_dropbox_shell "$(printf '%q' "$DROPBOX_DAEMON")" &
DAEMON_PID=$!

sleep 3
show_link_hint_if_needed

if wait_for_dropbox_ready; then
  configure_selective_sync
fi

log "Dropbox container is running. Daemon PID: ${DAEMON_PID}"
wait "$DAEMON_PID"
