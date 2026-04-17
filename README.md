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
docker logs -f onlydropbox
```

After linking, restart once:

```bash
docker compose restart
```

## LXC Interactive Install

Inside a Debian/Ubuntu LXC container, you can run the interactive installer. It asks for `PREFIX_PATH` and `SYNC_FOLDERS`, writes `.env`, installs Docker if needed, and starts `onlydropbox`.

If you already cloned this repo:

```bash
chmod +x install-onlydropbox-lxc.sh
./install-onlydropbox-lxc.sh
```

If you only want to download and run the script:

```bash
curl -A "Mozilla/5.0" -L -o install-onlydropbox-lxc.sh https://raw.githubusercontent.com/xDecisionSystems/onlydropbox/main/install-onlydropbox-lxc.sh
chmod +x install-onlydropbox-lxc.sh
./install-onlydropbox-lxc.sh
```

## Volumes

- `./data/dropbox-config` -> `/root/.dropbox` (account/config)
- `./data/dropbox-sync` -> `/root/Dropbox` (synced files)

## Notes

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
