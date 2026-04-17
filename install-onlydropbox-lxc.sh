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
  if [[ "${ONLYDROPBOX_AS_USER:-}" == "1" ]]; then
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
      script_target="/tmp/install-onlydropbox-lxc.sh"
      log "Copying installer to $script_target so '$dropbox_user' can execute it."
      cp "$script_source" "$script_target"
      chown "$dropbox_user":"$dropbox_user" "$script_target"
      chmod 755 "$script_target"
    fi

    log "Re-running installer as '$dropbox_user'."
    exec runuser -u "$dropbox_user" -- env \
      ONLYDROPBOX_AS_USER=1 \
      DROPBOX_USER="$dropbox_user" \
      HOME="$dropbox_home" \
      LC_ALL=C \
      bash "$script_target"
  fi

  script_target="/tmp/install-onlydropbox-lxc.sh"
  log "runuser not found; using su. Copying installer to $script_target."
  cp "$script_source" "$script_target"
  chown "$dropbox_user":"$dropbox_user" "$script_target"
  chmod 755 "$script_target"
  exec su - "$dropbox_user" -c "ONLYDROPBOX_AS_USER=1 DROPBOX_USER='$dropbox_user' LC_ALL=C bash '$script_target'"
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
  local log_file="/tmp/onlydropbox-dropboxd.log"
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

start_dropbox_daemon() {
  if pgrep -f "$DROPBOX_DAEMON" >/dev/null 2>&1; then
    log "Dropbox daemon is already running."
    return 0
  fi

  log "Starting Dropbox daemon in background."
  nohup "$DROPBOX_DAEMON" >/tmp/onlydropbox-dropboxd.log 2>&1 &
  sleep 4

  if pgrep -f "$DROPBOX_DAEMON" >/dev/null 2>&1; then
    log "Dropbox daemon started."
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

if [[ "${EUID}" -eq 0 && "${ONLYDROPBOX_AS_USER:-}" != "1" ]]; then
  log "Installing minimal baseline packages."
  run_privileged apt-get update
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    libatomic1 \
    libglib2.0-0 \
    libstdc++6 \
    tar \
    python3 \
    procps

  prompt_for_dropbox_user
  reexec_as_dropbox_user
fi

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

start_dropbox_daemon

status_out="$("$DROPBOX_CLI" status 2>&1 || true)"
if [[ "$status_out" == *"not linked"* || "$status_out" == *"This computer isn't linked"* || "$status_out" == *"isn't linked to any Dropbox account"* || "$status_out" == *"Please visit "*"/cli_link_nonce"* ]]; then
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
  error "Dropbox daemon did not become ready. Check /tmp/onlydropbox-dropboxd.log and run '$DROPBOX_CLI status'."
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
