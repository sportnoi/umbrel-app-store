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

That single directory is the whole backup. To take one:

```sh
sudo sqlite3 /home/umbrel/umbrel/app-data/finance-casa/data/finance.db \
  ".backup '/home/umbrel/finance-casa-$(date +%F).db'"
```

Prefer `.backup` over copying the file while the app is running — two
containers hold the database open concurrently.

## Telegram bot token

umbrelOS has no UI for per-app secrets. After installing, create
`/home/umbrel/umbrel/app-data/finance-casa/.env`:

```
TELEGRAM_BOT_TOKEN=123456789:AAaBbCc...
```

then restart the app from the dashboard. Compose reads `.env` from the app's
data directory. Until the token is set, the `telegram-bot` container restarts in
a loop — harmless, and the web UI is unaffected. Delete the `telegram-bot`
service from `docker-compose.yml` if you do not want the bot at all.

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

1. Push new images from the app repo.
2. Bump `version:` and `releaseNotes:` in `finance-casa/umbrel-app.yml`.
3. Bump the three image tags in `finance-casa/docker-compose.yml`.
4. Commit and push. Umbrel picks up the update on its next store refresh.
