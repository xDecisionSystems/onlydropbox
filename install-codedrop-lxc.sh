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

download_update_script_as_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    error "Update script download must run as a non-root user."
  fi

  local update_script_url="https://raw.githubusercontent.com/xDecisionSystems/codedrop/main/update-codedrop-sync-lxc.sh"
  local target_dir="$HOME/.local/bin"
  local target_file="$target_dir/update-codedrop-sync-lxc.sh"

  mkdir -p "$target_dir"

  log "Downloading update helper script to $target_file"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$update_script_url" -o "$target_file"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$target_file" "$update_script_url"
  else
    error "Neither curl nor wget is available to download update-codedrop-sync-lxc.sh."
  fi

  chmod +x "$target_file"
}

install_code_server_as_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    error "code-server installation must run as a non-root user."
  fi

  if command -v code-server >/dev/null 2>&1; then
    log "code-server is already installed for user '$USER'."
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required to install code-server. Re-run as root so prerequisites can be installed."
  fi

  log "Installing code-server for user '$USER'."
  curl -fsSL https://code-server.dev/install.sh | sh
}

install_claude_code_as_user() {
  local claude_extension_id="anthropic.claude-code"

  if [[ "${EUID}" -eq 0 ]]; then
    error "Claude Code installation must run as a non-root user."
  fi

  if command -v claude >/dev/null 2>&1; then
    log "Claude Code is already installed for user '$USER'."
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required to install Claude Code. Re-run as root so prerequisites can be installed."
  fi

  log "Installing Claude Code for user '$USER'."
  curl -fsSL https://claude.ai/install.sh | bash

  if ! command -v code-server >/dev/null 2>&1; then
    log "code-server not found; skipping Claude extension '$claude_extension_id' installation."
    return 0
  fi

  if code-server --list-extensions 2>/dev/null | grep -Fxq "$claude_extension_id"; then
    log "Claude extension '$claude_extension_id' is already installed for user '$USER'."
    return 0
  fi

  log "Installing Claude extension '$claude_extension_id' for user '$USER'."
  code-server --install-extension "$claude_extension_id"
}

install_codex_extension_as_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    error "Codex extension installation must run as a non-root user."
  fi

  if ! command -v code-server >/dev/null 2>&1; then
    error "code-server is required to install a Codex extension. Install code-server and re-run the installer."
  fi

  if [[ -z "${CODEX_EXTENSION_ID:-}" ]]; then
    error "CODEX_EXTENSION_ID is required to install the Codex extension."
  fi

  if code-server --list-extensions 2>/dev/null | grep -Fxq "$CODEX_EXTENSION_ID"; then
    log "Codex extension '$CODEX_EXTENSION_ID' is already installed for user '$USER'."
    return 0
  fi

  log "Installing Codex extension '$CODEX_EXTENSION_ID' for user '$USER'."
  code-server --install-extension "$CODEX_EXTENSION_ID"
}

install_python_extension_as_user() {
  local python_extension_id="ms-python.python"

  if [[ "${EUID}" -eq 0 ]]; then
    error "Python extension installation must run as a non-root user."
  fi

  if ! command -v code-server >/dev/null 2>&1; then
    error "code-server is required to install the Python extension. Install code-server and re-run the installer."
  fi

  if code-server --list-extensions 2>/dev/null | grep -Fxq "$python_extension_id"; then
    log "Python extension '$python_extension_id' is already installed for user '$USER'."
    return 0
  fi

  log "Installing Python extension '$python_extension_id' for user '$USER'."
  code-server --install-extension "$python_extension_id"
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

  if [[ "${EUID}" -eq 0 ]]; then
    error "LaTeX support installation must run as a non-root user."
  fi

  if ! command -v code-server >/dev/null 2>&1; then
    error "code-server is required to install LaTeX support. Install code-server and re-run the installer."
  fi

  install_latex_prereqs_as_root

  if code-server --list-extensions 2>/dev/null | grep -Fxq "$latex_extension_id"; then
    log "LaTeX extension '$latex_extension_id' is already installed for user '$USER'."
  else
    log "Installing LaTeX extension '$latex_extension_id' for user '$USER'."
    code-server --install-extension "$latex_extension_id"
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

reexec_as_dropbox_user() {
  if [[ "${EUID}" -ne 0 ]]; then
    return 0
  fi
  if [[ "${CODEDROP_AS_USER:-}" == "1" ]]; then
    return 0
  fi

  local dropbox_user="${DROPBOX_USER:-dropbox}"
  local dropbox_home
  local script_source
  local script_target

  if ! is_valid_unix_username "$dropbox_user"; then
    error "Invalid DROPBOX_USER '$dropbox_user'."
  fi

  if id -u "$dropbox_user" >/dev/null 2>&1; then
    dropbox_home="$(getent passwd "$dropbox_user" | cut -d: -f6)"
    dropbox_home="${dropbox_home:-/home/$dropbox_user}"
  else
    dropbox_home="/home/$dropbox_user"
  fi

  script_source="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if ! id -u "$dropbox_user" >/dev/null 2>&1; then
    log "Creating dedicated user '$dropbox_user'."
    useradd -m -d "$dropbox_home" -U -s /bin/bash "$dropbox_user"
  else
    log "Using existing user '$dropbox_user'."
  fi

  script_target="$script_source"
  if command -v runuser >/dev/null 2>&1; then
    if ! runuser -u "$dropbox_user" -- test -r "$script_target" >/dev/null 2>&1; then
      script_target="/tmp/install-codedrop-lxc.sh"
      log "Copying installer to $script_target so '$dropbox_user' can execute it."
      cp "$script_source" "$script_target"
      chown "$dropbox_user":"$dropbox_user" "$script_target"
      chmod 755 "$script_target"
    fi

    log "Re-running installer as '$dropbox_user'."
    exec runuser -u "$dropbox_user" -- env \
      CODEDROP_AS_USER=1 \
      INSTALL_DROPBOX="${INSTALL_DROPBOX:-n}" \
      DROPBOX_USER="$dropbox_user" \
      HOME="$dropbox_home" \
      LC_ALL=C \
      bash "$script_target"
  fi

  script_target="/tmp/install-codedrop-lxc.sh"
  log "runuser not found; using su. Copying installer to $script_target."
  cp "$script_source" "$script_target"
  chown "$dropbox_user":"$dropbox_user" "$script_target"
  chmod 755 "$script_target"
  exec su - "$dropbox_user" -c "CODEDROP_AS_USER=1 INSTALL_DROPBOX='${INSTALL_DROPBOX:-n}' DROPBOX_USER='$dropbox_user' LC_ALL=C bash '$script_target'"
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

wait_for_dropbox_ready() {
  local max_wait=300
  local elapsed=0
  local status
  local last_status=""
  local last_reported=-1

  log "Waiting for Dropbox daemon to initialize..."
  while (( elapsed < max_wait )); do
    status="$("$DROPBOX_CLI" status 2>/dev/null || true)"

    case "$status" in
      *"Up to date"*|*"Syncing"*|*"Connecting"*|*"Downloading"*|*"Indexing"*)
        log "Dropbox is responding: $status"
        return 0
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

  log "Dropbox did not become ready in ${max_wait}s. Current status: $("$DROPBOX_CLI" status 2>/dev/null || true)"
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
  nohup "$DROPBOX_DAEMON" >/tmp/codedrop-dropboxd.log 2>&1 &
  sleep 4

  if pgrep -f "$DROPBOX_DAEMON" >/dev/null 2>&1; then
    log "Dropbox daemon started."
    return 0
  fi

  status="$("$DROPBOX_CLI" status 2>&1 || true)"
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
CONFIG_DIR="$HOME_DIR/.config/codedrop"
ENV_FILE="$CONFIG_DIR/codedrop.env"
DROPBOX_DIST_DIR="$HOME_DIR/.dropbox-dist"
DROPBOX_DAEMON="$DROPBOX_DIST_DIR/dropboxd"
DROPBOX_CLI="$HOME_DIR/.local/bin/dropbox"
DROPBOX_DOWNLOAD_URL="https://www.dropbox.com/download?plat=lnx.x86_64"
DROPBOX_CLI_URL="https://www.dropbox.com/download?dl=packages/dropbox.py"

if ! command -v apt-get >/dev/null 2>&1; then
  error "apt-get not found. This installer currently supports Debian/Ubuntu-based LXC containers."
fi

INSTALL_DROPBOX="${INSTALL_DROPBOX:-n}"
if prompt_yes_no "Install Dropbox (headless daemon + selective sync)?" "${INSTALL_DROPBOX}"; then
  INSTALL_DROPBOX="y"
else
  INSTALL_DROPBOX="n"
fi

if [[ "${EUID}" -eq 0 && "${CODEDROP_AS_USER:-}" != "1" ]]; then
  log "Installing minimal baseline packages."
  run_privileged apt-get update
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    tar \
    python3 \
    procps

  if [[ "$INSTALL_DROPBOX" == "y" ]]; then
    log "Installing Dropbox prerequisites."
    run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      wget \
      libatomic1 \
      libglib2.0-0 \
      libstdc++6
  fi

  prompt_for_dropbox_user
  reexec_as_dropbox_user
fi

INSTALL_CODE_SERVER="n"
if prompt_yes_no "Install code-server for user '$USER'?" "n"; then
  INSTALL_CODE_SERVER="y"
fi
if [[ "$INSTALL_CODE_SERVER" == "y" ]]; then
  install_code_server_as_user
else
  log "Skipping code-server installation."
fi

INSTALL_CLAUDE_CODE="n"
if prompt_yes_no "Install Claude Code for user '$USER'?" "n"; then
  INSTALL_CLAUDE_CODE="y"
fi
if [[ "$INSTALL_CLAUDE_CODE" == "y" ]]; then
  install_claude_code_as_user
else
  log "Skipping Claude Code installation."
fi

INSTALL_CODEX_EXTENSION="n"
if prompt_yes_no "Install Codex extension in code-server for user '$USER'?" "n"; then
  INSTALL_CODEX_EXTENSION="y"
fi
if [[ "$INSTALL_CODEX_EXTENSION" == "y" ]]; then
  CODEX_EXTENSION_ID="$(prompt "CODEX_EXTENSION_ID (VS Code extension id, e.g. publisher.extension)" "${CODEX_EXTENSION_ID:-openai.chatgpt}")"
  CODEX_EXTENSION_ID="$(trim "$CODEX_EXTENSION_ID")"
  if [[ -z "$CODEX_EXTENSION_ID" ]]; then
    error "CODEX_EXTENSION_ID cannot be empty when Codex extension installation is selected."
  fi
  install_codex_extension_as_user
else
  log "Skipping Codex extension installation."
fi

INSTALL_PYTHON_EXTENSION="n"
if prompt_yes_no "Enable Python support in code-server for user '$USER'?" "n"; then
  INSTALL_PYTHON_EXTENSION="y"
fi
if [[ "$INSTALL_PYTHON_EXTENSION" == "y" ]]; then
  install_python_extension_as_user
else
  log "Skipping Python extension installation."
fi

INSTALL_LATEX_SUPPORT="n"
if prompt_yes_no "Enable LaTeX formatting in code-server for user '$USER'?" "n"; then
  INSTALL_LATEX_SUPPORT="y"
fi
if [[ "$INSTALL_LATEX_SUPPORT" == "y" ]]; then
  install_latex_support_as_user
else
  log "Skipping LaTeX support installation."
fi

download_update_script_as_user

if [[ "$INSTALL_DROPBOX" == "y" ]]; then
  existing_prefix="/"
  existing_sync=""
  if [[ -f "$ENV_FILE" ]]; then
    existing_prefix="$(read_config_value "PREFIX_PATH" "$ENV_FILE")"
    existing_sync="$(read_config_value "SYNC_FOLDERS" "$ENV_FILE")"
  fi

  PREFIX_PATH="$(prompt "PREFIX_PATH (Dropbox base path)" "${existing_prefix:-/}")"
  SYNC_FOLDERS="$(prompt "SYNC_FOLDERS (comma-separated first-level folders to sync; empty = unchanged)" "${existing_sync:-}")"

  mkdir -p "$CONFIG_DIR" "$HOME_DIR/.local/bin"

  cat > "$ENV_FILE" <<EOF
# Generated by install-codedrop-lxc.sh on $(date '+%Y-%m-%d %H:%M:%S')
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
    wget -qO "$TMP_TAR" "$DROPBOX_DOWNLOAD_URL"
    tar -xzf "$TMP_TAR" -C "$HOME_DIR"
    rm -f "$TMP_TAR"
  fi

  if [[ ! -f "$DROPBOX_CLI" ]]; then
    log "Installing Dropbox CLI to $DROPBOX_CLI"
    wget -qO "$DROPBOX_CLI" "$DROPBOX_CLI_URL"
    chmod +x "$DROPBOX_CLI"
  fi

  start_dropbox_daemon

  status_out="$("$DROPBOX_CLI" status 2>&1 || true)"
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

After linking completes, re-run this installer to apply selective sync using:
  PREFIX_PATH=$PREFIX_PATH
  SYNC_FOLDERS=$SYNC_FOLDERS

EOF
    exit 0
  fi

  if wait_for_dropbox_ready; then
    configure_selective_sync
  else
    wait_rc=$?
    if [[ "$wait_rc" -eq 10 ]]; then
      cat <<EOF

Dropbox needs linking before selective sync can be applied.
Run:
  $DROPBOX_CLI start -i

After linking completes, re-run this installer.

EOF
      exit 0
    fi
    tail_daemon_log
    diagnose_dropbox_runtime
    error "Dropbox daemon did not become ready. Check /tmp/codedrop-dropboxd.log and run '$DROPBOX_CLI status'."
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
else
  cat <<EOF

Install complete.

Dropbox installation was skipped by choice.
Re-run this installer any time and answer "yes" to install Dropbox later.

EOF
fi
