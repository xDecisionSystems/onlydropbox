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

prompt_yes_no() {
  local label="$1"
  local default_value="${2:-n}"
  local input

  while true; do
    read -r -p "$label [$default_value]: " input || true
    input="$(trim "${input:-}")"
    input="${input,,}"
    [[ -z "$input" ]] && input="${default_value,,}"

    case "$input" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) log "Please answer yes or no." ;;
    esac
  done
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

LOCAL_USER="${DROPBOX_USER:-${SUDO_USER:-${USER:-}}}"
LOCAL_HOME="${HOME:-/root}"

ensure_root_with_su() {
  [[ "${EUID}" -ne 0 ]] && error "This installer must run as root."
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

download_update_script_as_user() {
  local update_script_url="https://raw.githubusercontent.com/xDecisionSystems/codedrop/main/update-codedrop-sync-lxc.sh"
  local target_dir="$HOME_DIR/.local/bin"
  local target_file="$target_dir/update-codedrop-sync-lxc.sh"

  run_as_local_user_shell "$LOCAL_USER" "mkdir -p $(printf '%q' "$target_dir")"

  log "Downloading update helper script to $target_file for user '$LOCAL_USER'"
  if command -v curl >/dev/null 2>&1; then
    run_as_local_user_shell "$LOCAL_USER" "curl -fsSL $(printf '%q' "$update_script_url") -o $(printf '%q' "$target_file")"
  elif command -v wget >/dev/null 2>&1; then
    run_as_local_user_shell "$LOCAL_USER" "wget -qO $(printf '%q' "$target_file") $(printf '%q' "$update_script_url")"
  else
    error "Neither curl nor wget is available to download update-codedrop-sync-lxc.sh."
  fi

  run_as_local_user_shell "$LOCAL_USER" "chmod +x $(printf '%q' "$target_file")"
}

install_code_server_as_user() {
  if run_as_local_user_shell "$LOCAL_USER" "command -v code-server >/dev/null 2>&1"; then
    log "code-server is already installed system-wide."
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required to install code-server. Re-run as root so prerequisites can be installed."
  fi

  # The upstream installer needs root for dpkg; run it as root to avoid nested su prompts.
  log "Installing code-server system-wide."
  run_privileged sh -c 'curl -fsSL https://code-server.dev/install.sh | sh'
}

install_tailscale_as_root() {
  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale is already installed."
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required to install Tailscale."
  fi

  log "Installing Tailscale."
  run_privileged sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'
}

install_claude_code_as_user() {
  local claude_extension_id="anthropic.claude-code"

  if run_as_local_user_shell "$LOCAL_USER" "command -v claude >/dev/null 2>&1"; then
    log "Claude Code is already installed for user '$LOCAL_USER'."
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required to install Claude Code. Re-run as root so prerequisites can be installed."
  fi

  log "Installing Claude Code for user '$LOCAL_USER'."
  run_as_local_user_shell "$LOCAL_USER" "curl -fsSL https://claude.ai/install.sh | bash"

  if ! run_as_local_user_shell "$LOCAL_USER" "command -v code-server >/dev/null 2>&1"; then
    log "code-server not found; skipping Claude extension '$claude_extension_id' installation."
    return 0
  fi

  if run_as_local_user_shell "$LOCAL_USER" "code-server --list-extensions 2>/dev/null | grep -Fxq $(printf '%q' "$claude_extension_id")"; then
    log "Claude extension '$claude_extension_id' is already installed for user '$LOCAL_USER'."
    return 0
  fi

  log "Installing Claude extension '$claude_extension_id' for user '$LOCAL_USER'."
  run_as_local_user_shell "$LOCAL_USER" "code-server --install-extension $(printf '%q' "$claude_extension_id")"
}

install_codex_extension_as_user() {
  if ! run_as_local_user_shell "$LOCAL_USER" "command -v code-server >/dev/null 2>&1"; then
    error "code-server is required to install a Codex extension. Install code-server and re-run the installer."
  fi

  log "Installing Codex extension '$CODEX_EXTENSION_ID' for user '$LOCAL_USER'."
  run_as_local_user_shell "$LOCAL_USER" "code-server --install-extension $(printf '%q' "$CODEX_EXTENSION_ID")"
}

install_python_extension_as_user() {
  local python_extension_id="ms-python.python"

  if ! run_as_local_user_shell "$LOCAL_USER" "command -v code-server >/dev/null 2>&1"; then
    error "code-server is required to install the Python extension. Install code-server and re-run the installer."
  fi

  if run_as_local_user_shell "$LOCAL_USER" "code-server --list-extensions 2>/dev/null | grep -Fxq $(printf '%q' "$python_extension_id")"; then
    log "Python extension '$python_extension_id' is already installed for user '$LOCAL_USER'."
    return 0
  fi

  log "Installing Python extension '$python_extension_id' for user '$LOCAL_USER'."
  run_as_local_user_shell "$LOCAL_USER" "code-server --install-extension $(printf '%q' "$python_extension_id")"
}

install_latex_prereqs_as_root() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log "apt-get not found; skipping automatic install of latexindent.pl/cpanm/chktex prerequisites."
    return 0
  fi

  log "Installing LaTeX formatting/linting prerequisites in root mode (latexindent.pl, cpanm, chktex)."
  run_privileged sh -c '
    set -e
    [ "$(id -u)" -eq 0 ] || { echo "Root mode required for LaTeX prerequisites." >&2; exit 1; }
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      perl \
      cpanminus \
      texlive-extra-utils \
      chktex
  '
}

install_latex_support_as_user() {
  local latex_extension_id="mathematic.vscode-latex"

  if ! run_as_local_user_shell "$LOCAL_USER" "command -v code-server >/dev/null 2>&1"; then
    error "code-server is required to install LaTeX support. Install code-server and re-run the installer."
  fi

  install_latex_prereqs_as_root

  if run_as_local_user_shell "$LOCAL_USER" "code-server --list-extensions 2>/dev/null | grep -Fxq $(printf '%q' "$latex_extension_id")"; then
    log "LaTeX extension '$latex_extension_id' is already installed for user '$LOCAL_USER'."
  else
    log "Installing LaTeX extension '$latex_extension_id' for user '$LOCAL_USER'."
    run_as_local_user_shell "$LOCAL_USER" "code-server --install-extension $(printf '%q' "$latex_extension_id")"
  fi

  if command -v latexindent.pl >/dev/null 2>&1; then
    log "latexindent.pl detected. On first format, install any prompted Perl modules via cpanm."
  else
    log "latexindent.pl not found after install attempt. Install 'texlive-extra-utils' and re-run."
  fi
}

is_valid_unix_username() {
  local name="$1"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

prompt_for_dropbox_user() {
  local chosen
  while true; do
    chosen="$(prompt "DROPBOX_USER (linux username to run daemon)" "${DROPBOX_USER:-dropbox}")"
    chosen="$(trim "$chosen")"

    if [[ -z "$chosen" ]]; then
      log "Username cannot be empty."
      continue
    fi
    if ! is_valid_unix_username "$chosen"; then
      log "Invalid username '$chosen'. Use lowercase letters, digits, '_' or '-', and start with a letter or '_'."
      continue
    fi

    DROPBOX_USER="$chosen"
    return 0
  done
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

split_prefix_components() {
  local raw="$1"
  local trimmed

  trimmed="$(trim "$raw")"
  trimmed="${trimmed#/}"
  trimmed="${trimmed%/}"

  EXISTING_ACCOUNT_ROOT=""
  EXISTING_ACCOUNT_NAME=""

  [[ -z "$trimmed" ]] && return 0

  IFS='/' read -r EXISTING_ACCOUNT_ROOT EXISTING_ACCOUNT_NAME _ <<< "$trimmed"
}

prompt_for_prefix_path() {
  local existing_prefix="$1"
  local account_type_default="organization"
  local account_type
  local account_root_default
  local account_root
  local account_name
  local account_name_default

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
  account_name="$(prompt "ACCOUNT_NAME (Dropbox account folder name)" "$account_name_default")"
  account_name="$(trim "$account_name")"
  [[ -z "$account_name" ]] && error "ACCOUNT_NAME cannot be empty."

  PREFIX_PATH="$account_root/$account_name"

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
  local attempt
  local verify_try
  local target_user

  rel_path="${sync_path#/}"
  RUN_EXCLUDE_LAST_ERROR=""
  for attempt in 1 2 3 4 5; do
    target_user="${DROPBOX_USER:-$USER}"
    log "Running command: su - $target_user -c '$DROPBOX_CLI exclude $mode \"$rel_path\"'"
    cmd_output="$(run_dropbox_cli exclude "$mode" "$rel_path" 2>&1 || true)"
    RUN_EXCLUDE_LAST_ERROR="$cmd_output"
    if [[ -n "$cmd_output" ]]; then
      if [[ "$cmd_output" == *"Excluded:"* || "$cmd_output" == *"Included:"* ]]; then
        return 0
      elif [[ "$cmd_output" == *"already ignored"* || "$cmd_output" == *"isn't currently ignored"* || "$cmd_output" == *"not currently ignored"* ]]; then
        return 0
      elif [[ "$cmd_output" == *"Error"* || "$cmd_output" == *"error"* ]]; then
        sleep 1
        continue
      fi
    fi

    for verify_try in 1 2 3 4 5; do
      if [[ "$mode" == "add" ]]; then
        if is_path_excluded "$rel_path"; then
          return 0
        fi
      else
        if ! is_path_excluded "$rel_path"; then
          return 0
        fi
      fi
      sleep 1
    done
  done

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

wait_for_dropbox_ready() {
  local max_wait=300
  local elapsed=0
  local status
  local last_status=""
  local last_reported=-1

  log "Waiting for Dropbox daemon to initialize..."
  while (( elapsed < max_wait )); do
    status="$(run_dropbox_cli status 2>/dev/null || true)"

    case "$status" in
      *"Up to date"*|*"Syncing"*)
        log "Dropbox is responding: $status"
        return 0
        ;;
      *"Connecting"*|*"Downloading"*|*"Indexing"*|*"Starting"*)
        ;;
      *"not linked"*|*"This computer isn't linked"*|*"isn't linked to any Dropbox account"*|*"Please visit "*"/cli_link_nonce"*)
        log "Dropbox requires account linking before continuing."
        return 10
        ;;
    esac

    if [[ "$status" != "$last_status" ]]; then
      log "Dropbox status: ${status:-<empty>}"
      last_status="$status"
      last_reported=$elapsed
    elif (( elapsed - last_reported >= 10 )); then
      log "Still waiting... (${elapsed}s elapsed, status: ${status:-<empty>})"
      last_reported=$elapsed
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  log "Dropbox did not become ready in ${max_wait}s. Current status: $(run_dropbox_cli status 2>/dev/null || true)"
  return 1
}

tail_daemon_log() {
  local log_file="/tmp/codedrop-dropboxd.log"
  if [[ -f "$log_file" ]]; then
    log "Recent Dropbox daemon log (last 60 lines):"
    tail -n 60 "$log_file" >&2 || true
  else
    log "Dropbox daemon log file not found at $log_file"
  fi
}

diagnose_dropbox_runtime() {
  if ! command -v ldd >/dev/null 2>&1; then
    return 0
  fi

  local missing
  missing="$(ldd "$DROPBOX_DAEMON" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -n "$missing" ]]; then
    log "Missing shared libraries detected: $missing"
    cat >&2 <<'EOF'
Potential fix:
  apt-get update && apt-get install -y \
    libx11-6 libxext6 libxrender1 libxrandr2 libxfixes3 libxi6 libxtst6 libxss1 \
    libatk1.0-0 libatk-bridge2.0-0 libgtk-3-0 libnotify4 libdbus-1-3 libasound2 \
    libnss3 libnspr4 libpango-1.0-0 libcairo2 xdg-utils
EOF
  else
    log "No missing shared libraries reported by ldd."
  fi
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
    log "Dropbox daemon is already running."
    return 0
  fi

  log "Starting Dropbox daemon in background."
  run_as_local_user_shell "${DROPBOX_USER:-$LOCAL_USER}" "nohup $(printf '%q' "$DROPBOX_DAEMON") >/tmp/codedrop-dropboxd.log 2>&1 &"
  sleep 4

  if pgrep -f "$DROPBOX_DAEMON" >/dev/null 2>&1; then
    log "Dropbox daemon started."
    return 0
  fi

  status="$(run_dropbox_cli status 2>&1 || true)"
  if [[ "$status" == *"Starting..."* || "$status" == *"Up to date"* || "$status" == *"Syncing"* || "$status" == *"Connecting"* || "$status" == *"Downloading"* || "$status" == *"Indexing"* ]] || is_link_required_status "$status"; then
    log "Dropbox appears to be running (status check): ${status//$'\n'/ }"
    return 0
  fi

  tail_daemon_log
  diagnose_dropbox_runtime
  error "Dropbox daemon exited right after start. This is usually a runtime dependency or unsupported filesystem issue in the container."
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
  local final_exclude_output
  local expected_rel
  local action_failures=0
  local fallback_prefix=""
  local exclude_attempts=0
  local -a expected_excludes=()
  local -a excluded_now=()
  local -a missing_excludes=()
  local -A excluded_map=()

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
        exclude_attempts=$((exclude_attempts + 1))
        expected_rel="${full_path#/}"
        expected_excludes+=("$expected_rel")
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

  if [[ "${#expected_excludes[@]}" -gt 0 ]]; then
    mapfile -t excluded_now < <(exclude_list_normalized)
    excluded_map=()
    for normalized in "${excluded_now[@]:-}"; do
      excluded_map["$normalized"]=1
    done

    missing_excludes=()
    for expected_rel in "${expected_excludes[@]}"; do
      if [[ -z "${excluded_map[$expected_rel]:-}" ]]; then
        missing_excludes+=("$expected_rel")
      fi
    done

    if [[ "${#missing_excludes[@]}" -gt 0 ]]; then
      log "Retrying ${#missing_excludes[@]} missing exclude entries reported absent from Dropbox state."
      for expected_rel in "${missing_excludes[@]}"; do
        run_exclude_cmd add "$expected_rel" >/dev/null 2>&1 || true
      done
      sleep 1

      mapfile -t excluded_now < <(exclude_list_normalized)
      excluded_map=()
      for normalized in "${excluded_now[@]:-}"; do
        excluded_map["$normalized"]=1
      done

      missing_excludes=()
      for expected_rel in "${expected_excludes[@]}"; do
        if [[ -z "${excluded_map[$expected_rel]:-}" ]]; then
          missing_excludes+=("$expected_rel")
        fi
      done

      if [[ "${#missing_excludes[@]}" -gt 0 ]]; then
        error "Dropbox did not persist ${#missing_excludes[@]} exclude entries (first: ${missing_excludes[0]})."
      fi
    fi
  fi

  final_exclude_output="$(run_dropbox_cli exclude list 2>/dev/null || true)"
  if [[ "$exclude_attempts" -gt 0 && "$final_exclude_output" == *"No directories are being ignored."* ]]; then
    error "Selective sync issued exclude operations, but Dropbox reports no excluded directories. Verify with a relative path such as: '$DROPBOX_CLI exclude add \"${PREFIX_PATH#/}/Accounts\"'."
  fi

  log "Selective sync configuration finished."
}

refresh_runtime_paths
DROPBOX_DOWNLOAD_URL="https://www.dropbox.com/download?plat=lnx.x86_64"
DROPBOX_CLI_URL="https://www.dropbox.com/download?dl=packages/dropbox.py"

write_env_config() {
  run_as_local_user_shell "$LOCAL_USER" "mkdir -p $(printf '%q' "$CONFIG_DIR")"
  run_as_local_user_shell "$LOCAL_USER" "cat > $(printf '%q' "$ENV_FILE") <<'EOF'
# Generated by install-codedrop-lxc.sh on $(date '+%Y-%m-%d %H:%M:%S')
PREFIX_PATH=$PREFIX_PATH
SYNC_FOLDERS=$SYNC_FOLDERS
EOF
"
}

install_and_configure_dropbox() {
  local arch
  local tmp_tar
  local status_out
  local link_url
  local wait_rc

  run_as_local_user_shell "$LOCAL_USER" "mkdir -p $(printf '%q' "$CONFIG_DIR") $(printf '%q' "$HOME_DIR/.local/bin")"

  write_env_config

  log "Saved config to $ENV_FILE"

  arch="$(uname -m)"
  if [[ "$arch" != "x86_64" ]]; then
    error "Dropbox headless Linux binary from this script currently supports x86_64. Detected: $arch"
  fi

  if [[ ! -x "$DROPBOX_DAEMON" ]]; then
    log "Installing Dropbox headless daemon to $DROPBOX_DIST_DIR"
    tmp_tar="$(mktemp)"
    wget -qO "$tmp_tar" "$DROPBOX_DOWNLOAD_URL"
    run_as_local_user "$LOCAL_USER" tar -xzf "$tmp_tar" -C "$HOME_DIR"
    rm -f "$tmp_tar"
  fi

  if [[ ! -f "$DROPBOX_CLI" ]]; then
    log "Installing Dropbox CLI to $DROPBOX_CLI"
    run_as_local_user_shell "$LOCAL_USER" "wget -qO $(printf '%q' "$DROPBOX_CLI") $(printf '%q' "$DROPBOX_CLI_URL")"
    run_as_local_user_shell "$LOCAL_USER" "chmod +x $(printf '%q' "$DROPBOX_CLI")"
  fi

  start_dropbox_daemon

  status_out="$(run_dropbox_cli status 2>&1 || true)"
  if is_link_required_status "$status_out"; then
    link_url="$(extract_link_url "$status_out")"
    cat <<EOF

Dropbox is not linked yet.
EOF
    if [[ -n "${link_url:-}" ]]; then
      cat <<EOF
Open this pairing URL:
  $link_url
EOF
    else
      cat <<EOF
Run this command to get the pairing URL:
  $DROPBOX_CLI start -i
EOF
    fi
    cat <<EOF
SCRIPT_MARKER: tailscale

After linking completes, re-run this installer to apply selective sync using:
  PREFIX_PATH=$PREFIX_PATH
  SYNC_FOLDERS=$SYNC_FOLDERS

Or apply selective sync directly with:
  $HOME_DIR/.local/bin/update-codedrop-sync-lxc.sh

EOF
    exit 0
  fi

  if ! wait_for_dropbox_ready; then
    wait_rc=$?
    if [[ "$wait_rc" -eq 10 ]]; then
      cat <<EOF
SCRIPT_MARKER: tailscale

Dropbox needs linking before selective sync can be applied.
Run:
  $DROPBOX_CLI start -i

After linking completes, re-run this installer.

Or apply selective sync directly with:
  $HOME_DIR/.local/bin/update-codedrop-sync-lxc.sh

EOF
      exit 0
    fi
    tail_daemon_log
    diagnose_dropbox_runtime
    error "Dropbox daemon did not become ready. Check /tmp/codedrop-dropboxd.log and run '$DROPBOX_CLI status'."
  fi

  if ! configure_selective_sync; then
    error "Early selective sync update failed. Verify PREFIX_PATH with '$DROPBOX_CLI ls \"$PREFIX_PATH_NORMALIZED\"', then rerun."
  fi
  write_env_config
  log "Saved early selective sync config to $ENV_FILE"
  log "Skipping final wait/verification. You can run update-codedrop-sync-lxc.sh later if needed."
}

if ! command -v apt-get >/dev/null 2>&1; then
  error "apt-get not found. This installer currently supports Debian/Ubuntu-based LXC containers."
fi
if [[ "${EUID}" -ne 0 ]]; then
  error "Run this installer as root."
fi

INSTALL_DROPBOX="${INSTALL_DROPBOX:-n}"
printf 'SCRIPT_MARKER: tailscale\n'
if prompt_yes_no "Install/keep Dropbox (headless daemon + selective sync)?" "${INSTALL_DROPBOX}"; then
  INSTALL_DROPBOX="y"
else
  INSTALL_DROPBOX="n"
fi

log "Installing minimal baseline packages."
run_privileged apt-get update
run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  tar \
  python3 \
  procps

INSTALL_TAILSCALE="n"
if command -v tailscale >/dev/null 2>&1; then
  log "Tailscale is already installed; skipping Tailscale prompt."
elif prompt_yes_no "Install Tailscale?" "n"; then
  INSTALL_TAILSCALE="y"
fi
if [[ "$INSTALL_TAILSCALE" == "y" ]]; then
  install_tailscale_as_root
fi

if [[ "$INSTALL_DROPBOX" == "y" ]]; then
  log "Installing Dropbox prerequisites."
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wget \
    python3-gpg \
    libatomic1 \
    libglib2.0-0 \
    libstdc++6
fi

if [[ "$INSTALL_DROPBOX" == "y" && -z "${DROPBOX_USER:-}" ]]; then
  prompt_for_dropbox_user
fi

if [[ -n "${DROPBOX_USER:-}" ]]; then
  LOCAL_USER="$DROPBOX_USER"
fi
if [[ -z "${LOCAL_USER:-}" || "$LOCAL_USER" == "root" ]]; then
  LOCAL_USER="$(prompt "LOCAL_USER (linux username for user-scoped install steps)" "${SUDO_USER:-}")"
  LOCAL_USER="$(trim "$LOCAL_USER")"
  if [[ -z "$LOCAL_USER" ]]; then
    error "LOCAL_USER cannot be empty when running installer as root."
  fi
fi
if ! is_valid_unix_username "$LOCAL_USER"; then
  error "Invalid LOCAL_USER '$LOCAL_USER'."
fi
if [[ "$LOCAL_USER" == "root" ]]; then
  error "LOCAL_USER cannot be root. Use your Dropbox/Linux user (for example: aev)."
fi

if ! id -u "$LOCAL_USER" >/dev/null 2>&1; then
  LOCAL_HOME="/home/$LOCAL_USER"
  log "Creating user '$LOCAL_USER' for user-scoped install steps."
  useradd -m -d "$LOCAL_HOME" -U -s /bin/bash "$LOCAL_USER"
fi

LOCAL_HOME="$(resolve_user_home "$LOCAL_USER")"
DROPBOX_USER="${DROPBOX_USER:-$LOCAL_USER}"
refresh_runtime_paths
log "Running in root mode. User-scoped commands will run as '$LOCAL_USER' via su."

if [[ "$INSTALL_DROPBOX" == "y" ]]; then
  existing_prefix="/"
  existing_sync=""
  if [[ -f "$ENV_FILE" ]]; then
    existing_prefix="$(read_config_value "PREFIX_PATH" "$ENV_FILE")"
    existing_sync="$(read_config_value "SYNC_FOLDERS" "$ENV_FILE")"
  fi

  prompt_for_prefix_path "${existing_prefix:-/}"
  SYNC_FOLDERS="$(prompt "SYNC_FOLDERS (comma-separated relative folder paths to sync; empty = unchanged)" "${existing_sync:-}")"
  install_and_configure_dropbox
fi

INSTALL_CODE_SERVER="n"
if prompt_yes_no "Install/keep code-server (system-wide)?" "n"; then
  INSTALL_CODE_SERVER="y"
fi
if [[ "$INSTALL_CODE_SERVER" == "y" ]]; then
  install_code_server_as_user
else
  log "Skipping code-server installation."
fi

INSTALL_CLAUDE_CODE="n"
if prompt_yes_no "Install Claude Code for user '$LOCAL_USER'?" "n"; then
  INSTALL_CLAUDE_CODE="y"
fi
if [[ "$INSTALL_CLAUDE_CODE" == "y" ]]; then
  install_claude_code_as_user
else
  log "Skipping Claude Code installation."
fi

INSTALL_CODEX_EXTENSION="n"
if prompt_yes_no "Install Codex extension in code-server for user '$LOCAL_USER'?" "n"; then
  INSTALL_CODEX_EXTENSION="y"
fi
if [[ "$INSTALL_CODEX_EXTENSION" == "y" ]]; then
  CODEX_EXTENSION_ID="$(prompt "CODEX_EXTENSION_ID" "${CODEX_EXTENSION_ID:-openai.chatgpt}")"
  CODEX_EXTENSION_ID="$(trim "$CODEX_EXTENSION_ID")"
  install_codex_extension_as_user
else
  log "Skipping Codex extension installation."
fi

INSTALL_PYTHON_EXTENSION="n"
if prompt_yes_no "Enable Python support in code-server for user '$LOCAL_USER'?" "n"; then
  INSTALL_PYTHON_EXTENSION="y"
fi
if [[ "$INSTALL_PYTHON_EXTENSION" == "y" ]]; then
  install_python_extension_as_user
else
  log "Skipping Python extension installation."
fi

download_update_script_as_user

if [[ "$INSTALL_DROPBOX" == "y" ]]; then
  cat <<EOF
SCRIPT_MARKER: tailscale

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
  $HOME_DIR/.local/bin/update-codedrop-sync-lxc.sh

If you installed Tailscale, bring it online with:
  tailscale up

EOF
else
  cat <<EOF
SCRIPT_MARKER: tailscale

Install complete.

Dropbox installation was skipped by choice.
Re-run this installer any time and answer "yes" to install Dropbox later.
Update helper script is available at:
  $HOME_DIR/.local/bin/update-codedrop-sync-lxc.sh

If you installed Tailscale, bring it online with:
  tailscale up

EOF
fi
