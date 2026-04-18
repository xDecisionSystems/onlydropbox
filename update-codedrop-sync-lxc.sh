#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

LOCAL_USER="${DROPBOX_USER:-${SUDO_USER:-${USER:-}}}"
LOCAL_HOME="${HOME:-/root}"

ensure_root_with_su() {
  [[ "${EUID}" -ne 0 ]] && error "Run this updater as root."
  command -v su >/dev/null 2>&1 || error "'su' is required for user-scoped execution."
}

resolve_user_home() {
  local user_name="$1"
  local home_dir=""

  if [[ -z "$user_name" ]]; then
    printf '%s' "${HOME:-/root}"
    return 0
  fi

  if [[ "$user_name" == "$(id -un)" ]]; then
    printf '%s' "${HOME:-/root}"
    return 0
  fi

  if id -u "$user_name" >/dev/null 2>&1; then
    home_dir="$(getent passwd "$user_name" | cut -d: -f6)"
  fi
  printf '%s' "${home_dir:-/home/$user_name}"
}

run_as_local_user() {
  local target_user="${1:-$LOCAL_USER}"
  shift || true

  [[ -z "$target_user" ]] && error "No local user configured for user-scoped command execution."
  [[ "$#" -eq 0 ]] && error "run_as_local_user requires a command."
  ensure_root_with_su

  local escaped_cmd
  printf -v escaped_cmd '%q ' "$@"
  escaped_cmd="${escaped_cmd% }"
  su - "$target_user" -c "$escaped_cmd"
}

run_as_local_user_shell() {
  local target_user="${1:-$LOCAL_USER}"
  shift || true
  [[ -z "$target_user" ]] && error "No local user configured for user-scoped command execution."
  [[ "$#" -eq 0 ]] && error "run_as_local_user_shell requires a command string."

  local shell_cmd="$1"
  ensure_root_with_su
  su - "$target_user" -c "$shell_cmd"
}

run_dropbox_cli() {
  run_as_local_user "${DROPBOX_USER:-$LOCAL_USER}" "$DROPBOX_CLI" "$@"
}

refresh_runtime_paths() {
  HOME_DIR="${LOCAL_HOME:-${HOME:-/root}}"
  CONFIG_DIR="$HOME_DIR/.config/codedrop"
  ENV_FILE="$CONFIG_DIR/codedrop.env"
  DROPBOX_DIST_DIR="$HOME_DIR/.dropbox-dist"
  DROPBOX_DAEMON="$DROPBOX_DIST_DIR/dropboxd"
  DROPBOX_CLI="$HOME_DIR/.local/bin/dropbox"
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

select_dropbox_user_for_root() {
  local target_user=""
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
      target_user="${SUDO_USER:-}"
      [[ -z "$target_user" ]] && error "Could not detect Dropbox user automatically. Set DROPBOX_USER=<user>."
    else
      target_user="${candidates[0]}"
    fi
  fi

  target_user="$(prompt "Dropbox user for Dropbox commands" "$target_user")"
  target_user="$(trim "$target_user")"
  [[ -z "$target_user" ]] && error "Dropbox user cannot be empty."
  [[ "$target_user" == "root" ]] && error "Dropbox user cannot be root. Use your Dropbox/Linux user (for example: aev)."
  if ! id -u "$target_user" >/dev/null 2>&1; then
    error "Dropbox user '$target_user' does not exist."
  fi

  DROPBOX_USER="$target_user"
  LOCAL_USER="$target_user"
  LOCAL_HOME="$(resolve_user_home "$target_user")"
  refresh_runtime_paths
}

split_prefix_components() {
  local raw="$1"
  local trimmed

  trimmed="$(trim "$raw")"
  trimmed="${trimmed#/}"
  trimmed="${trimmed%/}"

  EXISTING_ACCOUNT_ROOT=""
  EXISTING_ACCOUNT_NAME=""
  EXISTING_ACCOUNT_SUBPATH=""

  [[ -z "$trimmed" ]] && return 0

  IFS='/' read -r EXISTING_ACCOUNT_ROOT EXISTING_ACCOUNT_NAME EXISTING_ACCOUNT_SUBPATH <<< "$trimmed"
}

prompt_for_prefix_path() {
  local existing_prefix="$1"
  local account_type_default="organization"
  local account_type
  local account_root_default
  local account_root
  local account_name
  local account_name_default
  local account_subpath

  split_prefix_components "$existing_prefix"

  if [[ "$EXISTING_ACCOUNT_ROOT" == "Dropbox" ]]; then
    account_type_default="personal"
  fi

  while true; do
    account_type="$(prompt "ACCOUNT_TYPE (o=organization, p=personal)" "$account_type_default")"
    account_type="$(trim "${account_type,,}")"
    case "$account_type" in
      o|org|organization) account_type="organization"; break ;;
      p|personal) account_type="personal"; break ;;
      personal|organization) break ;;
      *) log "Please enter 'personal' or 'organization'." ;;
    esac
  done

  if [[ "$account_type" == "personal" ]]; then
    account_root_default="Dropbox"
  else
    account_root_default="${EXISTING_ACCOUNT_ROOT:-UCF Dropbox}"
  fi

  account_root="$(prompt "ACCOUNT_ROOT (e.g. Dropbox or UCF Dropbox)" "$account_root_default")"
  account_root="$(trim "$account_root")"
  [[ -z "$account_root" ]] && error "ACCOUNT_ROOT cannot be empty."

  account_name_default="${EXISTING_ACCOUNT_NAME:-${DROPBOX_USER:-$USER}}"
  account_name="$(prompt "ACCOUNT_NAME (e.g. Jane Doe)" "$account_name_default")"
  account_name="$(trim "$account_name")"
  [[ -z "$account_name" ]] && error "ACCOUNT_NAME cannot be empty."

  account_subpath="$(prompt "ACCOUNT_SUBPATH (optional path under account folder)" "${EXISTING_ACCOUNT_SUBPATH:-}")"
  account_subpath="$(trim "$account_subpath")"
  account_subpath="${account_subpath#/}"
  account_subpath="${account_subpath%/}"

  PREFIX_PATH="$account_root/$account_name"
  if [[ -n "$account_subpath" ]]; then
    PREFIX_PATH="$PREFIX_PATH/$account_subpath"
  fi

  while [[ "$PREFIX_PATH" == *"//"* ]]; do
    PREFIX_PATH="${PREFIX_PATH//\/\//\/}"
  done
  PREFIX_PATH="${PREFIX_PATH#/}"
}

normalize_prefix_path() {
  local raw="${PREFIX_PATH:-}"
  local rel
  raw="$(trim "$raw")"
  [[ -z "$raw" ]] && raw="/"

  if [[ "$raw" == "/" || "$raw" == "$HOME_DIR" || "$raw" == "$HOME_DIR/" ]]; then
    PREFIX_PATH_NORMALIZED="/"
    PREFIX_PATH_LS_NORMALIZED="$HOME_DIR"
  elif [[ "$raw" == "$HOME_DIR/"* ]]; then
    rel="${raw#"$HOME_DIR"/}"
    rel="${rel#/}"
    rel="${rel%/}"
    PREFIX_PATH_NORMALIZED="/$rel"
    PREFIX_PATH_LS_NORMALIZED="$HOME_DIR/$rel"
  elif [[ "$raw" == /* ]]; then
    PREFIX_PATH_NORMALIZED="${raw%/}"
    [[ -z "$PREFIX_PATH_NORMALIZED" ]] && PREFIX_PATH_NORMALIZED="/"
    PREFIX_PATH_LS_NORMALIZED="$PREFIX_PATH_NORMALIZED"
  else
    raw="${raw#/}"
    raw="${raw%/}"
    PREFIX_PATH_NORMALIZED="/$raw"
    PREFIX_PATH_LS_NORMALIZED="$HOME_DIR/$raw"
  fi

  while [[ "$PREFIX_PATH_NORMALIZED" == *"//"* ]]; do
    PREFIX_PATH_NORMALIZED="${PREFIX_PATH_NORMALIZED//\/\//\/}"
  done
  while [[ "$PREFIX_PATH_LS_NORMALIZED" == *"//"* ]]; do
    PREFIX_PATH_LS_NORMALIZED="${PREFIX_PATH_LS_NORMALIZED//\/\//\/}"
  done
}

update_prefix_path_from_normalized() {
  if [[ "$PREFIX_PATH_NORMALIZED" == "/" ]]; then
    PREFIX_PATH="/"
  else
    PREFIX_PATH="${PREFIX_PATH_NORMALIZED#/}"
  fi
}

path_has_listable_entries() {
  local probe_path="$1"
  local probe_trimmed
  local -a probe_entries
  local name
  local normalized

  probe_trimmed="${probe_path#/}"
  mapfile -t probe_entries < <(run_dropbox_cli ls "$probe_path" 2>/dev/null || true)
  [[ "${#probe_entries[@]}" -eq 0 ]] && return 1

  for name in "${probe_entries[@]}"; do
    normalized="${name%/}"
    normalized="${normalized#/}"
    if [[ "$normalized" == *" (File doesn't exist!)" ]]; then
      continue
    fi
    if [[ -n "$probe_trimmed" && "$probe_trimmed" != "/" ]]; then
      if [[ "$normalized" == "$probe_trimmed/"* ]]; then
        normalized="${normalized#"$probe_trimmed"/}"
      elif [[ "$normalized" == "$probe_trimmed" ]]; then
        normalized=""
      fi
    fi
    [[ -n "$normalized" ]] && return 0
  done

  return 1
}

nearest_listable_nonroot_parent() {
  local probe="$1"
  local parent

  while [[ "$probe" != "/" ]]; do
    parent="${probe%/*}"
    [[ -z "$parent" ]] && parent="/"
    if [[ "$parent" != "/" ]] && path_has_listable_entries "$parent"; then
      printf '%s' "$parent"
      return 0
    fi
    if [[ "$parent" == "/" ]]; then
      break
    fi
    probe="$parent"
  done

  return 1
}

build_full_path() {
  local child="$1"
  if [[ "$PREFIX_PATH_NORMALIZED" == "/" ]]; then
    printf '/%s' "$child"
  else
    printf '%s/%s' "$PREFIX_PATH_NORMALIZED" "$child"
  fi
}

build_ls_path() {
  local child="$1"
  if [[ "$PREFIX_PATH_LS_NORMALIZED" == "/" ]]; then
    printf '/%s' "$child"
  else
    printf '%s/%s' "$PREFIX_PATH_LS_NORMALIZED" "$child"
  fi
}

run_exclude_cmd() {
  local mode="$1"
  local sync_path="$2"
  local rel_path
  local cmd_output
  local target_user

  rel_path="${sync_path#/}"
  RUN_EXCLUDE_LAST_ERROR=""
  target_user="${DROPBOX_USER:-$USER}"
  log "Running command: su - $target_user -c '$DROPBOX_CLI exclude $mode \"$rel_path\"'"
  cmd_output="$(run_dropbox_cli exclude "$mode" "$rel_path" 2>&1 || true)"
  RUN_EXCLUDE_LAST_ERROR="$cmd_output"
  if [[ -n "$cmd_output" ]]; then
    if [[ "$cmd_output" == *"Excluded:"* || "$cmd_output" == *"Included:"* ]]; then
      return 0
    elif [[ "$cmd_output" == *"already ignored"* || "$cmd_output" == *"isn't currently ignored"* || "$cmd_output" == *"not currently ignored"* ]]; then
      return 0
    fi
  fi

  return 1
}

exclude_list_normalized() {
  local line
  local norm

  while IFS= read -r line; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == "Excluded:" ]] && continue
    [[ "$line" == "No directories are being ignored." ]] && continue
    norm="${line%/}"
    norm="${norm#/}"
    [[ -z "$norm" ]] && continue
    printf '%s\n' "$norm"
  done < <(run_dropbox_cli exclude list 2>/dev/null || true)
}

is_path_excluded() {
  local rel_path="$1"
  local line
  while IFS= read -r line; do
    [[ "$line" == "$rel_path" ]] && return 0
  done < <(exclude_list_normalized)
  return 1
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
  run_as_local_user_shell "${DROPBOX_USER:-$LOCAL_USER}" "nohup $(printf '%q' "$DROPBOX_DAEMON") >/tmp/codedrop-dropboxd.log 2>&1 &"
  sleep 3

  if pgrep -f "$DROPBOX_DAEMON" >/dev/null 2>&1; then
    return 0
  fi

  status="$(run_dropbox_cli status 2>&1 || true)"
  if [[ "$status" == *"Starting..."* || "$status" == *"Up to date"* || "$status" == *"Syncing"* || "$status" == *"Connecting"* || "$status" == *"Downloading"* || "$status" == *"Indexing"* ]] || is_link_required_status "$status"; then
    return 0
  fi

  error "Dropbox daemon did not start. Check /tmp/codedrop-dropboxd.log"
}

wait_for_dropbox_ready() {
  local max_wait=300
  local elapsed=0
  local status

  while (( elapsed < max_wait )); do
    status="$(run_dropbox_cli status 2>/dev/null || true)"

    case "$status" in
      *"Up to date"*|*"Syncing"*)
        return 0
        ;;
      *"Connecting"*|*"Downloading"*|*"Indexing"*|*"Starting"*)
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

wait_for_dropbox_up_to_date() {
  local max_wait=300
  local elapsed=0
  local status

  while (( elapsed < max_wait )); do
    status="$(run_dropbox_cli status 2>/dev/null || true)"
    case "$status" in
      *"Up to date"*) return 0 ;;
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
  local action_failures=0
  local fallback_prefix=""

  if ! path_has_listable_entries "$PREFIX_PATH_LS_NORMALIZED"; then
    fallback_prefix="$(nearest_listable_nonroot_parent "$PREFIX_PATH_LS_NORMALIZED" || true)"
    if [[ -n "$fallback_prefix" ]]; then
      log "Configured PREFIX_PATH is not listable: ${PREFIX_PATH_LS_NORMALIZED}"
      log "Falling back to nearest listable parent: ${fallback_prefix}"
      PREFIX_PATH_LS_NORMALIZED="$fallback_prefix"
      if [[ "$PREFIX_PATH_LS_NORMALIZED" == "$HOME_DIR" ]]; then
        PREFIX_PATH_NORMALIZED="/"
      elif [[ "$PREFIX_PATH_LS_NORMALIZED" == "$HOME_DIR/"* ]]; then
        PREFIX_PATH_NORMALIZED="/${PREFIX_PATH_LS_NORMALIZED#"$HOME_DIR"/}"
      else
        PREFIX_PATH_NORMALIZED="$PREFIX_PATH_LS_NORMALIZED"
      fi
      update_prefix_path_from_normalized
    else
      log "Configured PREFIX_PATH is not listable: ${PREFIX_PATH_LS_NORMALIZED}"
      log "No safe non-root parent is listable yet; refusing to fall back to '/'."
      return 2
    fi
  fi

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
      current_full="$PREFIX_PATH_LS_NORMALIZED"
    else
      current_full="$(build_ls_path "$current_effective_rel")"
    fi
    current_trimmed="${current_full#/}"

    mapfile -t remote_entries < <(run_dropbox_cli ls "$current_full" 2>/dev/null || true)
    if [[ "${#remote_entries[@]}" -eq 0 ]]; then
      continue
    fi

    for name in "${remote_entries[@]}"; do
      # Dropbox CLI may print multiple entries per line in column layout.
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
      normalized="${name%/}"
      normalized="${normalized#/}"
      normalized="$(trim "$normalized")"
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
      saw_valid_entry=1

      if [[ -z "$current_rel" ]]; then
        rel_path_raw="$normalized"
      else
        rel_path_raw="$current_rel/$normalized"
      fi

      rel_path="$rel_path_raw"
      rel_path="$(trim "$rel_path")"
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
        if ! run_exclude_cmd remove "${full_path}"; then
          log "Failed to include ${full_path} (dropbox exclude remove): ${RUN_EXCLUDE_LAST_ERROR:-no output}"
          action_failures=$((action_failures + 1))
        fi
      else
        log "Excluding ${full_path}"
        if ! run_exclude_cmd add "${full_path}"; then
          log "Failed to exclude ${full_path} (dropbox exclude add): ${RUN_EXCLUDE_LAST_ERROR:-no output}"
          action_failures=$((action_failures + 1))
        fi
      fi

      if is_ancestor_of_allowed "$rel_path"; then
        queue+=("$rel_path")
      fi
      done < <(printf '%s\n' "$name" | awk 'BEGIN{FS="  +"} {for(i=1;i<=NF;i++) if(length($i)) print $i}')
    done
  done

  if [[ "$saw_valid_entry" -eq 0 ]]; then
    log "No listable entries found under ${PREFIX_PATH_LS_NORMALIZED}. Verify PREFIX_PATH with: $DROPBOX_CLI ls \"$PREFIX_PATH_LS_NORMALIZED\""
    return 2
  fi

  if exclude_output="$(run_dropbox_cli exclude list 2>/dev/null || true)"; then
    while IFS= read -r exclude_line; do
      exclude_item="$(trim "$exclude_line")"
      [[ "$exclude_item" != /* ]] && continue
      exclude_item="${exclude_item%/}"

      for normalized in "${ALLOW[@]}"; do
        full_path="$(build_full_path "$normalized")"
        if [[ "$exclude_item" == "$full_path" || "$exclude_item" == "$full_path/"* ]]; then
          log "Including nested excluded path ${exclude_item}"
          if ! run_exclude_cmd remove "$exclude_item"; then
            log "Failed to include nested excluded path ${exclude_item}: ${RUN_EXCLUDE_LAST_ERROR:-no output}"
            action_failures=$((action_failures + 1))
          fi
          break
        fi
      done
    done <<< "$exclude_output"
  fi

  if [[ "$action_failures" -gt 0 ]]; then
    error "Selective sync encountered ${action_failures} Dropbox CLI command failure(s)."
  fi

  log "Selective sync configuration finished."
}

refresh_runtime_paths

if [[ "${EUID}" -ne 0 ]]; then
  error "Run this updater as root."
fi

select_dropbox_user_for_root
log "Running in root mode. User-scoped Dropbox commands will run as '$LOCAL_USER' via su."

if [[ ! -x "$DROPBOX_CLI" ]]; then
  error "Dropbox CLI not found at $DROPBOX_CLI. Run the installer first."
fi

write_env_config() {
  run_as_local_user_shell "$LOCAL_USER" "mkdir -p $(printf '%q' "$CONFIG_DIR")"
  run_as_local_user_shell "$LOCAL_USER" "cat > $(printf '%q' "$ENV_FILE") <<'CONFIG'
# Updated by update-codedrop-sync-lxc.sh on $(date '+%Y-%m-%d %H:%M:%S')
PREFIX_PATH=$PREFIX_PATH
SYNC_FOLDERS=$SYNC_FOLDERS
CONFIG
"
}

existing_prefix="/"
existing_sync=""
if [[ -f "$ENV_FILE" ]]; then
  existing_prefix="$(read_config_value "PREFIX_PATH" "$ENV_FILE")"
  existing_sync="$(read_config_value "SYNC_FOLDERS" "$ENV_FILE")"
fi

prompt_for_prefix_path "${existing_prefix:-/}"
SYNC_FOLDERS="$(prompt "SYNC_FOLDERS (comma-separated relative folder paths to sync; empty = unchanged)" "${existing_sync:-}")"

PREFIX_PATH="$(trim "$PREFIX_PATH")"
SYNC_FOLDERS="$(trim "$SYNC_FOLDERS")"
[[ -z "$PREFIX_PATH" ]] && PREFIX_PATH="/"

write_env_config

log "Saved config to $ENV_FILE"

start_dropbox_daemon

status_out="$(run_dropbox_cli status 2>&1 || true)"
if is_link_required_status "$status_out"; then
  printf 'SCRIPT_MARKER: fandom\n'
  link_url="$(extract_link_url "$status_out")"
  if [[ -n "$link_url" ]]; then
    printf '\nDropbox is not linked. Open this URL:\n  %s\n\n' "$link_url"
  else
    printf '\nDropbox is not linked. Run:\n  %s start -i\n\n' "$DROPBOX_CLI"
  fi
  exit 0
fi

wait_rc=0
if ! wait_for_dropbox_ready; then
  wait_rc=$?
  if [[ "$wait_rc" -eq 10 ]]; then
    printf 'SCRIPT_MARKER: fandom\n\nDropbox needs account linking before selective sync can be applied.\nRun:\n  %s start -i\n\n' "$DROPBOX_CLI"
    exit 0
  fi
  error "Dropbox did not become ready. Check /tmp/codedrop-dropboxd.log and '$DROPBOX_CLI status'."
fi

if ! configure_selective_sync; then
  error "Early selective sync update failed. Verify PREFIX_PATH with '$DROPBOX_CLI ls \"$PREFIX_PATH_NORMALIZED\"', then rerun."
fi
write_env_config
log "Saved early selective sync config to $ENV_FILE"

if ! wait_for_dropbox_up_to_date; then
  wait_rc=$?
  if [[ "$wait_rc" -eq 10 ]]; then
    error "Dropbox became unlinked before final selective sync verification."
  fi
  error "Dropbox did not reach 'Up to date' in time for final selective sync verification."
fi

if ! configure_selective_sync; then
  error "Final selective sync verification failed. Verify PREFIX_PATH with '$DROPBOX_CLI ls \"$PREFIX_PATH_NORMALIZED\"', then rerun."
fi
write_env_config
log "Saved effective config to $ENV_FILE"
printf 'SCRIPT_MARKER: fandom\n\nUpdated selective sync with:\n  PREFIX_PATH=%s\n  SYNC_FOLDERS=%s\n\n' "$PREFIX_PATH" "$SYNC_FOLDERS"
exit 0
