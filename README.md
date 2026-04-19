# Codedrop

Codedrop is an LXC-focused installer for Dropbox selective sync.

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
