# Finance Casa App Store

A private [Umbrel](https://umbrel.com) community app store for **Finance Casa**,
a self-hosted home finance tracker. Targets **umbrelOS 1.7.4**.

App source: [sportnoi/home-finance-tracker](https://github.com/sportnoi/home-finance-tracker)

## Install

On your Umbrel: **App Store → ⋯ (top right) → Community App Stores**, then add:

```
https://github.com/sportnoi/umbrel-app-store
```

"Finance Casa" then appears under the store and installs like any other app.

> The repository must be **publicly readable** — Umbrel clones community stores
> unauthenticated and cannot use your GitHub credentials.

## Layout

```
umbrel-app-store.yml          store manifest (id: finance)
finance-casa/
  umbrel-app.yml              app manifest (id: finance-casa)
  docker-compose.yml          frontend + backend + telegram-bot
  icon.svg                    app icon
  gallery/                    store screenshots (1.jpg, 2.jpg, 3.jpg)
```

> **Naming:** umbrelOS requires each app's `id` and directory to be prefixed
> with the store `id`. Store `finance` + app `casa` gives `finance-casa`, so the
> directory is `finance-casa/` rather than `finance-app/`.

## Architecture

| Service | Image | Reachable from |
|---|---|---|
| `app_proxy` | Umbrel built-in | Host `:3333` |
| `frontend` (Next.js, :3000) | `localhost:5000/home-finance-tracker-frontend` | app_proxy only |
| `backend` (`server.py`, :8080) | `localhost:5000/home-finance-tracker-backend` | `frontend` only — no host port |
| `telegram-bot` | `localhost:5000/home-finance-tracker-telegram-bot` | internal only |

### Differences from the app repo's `docker-compose.yml`

| Upstream | Here | Why |
|---|---|---|
| `build:` from local context | `image:` from a local registry mirror | umbrelOS pulls images, it never builds |
| `ports: ["${FRONTEND_PORT}:3000"]` | no `ports:` | `port: 3333` in `umbrel-app.yml` publishes it via `app_proxy` |
| `container_name: finance-*` | removed | umbrelOS names containers `finance-casa_<service>_1`; `app_proxy` cannot find the app otherwise |
| `networks: finance_net` | removed | umbrelOS manages the app network and puts `app_proxy` on it |
| `./data:/data` | `${APP_DATA_DIR}/data:/data` | same directory, addressed the way Umbrel expects |
| `restart: unless-stopped` | `restart: on-failure` | Umbrel's convention, so it honours a stopped app |
| plain `depends_on` | `depends_on` + backend healthcheck | ordering that waits for the port to actually accept connections |

`BACKEND_URL=http://backend:8080` and `FINANCE_DB_PATH=/data/finance.db` are
unchanged from upstream.

## Data

Everything lives in one directory on the Umbrel host — `${APP_DATA_DIR}/data`,
i.e. `/home/umbrel/umbrel/app-data/finance-casa/data`, containing `finance.db`.
Both `backend` and `telegram-bot` bind-mount it at `/data`, matching upstream.

### Ownership

The backend runs as `appuser` (uid 1000). A bind-mount source that does not
exist is created by Docker as **root-owned**, which leaves the container unable
to write and crashing on start. So `data/` and `finance.db` must be owned by
uid 1000:

```sh
sudo mkdir -p /home/umbrel/umbrel/app-data/finance-casa/data
sudo chown -R 1000:1000 /home/umbrel/umbrel/app-data/finance-casa/data
```

The backend image cannot create a schema from scratch — `setup_database.py` and
`migrate_multiuser.py` are excluded from it by the app repo's `.dockerignore`,
so `categories`, `expenses` and `users` are never created. A fresh install
therefore needs an existing `finance.db` copied in **before** first start.

### Backup

Do **not** plain-copy `finance.db` while the app runs — the backend and the
Telegram bot both hold it open, and you can capture a torn file. Use the
sqlite3 backup API, which is safe against concurrent writers:

```sh
sudo sh scripts/backup-finance-casa.sh
```

It writes `/home/umbrel/backups/finance-casa/finance-<timestamp>.db.gz`, keeps
the newest 14 and prunes older ones. Override with `FINANCE_CASA_BACKUP_DIR`
and `FINANCE_CASA_BACKUP_KEEP`.

Copy the script to `/home/umbrel/scripts/` first — the store clone under
`app-stores/` is overwritten on every refresh.

### Scheduling it nightly

umbrelOS ships no `cron`, so use a systemd timer.

```sh
sudo tee /etc/systemd/system/finance-casa-backup.service >/dev/null <<'EOF'
[Unit]
Description=Finance Casa database backup
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh /home/umbrel/scripts/backup-finance-casa.sh
EOF

sudo tee /etc/systemd/system/finance-casa-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Nightly Finance Casa database backup

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now finance-casa-backup.timer
```

`Persistent=true` catches up a run missed while the machine was off.

Check and test:

```sh
systemctl list-timers finance-casa-backup.timer
sudo systemctl start finance-casa-backup.service   # run once, now
journalctl -u finance-casa-backup -n 30 --no-pager
ls -la /home/umbrel/backups/finance-casa/
```

Units in `/etc/systemd/system/` may not survive a umbrelOS update, which
manages its own root filesystem. Re-check `systemctl list-timers` after an OS
upgrade.

Backups on the same disk are not backups. Pull them somewhere else
periodically. Note that scp reads anything before a colon as a hostname, so a
Windows drive path as the destination fails with
`Could not resolve hostname c` — cd to the destination and use `.` instead:

```powershell
cd D:\backups
scp "umbrel@<umbrel-ip>:/home/umbrel/backups/finance-casa/*.db.gz" .
```

Quote the remote side so the glob is expanded by the remote shell rather than
the local one.

If the destination is a cloud-synced folder (Dropbox, OneDrive, iCloud), the
database leaves your machine in readable form — which undoes much of the point
of self-hosting it. Encrypt before it syncs:

```sh
gpg --symmetric --cipher-algo AES256 \
  /home/umbrel/backups/finance-casa/finance-2026-09-03-0330.db.gz
```

and copy only the resulting `.gpg` file.

### Restore

```sh
# stop the app from the dashboard first
gunzip -c /home/umbrel/backups/finance-casa/finance-2026-09-03-0330.db.gz \
  | sudo tee /home/umbrel/umbrel/app-data/finance-casa/data/finance.db >/dev/null
sudo chown 1000:1000 /home/umbrel/umbrel/app-data/finance-casa/data/finance.db
# then start the app
```

Verify a backup is readable without restoring it:

```sh
gunzip -c /home/umbrel/backups/finance-casa/finance-2026-09-03-0330.db.gz > /tmp/check.db
python3 -c "import sqlite3;print(sorted(r[0] for r in sqlite3.connect('/tmp/check.db').execute(\"select name from sqlite_master where type='table'\")))"
rm /tmp/check.db
```

You should see `users`, `expenses`, `categories` and `budgets` among the tables.

## Telegram bot token

umbrelOS has no UI for per-app secrets. Create
`/home/umbrel/umbrel/app-data/finance-casa/.env`:

```sh
sudo tee /home/umbrel/umbrel/app-data/finance-casa/.env >/dev/null <<'EOF'
TELEGRAM_BOT_TOKEN=123456789:AAaBbCc...
EOF
sudo chown 1000:1000 /home/umbrel/umbrel/app-data/finance-casa/.env
sudo chmod 600 /home/umbrel/umbrel/app-data/finance-casa/.env
```

then restart the app.

**The `chown` is not optional.** `sudo tee` creates the file as `root:root`, and
mode 600 then makes it unreadable to anyone else. umbreld runs compose as the
`umbrel` user (uid 1000), and `env_file` is read at config-parse time — so a
root-owned 600 `.env` makes compose fail to parse the whole project. Every
service stops, not just the bot, and an in-flight update hangs part-way. The
symptom is no containers at all plus an app stuck mid-update; the fix is the
`chown` above followed by `sudo systemctl restart umbrel`.

The `telegram-bot` service pulls this in with an explicit
`env_file: ${APP_DATA_DIR}/.env`. Compose's *implicit* `.env` lookup does not
work here: umbreld invokes compose with several `-f` files, including its own
under `/opt/umbreld/source/modules/apps/legacy-compat/`, so the project
directory is not this app's data directory and a `.env` sitting there is never
read. An absolute `env_file` path sidesteps the question entirely.

For the same reason there is no `TELEGRAM_BOT_TOKEN` under the service's
`environment:` key — `environment:` wins over `env_file:`, so a
`${TELEGRAM_BOT_TOKEN:-}` default would resolve to empty and overwrite the real
token.

**The `.env` file must exist before installing**, or the service fails to start
and takes the install with it. If you do not want the bot, either create the
file empty (`sudo touch`) or delete the `telegram-bot` service from
`docker-compose.yml`.

Verify the token actually reached the container:

```sh
sudo docker inspect finance-casa_telegram-bot_1 --format '{{json .Config.Env}}' | tr ',' '\n' | grep TELEGRAM
```

## Images: GHCR build, local mirror

umbrelOS does **not** run `docker build` — it only pulls — so all three images
are built and published by `.github/workflows/publish-images.yml` in the app
repo, tagged from a `v*` git tag.

They are **not** pulled from GHCR by Umbrel, though. umbreld pulls through the
Docker Engine API (`docker-modem`), and unlike the `docker` CLI the Engine API
never reads `~/.docker/config.json` — the CLI attaches credentials as an
`X-Registry-Auth` header per request, and the daemon stores none itself. So a
private GHCR package fails at install with:

```
Error: (HTTP code 401) - Head "https://ghcr.io/v2/sportnoi/home-finance-tracker-frontend/manifests/1.0.0": unauthorized
```

`docker login` on the host does not fix this; it only helps the CLI.

To keep the packages private, the Umbrel host runs its own registry on
`127.0.0.1:5000` and the images are mirrored into it. Docker permits plain HTTP
to `localhost` with no `insecure-registries` entry, and loopback binding keeps
it off the LAN.

### One-time: start the registry

```sh
sudo mkdir -p /home/umbrel/registry-data
sudo docker run -d --name local-registry --restart always \
  -p 127.0.0.1:5000:5000 \
  -v /home/umbrel/registry-data:/var/lib/registry \
  registry:2
```

### Every release: mirror the new images

With the host logged in to GHCR (`docker login ghcr.io -u sportnoi`, classic PAT
with `read:packages`):

```sh
VERSION=1.0.0
for img in backend frontend telegram-bot; do
  sudo docker pull  ghcr.io/sportnoi/home-finance-tracker-$img:$VERSION
  sudo docker tag   ghcr.io/sportnoi/home-finance-tracker-$img:$VERSION \
                    localhost:5000/home-finance-tracker-$img:$VERSION
  sudo docker push  localhost:5000/home-finance-tracker-$img:$VERSION
done
```

Then bump the three tags in `finance-casa/docker-compose.yml` and `version:` in
`umbrel-app.yml`.

Restarts do not need the registry — the images stay in the host's image cache;
only installs and updates pull. Making the GHCR packages public instead would
remove the mirror step entirely, at the cost of publishing the built app.

## Nginx Proxy Manager

`app_proxy` sets `PROXY_AUTH_ADD: "false"` so Umbrel's own auth layer does not
sit in front of the app — that layer misbehaves behind an external reverse
proxy. Point an NPM proxy host at:

```
Forward Hostname/IP: <your Umbrel LAN IP>
Forward Port:        3333
Websockets Support:  enabled
```

Enable **Block Common Exploits** and attach an SSL certificate. Because Umbrel's
auth is off, the app's own login is the only gate — verify it holds before
exposing this beyond your LAN.

Host port 3333 avoids the 3000–3010 / 8080–8099 / 9000 ranges that Umbrel
community apps commonly take. The app repo's `.env.example` defaults to 8347
instead; either is fine, but `port:` in `umbrel-app.yml` is what matters here.

## Updating the app

`/home/umbrel/umbrel/app-data/<app-id>/docker-compose.yml` is **not** the file
in this repo — umbreld renders its own copy at install time (comments stripped,
quoting normalized, `container_name:` injected) and that rendered copy is what
actually runs. Refreshing the store does **not** regenerate it, so a compose
change pushed here has no effect on a running app until umbreld re-renders.

The trigger for a re-render is a version bump:

1. Push new images if the code changed, and mirror them (see above).
2. Bump `version:` and `releaseNotes:` in `finance-casa/umbrel-app.yml` — this
   is what makes the Update button appear, and it is required even when only
   `docker-compose.yml` changed.
3. Bump the image tags in `finance-casa/docker-compose.yml` if they changed.
4. Commit and push. Umbrel notices within ~5 minutes (or `sudo systemctl restart
   umbrel`), then shows **Update** on the app.

Clicking Update re-renders the compose file and restarts the app, preserving
`data/` and `.env`.

To verify a change actually took effect:

```sh
diff /home/umbrel/umbrel/app-stores/sportnoi-umbrel-app-store-github-*/finance-casa/docker-compose.yml \
     /home/umbrel/umbrel/app-data/finance-casa/docker-compose.yml
```

Differences in comments and quoting are expected. Differences in `image:`,
`environment:` or `env_file:` mean the update has not been applied yet.
