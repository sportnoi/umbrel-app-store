# Releasing a new version of Finance Casa

Two repositories and one host are involved, and **the order matters**. Getting it
wrong leaves the app with an Update button that fails halfway and takes the
running containers with it.

```
app repo  ──tag──▶  GitHub Actions  ──push──▶  GHCR
                                                 │
                                     (you, on the Umbrel host)
                                                 ▼
                                    localhost:5000  ──pull──▶  umbreld
                                                 ▲                 │
store repo  ──bump version──────────────────────┘                 ▼
                                                              app running
```

The rule: **images must exist in the host registry before the store version is
bumped.** Umbrel offers the update as soon as it sees the new version, and a
pull failure at that point is not graceful.

---

## Before you start

Confirm the two things that silently rot between releases:

```sh
# 1. The local registry is up
curl -s http://localhost:5000/v2/_catalog

# 2. GHCR credentials still work
sudo docker pull ghcr.io/sportnoi/home-finance-tracker-backend:1.0.2
```

If the registry is down:

```sh
sudo docker start local-registry || sudo docker run -d --name local-registry \
  --restart always -p 127.0.0.1:5000:5000 \
  -v /home/umbrel/registry-data:/var/lib/registry registry:2
```

If GHCR says `unauthorized`, the PAT is gone or expired — make a new classic
token with scope `read:packages` and run `docker login ghcr.io -u sportnoi`
**and** `sudo docker login ghcr.io -u sportnoi` (the CLI and root read different
config files).

**Take a backup.** Especially for any release that touches the schema:

```sh
sudo sh /home/umbrel/scripts/backup-finance-casa.sh
```

---

## 1. App repo — build and publish the images

In `sportnoi/home-finance-tracker`, with your change committed and pushed to
`main`:

```powershell
git tag v1.0.3
git push origin v1.0.3
```

Keep the app tag and the store version in lockstep: app `v1.0.3` -> store
`1.0.3`. Chasing a mismatch later is not worth the five seconds saved.

Watch the run at
https://github.com/sportnoi/home-finance-tracker/actions — **all three matrix
jobs must be green**. `fail-fast: false` means one failure no longer cancels the
others, so check each rather than the overall badge.

## 2. Umbrel host — mirror the images

umbreld pulls through the Docker Engine API, which never reads
`~/.docker/config.json`, so it cannot authenticate to private GHCR packages.
That is why the images are mirrored into a registry on the host instead.

```sh
VERSION=1.0.3
for img in backend frontend telegram-bot; do
  sudo docker pull  ghcr.io/sportnoi/home-finance-tracker-$img:$VERSION
  sudo docker tag   ghcr.io/sportnoi/home-finance-tracker-$img:$VERSION \
                    localhost:5000/home-finance-tracker-$img:$VERSION
  sudo docker push  localhost:5000/home-finance-tracker-$img:$VERSION
done
```

Verify all three before going any further:

```sh
for img in backend frontend telegram-bot; do
  echo -n "$img: "; curl -s http://localhost:5000/v2/home-finance-tracker-$img/tags/list; echo
done
```

Every one must list the new version. All three are required even when only one
changed — compose resolves every service.

## 3. Store repo — bump the version

In `sportnoi/umbrel-app-store`:

- `finance-casa/docker-compose.yml` — all three `image:` tags
- `finance-casa/umbrel-app.yml` — `version:` and `releaseNotes:`

Commit and push to `main`.

**The version bump is mandatory even for a compose-only change.** umbreld renders
its own copy of `docker-compose.yml` into `app-data/` at install time — comments
stripped, quoting normalised, `container_name:` injected — and that rendered copy
is what actually runs. Refreshing the store does not regenerate it. Only an
update does.

## 4. Apply it

```sh
sudo systemctl restart umbrel
```

Or wait — umbreld polls the store roughly every five minutes. Confirm it landed:

```sh
grep '^version:' /home/umbrel/umbrel/app-stores/sportnoi-umbrel-app-store-github-*/finance-casa/umbrel-app.yml
```

Then click **Update** on the Finance Casa tile.

## 5. Verify

```sh
sudo docker ps --filter name=finance-casa --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
```

Four containers, all on the new tag, backend `(healthy)`, telegram-bot `Up` with
no restart counter. Then open the app and hard-reload — **Ctrl+Shift+R**. Static
assets and favicons are cached aggressively.

---

## If the update hangs or the app disappears

Check these in order — each has bitten this setup at least once:

```sh
# 1. What umbreld actually said
sudo journalctl -u umbrel --no-pager -n 200 | grep -i -B2 -A15 "finance-casa"

# 2. .env must exist and be readable by uid 1000, or compose cannot parse the
#    project and NO service starts
sudo ls -la /home/umbrel/umbrel/app-data/finance-casa/.env

# 3. The data directory must be owned by uid 1000
sudo ls -la /home/umbrel/umbrel/app-data/finance-casa/data/

# 4. Why a container died
sudo docker logs finance-casa_backend_1 --tail 50
```

Known error signatures:

| Symptom | Cause |
|---|---|
| `401 unauthorized` from ghcr.io | GHCR PAT missing or expired |
| `connection refused` on `localhost:5000` | local registry container not running |
| `manifest unknown` | images not mirrored for this version yet |
| `container ... is unhealthy` within a second | backend exited — usually `/data` not writable |
| No containers at all, stuck mid-update | `.env` unreadable by uid 1000 |

## Rolling back

Umbrel will not offer an update to a lower version, so roll back by releasing
*forward* to a version that points at the older images:

1. In the store repo set `version: "1.0.4"` but leave the three `image:` tags at
   the last good version (say `1.0.2`).
2. Push, restart umbreld, click Update.

If the database was migrated by the bad release, restore it too:

```sh
# stop the app from the dashboard first
gunzip -c /home/umbrel/backups/finance-casa/finance-<timestamp>.db.gz \
  | sudo tee /home/umbrel/umbrel/app-data/finance-casa/data/finance.db >/dev/null
sudo chown 1000:1000 /home/umbrel/umbrel/app-data/finance-casa/data/finance.db
# then start the app
```

---

## Quick reference

```sh
# on the Umbrel, for release X.Y.Z
VERSION=X.Y.Z
curl -s http://localhost:5000/v2/_catalog                       # registry alive?
sudo sh /home/umbrel/scripts/backup-finance-casa.sh             # backup
for img in backend frontend telegram-bot; do                    # mirror
  sudo docker pull ghcr.io/sportnoi/home-finance-tracker-$img:$VERSION
  sudo docker tag  ghcr.io/sportnoi/home-finance-tracker-$img:$VERSION \
                   localhost:5000/home-finance-tracker-$img:$VERSION
  sudo docker push localhost:5000/home-finance-tracker-$img:$VERSION
done
# ...bump the store repo, then:
sudo systemctl restart umbrel                                   # pick up store
# click Update, then:
sudo docker ps --filter name=finance-casa
```
