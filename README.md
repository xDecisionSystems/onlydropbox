# Headless Dropbox Docker

This project runs Dropbox in a container and applies selective sync based on `PREFIX_PATH` + `SYNC_FOLDERS`.

## Behavior

- `PREFIX_PATH` selects the base Dropbox path for selective sync (default `/`).
- `SYNC_FOLDERS` is a comma-separated allow-list of first-level folder names inside `PREFIX_PATH`.
- On startup, the container:
  1. starts Dropbox daemon,
  2. reads folder list under `PREFIX_PATH`,
  3. excludes every folder not listed in `SYNC_FOLDERS`,
  4. ensures listed folders are included (including all subdirectories).

If `SYNC_FOLDERS` is empty, selective sync is left unchanged.

## Quick Start

1. Copy env template:

```bash
cp .env.example .env
```

2. Edit `.env` and set path + folder list:

```dotenv
PREFIX_PATH=/Team
SYNC_FOLDERS=Work,Photos,Taxes
```

3. Start container:

```bash
docker compose up -d --build
```

4. First run only: link Dropbox account.

Check logs and open the Dropbox linking URL shown by the daemon:

```bash
docker logs -f codedrop
```

After linking, restart once:

```bash
docker compose restart
```

## LXC Interactive Install

Inside a Debian/Ubuntu LXC container, you can run the interactive installer. It:

- installs a minimal package baseline,
- prompts for `DROPBOX_USER` (valid Linux username),
- creates/reuses that user,
- runs Dropbox as that user (not root),
- asks for `PREFIX_PATH` and `SYNC_FOLDERS`,
- installs headless Dropbox directly (no Docker),
- starts the Dropbox daemon, and applies selective sync settings.

If you already cloned this repo:

```bash
chmod +x install-codedrop-lxc.sh
./install-codedrop-lxc.sh
```

If you only want to download and run the script:

```bash
wget -O install-codedrop-lxc.sh https://raw.githubusercontent.com/xdecisionsystems/codedrop/main/install-codedrop-lxc.sh
chmod +x install-codedrop-lxc.sh
./install-codedrop-lxc.sh
```

To update selective sync later (without reinstalling), run:

```bash
chmod +x update-codedrop-sync-lxc.sh
./update-codedrop-sync-lxc.sh
```

## Volumes

- `./data/dropbox-config` -> `/root/.dropbox` (account/config)
- `./data/dropbox-sync` -> `/root/Dropbox` (synced files)

## Notes

- In LXC install mode, Dropbox state lives under the selected user's home (for example `/home/dropbox/.dropbox`), not `/root`.
- `PREFIX_PATH` can be `/`, `/Team`, or `Team/Clients` (leading/trailing `/` optional).
- Folder names in `SYNC_FOLDERS` are first-level names within `PREFIX_PATH`; each selected folder syncs recursively.
- Spaces around commas are allowed.
- Changing `SYNC_FOLDERS` requires container restart to re-apply exclusions.
- For institutional/team accounts with spaces in folder names, use exact names and wrap values in quotes.
- Example for Dropbox path `UCF Dropbox/Bob Jones/`:
  - `PREFIX_PATH="UCF Dropbox/Bob Jones"`
  - `SYNC_FOLDERS="Research Docs,Class Materials"`

## Build and Push (Docker Hub)

Set `REPO` and `VERSION` inside [build-and-push.sh], then run:

```bash
./build-and-push.sh
```
