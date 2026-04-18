#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

reexec_as_dropbox_user_if_needed() {
  if [[ "${EUID}" -ne 0 ]]; then
    return 0
  fi
  if [[ "${CODEDROP_SYNC_AS_USER:-}" == "1" ]]; then
    return 0
  fi

  local target_user=""
  local target_home=""
  local script_source
  local script_target
  local candidates=()
  local passwd_user
  local passwd_home

  if [[ -n "${DROPBOX_USER:-}" ]]; then
    if ! id -u "$DROPBOX_USER" >/dev/null 2>&1; then
      error "DROPBOX_USER '$DROPBOX_USER' does not exist."
    fi
    target_user="$DROPBOX_USER"
  else
    while IFS=: read -r passwd_user _ _ _ _ passwd_home _; do
      [[ -z "$passwd_user" || -z "$passwd_home" ]] && continue
      if [[ -f "$passwd_home/.config/codedrop/codedrop.env" || -x "$passwd_home/.local/bin/dropbox" || -x "$passwd_home/.dropbox-dist/dropboxd" ]]; then
        candidates+=("$passwd_user")
      fi
    done < /etc/passwd

    if [[ "${#candidates[@]}" -eq 1 ]]; then
      target_user="${candidates[0]}"
    elif [[ "${#candidates[@]}" -eq 0 ]]; then
      error "Could not detect Dropbox user automatically. Re-run as the Dropbox user or set DROPBOX_USER=<user>."
    else
      error "Multiple Dropbox users detected (${candidates[*]}). Re-run with DROPBOX_USER=<user>."
    fi
  fi

  target_user="$(prompt "Dropbox user to run as" "$target_user")"
  target_user="$(trim "$target_user")"
  if [[ -z "$target_user" ]]; then
    error "Dropbox user cannot be empty."
  fi
  if ! id -u "$target_user" >/dev/null 2>&1; then
    error "Dropbox user '$target_user' does not exist."
  fi

  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  target_home="${target_home:-/home/$target_user}"
  script_source="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  script_target="$script_source"

  if command -v runuser >/dev/null 2>&1; then
    if ! runuser -u "$target_user" -- test -r "$script_target" >/dev/null 2>&1; then
      script_target="/tmp/update-codedrop-sync-lxc.sh"
      cp "$script_source" "$script_target"
      chown "$target_user":"$target_user" "$script_target"
      chmod 755 "$script_target"
    fi

    log "Re-running as Dropbox user '$target_user'."
    exec runuser -u "$target_user" -- env \
      CODEDROP_SYNC_AS_USER=1 \
      DROPBOX_USER="$target_user" \
      HOME="$target_home" \
      LC_ALL=C \
      bash "$script_target"
  fi

  if command -v su >/dev/null 2>&1; then
    log "Re-running as Dropbox user '$target_user' via su."
    exec su - "$target_user" -c "CODEDROP_SYNC_AS_USER=1 DROPBOX_USER='$target_user' LC_ALL=C bash '$script_target'"
  fi

  error "Unable to switch user automatically (runuser/su not available)."
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
    token="${token%/}"
    while [[ "$token" == *"//"* ]]; do
      token="${token//\/\//\/}"
    done
    [[ -z "$token" ]] && continue
    ALLOW+=("$token")
  done
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

  local -a queue=("")
  local current_rel
  local current_full
  local current_trimmed
  local current_effective_rel
  local prefix_leaf
  local name
  local normalized
  local rel_path
  local rel_path_raw
  local full_path
  local -a remote_entries
  local saw_valid_entry=0
  local exclude_line
  local exclude_item
  local exclude_output

  prefix_leaf="${PREFIX_PATH_NORMALIZED##*/}"

  while [[ "${#queue[@]}" -gt 0 ]]; do
    current_rel="${queue[0]}"
    queue=("${queue[@]:1}")

    current_effective_rel="$current_rel"
    if [[ -n "$prefix_leaf" && "$prefix_leaf" != "/" ]]; then
      if [[ "$current_effective_rel" == "$prefix_leaf" ]]; then
        current_effective_rel=""
      elif [[ "$current_effective_rel" == "$prefix_leaf/"* ]]; then
        current_effective_rel="${current_effective_rel#"$prefix_leaf"/}"
      fi
    fi

    if [[ -z "$current_effective_rel" ]]; then
      current_full="$PREFIX_PATH_NORMALIZED"
    else
      current_full="$(build_full_path "$current_effective_rel")"
    fi
    current_trimmed="${current_full#/}"

    mapfile -t remote_entries < <("$DROPBOX_CLI" ls "$current_full" 2>/dev/null || true)
    if [[ "${#remote_entries[@]}" -eq 0 ]]; then
      continue
    fi

    for name in "${remote_entries[@]}"; do
      normalized="${name%/}"
      normalized="${normalized#/}"
      if [[ "$normalized" == *" (File doesn't exist!)" ]]; then
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
      saw_valid_entry=1

      if [[ -z "$current_rel" ]]; then
        rel_path_raw="$normalized"
      else
        rel_path_raw="$current_rel/$normalized"
      fi

      rel_path="$rel_path_raw"
      if [[ -n "$prefix_leaf" && "$prefix_leaf" != "/" ]]; then
        if [[ "$rel_path" == "$prefix_leaf/"* ]]; then
          rel_path="${rel_path#"$prefix_leaf"/}"
        elif [[ "$rel_path" == "$prefix_leaf" ]]; then
          # Dropbox CLI may echo the PREFIX_PATH leaf back as an entry.
          # Skip exclude/include action for this synthetic self-entry.
          continue
        fi
      fi
      full_path="$(build_full_path "$rel_path")"

      if is_allowed "$rel_path"; then
        log "Including ${full_path}"
        "$DROPBOX_CLI" exclude remove "${full_path}" >/dev/null 2>&1 || true
      else
        log "Excluding ${full_path}"
        "$DROPBOX_CLI" exclude add "${full_path}" >/dev/null 2>&1 || true
      fi

      if is_ancestor_of_allowed "$rel_path"; then
        queue+=("$rel_path")
      fi
    done
  done

  if [[ "$saw_valid_entry" -eq 0 ]]; then
    log "No listable entries found under ${PREFIX_PATH_NORMALIZED}. Verify PREFIX_PATH with: $DROPBOX_CLI ls \"$PREFIX_PATH_NORMALIZED\""
    return 0
  fi

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

reexec_as_dropbox_user_if_needed

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
