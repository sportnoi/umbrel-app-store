# Finance Casa App Store

A private [Umbrel](https://umbrel.com) community app store for **Finance Casa**,
a self-hosted home finance tracker. Targets **umbrelOS 1.7.4**.

## Install

On your Umbrel: **App Store → ⋯ (top right) → Community App Stores**, then add:

```
https://github.com/sportnoi/umbrel-app-store
```

"Finance Casa" then appears under the store and installs like any other app.

## Layout

```
umbrel-app-store.yml          store manifest (id: finance)
finance-casa/
  umbrel-app.yml              app manifest (id: finance-casa)
  docker-compose.yml          web + api + db
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
| `web` (Next.js) | `ghcr.io/sportnoi/home-finance-tracker-frontend` | app_proxy only |
| `api` (Python) | `ghcr.io/sportnoi/home-finance-tracker-backend` | `web` only — no host port |
| `db` (PostgreSQL 16) | `postgres:16.4-alpine` (digest-pinned) | `api` only — no host port |

## Data

Everything persists under the app's data directory on the Umbrel host
(`${APP_DATA_DIR}` → `/home/umbrel/umbrel/app-data/finance-casa`):

```
data/postgres/     PostgreSQL cluster
data/uploads/      receipts and imported statements
data/web-cache/    Next.js cache (disposable)
```

`data/postgres` and `data/uploads` are the two directories worth backing up.

## Images must be pre-built

umbrelOS does **not** run `docker build` — it only pulls images. Publish both
images from the app repo before bumping `version:` here, e.g.:

```yaml
# .github/workflows/release.yml in sportnoi/home-finance-tracker
- uses: docker/build-push-action@v6
  with:
    context: ./frontend
    push: true
    tags: ghcr.io/sportnoi/home-finance-tracker-frontend:${{ github.ref_name }}
```

Make the GHCR packages **public**, otherwise the Umbrel host cannot pull them.

Pinning by digest (`image@sha256:…`) is recommended for the app images too, as
already done for `postgres`.

## Nginx Proxy Manager

`PROXY_AUTH_ADD: "false"` is set on `app_proxy` so Umbrel's own auth layer does
not sit in front of the app — that layer misbehaves behind an external reverse
proxy. Point an NPM proxy host at:

```
Forward Hostname/IP: <your Umbrel LAN IP>
Forward Port:        3333
Websockets Support:  enabled
```

Enable **Block Common Exploits** and put an SSL certificate on it. Because
Umbrel's auth is off, Finance Casa's own login is the only gate — do not expose
it publicly until that is verified.

## Updating the app

1. Push new images from the app repo.
2. Bump `version:` and `releaseNotes:` in `finance-casa/umbrel-app.yml`.
3. Bump the image tags in `finance-casa/docker-compose.yml`.
4. Commit and push. Umbrel picks up the update on its next store refresh.
