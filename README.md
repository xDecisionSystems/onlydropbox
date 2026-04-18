# Codedrop

Codedrop provides two ways to run Dropbox with selective sync:

- Docker mode (`docker-compose.yml`)
- LXC interactive installer (`install-codedrop-lxc.sh`)

Selective sync is controlled by:

- `PREFIX_PATH`: base Dropbox path (default `/`)
- `SYNC_FOLDERS`: comma-separated allow-list of first-level folder names under `PREFIX_PATH`

If `SYNC_FOLDERS` is empty, selective sync is left unchanged.

## Docker Quick Start

1. Copy env template:

```bash
cp .env.example .env
```

2. Edit `.env`:

```dotenv
PREFIX_PATH=/Team
SYNC_FOLDERS=Work,Photos,Taxes
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
wget -O install-codedrop-lxc.sh https://raw.githubusercontent.com/xDecisionSystems/codedrop/main/install-codedrop-lxc.sh
chmod +x install-codedrop-lxc.sh
./install-codedrop-lxc.sh
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
- prompts for `PREFIX_PATH` and `SYNC_FOLDERS`
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

## Notes

- LXC mode stores Dropbox state in the selected user home (example: `/home/dropbox/.dropbox`).
- `PREFIX_PATH` can be `/`, `/Team`, or `Team/Clients`.
- Folder names in `SYNC_FOLDERS` are first-level names within `PREFIX_PATH`; each selected folder syncs recursively.
- Spaces around commas are allowed.
- Example for path `UCF Dropbox/Bob Jones/`:
  - `PREFIX_PATH="UCF Dropbox/Bob Jones"`
  - `SYNC_FOLDERS="Research Docs,Class Materials"`

## Build and Push (Docker Hub)

Set `REPO` and `VERSION` in `build-and-push.sh`, then run:

```bash
./build-and-push.sh
```
