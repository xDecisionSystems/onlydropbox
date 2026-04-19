# Codedrop

Codedrop provides two ways to run Dropbox with selective sync:

- Docker mode (`docker-compose.yml`)
- LXC interactive installer (`install-codedrop-lxc.sh`)

Selective sync inputs:

- Docker mode: `ACCOUNT_ROOT` + `ACCOUNT_NAME` + `SYNC_FOLDERS`
- LXC mode: `PREFIX_PATH` + `SYNC_FOLDERS`

In Docker mode, `SYNC_FOLDERS` is interpreted relative to `ACCOUNT_ROOT/ACCOUNT_NAME`.
If `SYNC_FOLDERS` is empty, selective sync is left unchanged.

## Docker Quick Start

1. Copy env template:

```bash
cp .env.example .env
```

2. Edit `.env`:

```dotenv
PUID=1000
PGID=1000
ACCOUNT_ROOT=UCF Dropbox
ACCOUNT_NAME=John Doe
SYNC_FOLDERS=Apps/Overleaf,Research/Papers
```

3. Start:

```bash
docker compose up -d --build
```

4. Link Dropbox account on first run:

```bash
docker logs -f codedrop
```

After linking, restart once:

```bash
docker compose restart
```

## LXC Interactive Installer

Run inside a Debian/Ubuntu LXC container.

```bash
chmod +x install-codedrop-lxc.sh
./install-codedrop-lxc.sh
```

Or download and run it directly:

```bash
wget -O install-codedrop-lxc.sh https://raw.githubusercontent.com/xDecisionSystems/codedrop/main/install-codedrop-lxc.sh && chmod +x install-codedrop-lxc.sh && ./install-codedrop-lxc.sh
```

The installer is re-runnable and asks what to install each run.

### What It Can Install

- Optional Dropbox (headless daemon + selective sync)
- code-server
- Claude Code CLI
- Claude code-server extension (`anthropic.claude-code`) when Claude CLI is installed and code-server exists
- Codex code-server extension (default ID `openai.chatgpt`, configurable)
- Python extension (`ms-python.python`)
- LaTeX extension (`mathematic.vscode-latex`)

If LaTeX support is selected, prerequisites are installed in root mode:

- `latexindent.pl` (`texlive-extra-utils`)
- `cpanm` (`cpanminus`)
- `chktex`

## Dropbox in LXC

When Dropbox install is selected, the installer:

- prompts for `DROPBOX_USER`
- creates/reuses that user
- runs Dropbox as that user (not root)
- prompts for `ACCOUNT_TYPE` (`personal` or `organization`)
- prompts for `ACCOUNT_ROOT` (for example `Dropbox` or `UCF Dropbox`)
- prompts for `ACCOUNT_NAME` (for example `Jane Doe`)
- prompts for optional `ACCOUNT_SUBPATH`
- builds `PREFIX_PATH` from account prompts, then prompts for `SYNC_FOLDERS`
- saves config to `~/.config/codedrop/codedrop.env`
- uses existing values from that file as defaults on future runs
- starts Dropbox and applies selective sync

If Dropbox is skipped, the script still completes and you can install Dropbox in a later run.

## Update Selective Sync Later

Use the helper script to update `PREFIX_PATH`/`SYNC_FOLDERS` and reapply selective sync without reinstalling:

```bash
chmod +x update-codedrop-sync-lxc.sh
./update-codedrop-sync-lxc.sh
```

This script reads/writes:

- `~/.config/codedrop/codedrop.env`

## Check Status and Excludes

Run as the Dropbox user:

```bash
su - <dropbox_user> -c '~/.local/bin/dropbox status'
su - <dropbox_user> -c '~/.local/bin/dropbox exclude list'
```

Important: wait until `dropbox status` is no longer showing active indexing/sync startup states before running other Dropbox commands (for example `exclude list`, `exclude add`, or `exclude remove`).

## Notes

- LXC mode stores Dropbox state in the selected user home (example: `/home/dropbox/.dropbox`).
- `PREFIX_PATH` can be `/`, `/Team`, or `Team/Clients`.
- Entries in `SYNC_FOLDERS` are relative paths within `PREFIX_PATH`; nested paths are supported and each selected path syncs recursively.
- Spaces around commas are allowed.
- Example for path `UCF Dropbox/Bob Jones/`:
  - `PREFIX_PATH="UCF Dropbox/Bob Jones"`
  - `SYNC_FOLDERS="Research Docs,Class Materials"`

## Build and Push (Docker Hub)

Set `REPO` and `VERSION` in `build-and-push.sh`, then run:

```bash
./build-and-push.sh
```
