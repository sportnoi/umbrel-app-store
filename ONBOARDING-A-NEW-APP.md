# Prompt: make an app installable on umbrelOS

Copy everything below the line into a fresh agent session **in the application's
own repository** (not this one). Fill in the three placeholders first.

This repository — the Umbrel community app store — only ever references images
and declares ports. All the containerisation work happens in the app repo, and
the contract between the two is the handover table at the end. The requirements
below are not style preferences: each one exists because its absence broke a
real install of Finance Casa.

---

You are working in `<OWNER>/<APP_REPO>`. This app is going to be installed on a
private **umbrelOS 1.7.4** box (x86_64, not a Raspberry Pi) through a private
community app store at `sportnoi/umbrel-app-store`.

Your job is to make this app installable there: build the images, publish them,
and hand back a precise runtime contract. **You do not touch the app store
repository** — you finish by producing the handover table in section 7, which
someone else turns into `docker-compose.yml` and `umbrel-app.yml`.

The app is `<SHORT DESCRIPTION: what it is, which services it has, what it
stores>`.

Read the existing code before you write anything. Do not assume a database, a
framework, or a port — find them.

## 1. How umbrelOS actually runs an app

Internalise these, because most of the requirements below follow from them:

- **umbrelOS pulls images. It never builds.** There is no build step anywhere in
  the install path, so a `build:` stanza is useless here.
- **umbreld pulls through the Docker Engine API**, which — unlike the `docker`
  CLI — never reads `~/.docker/config.json`. It therefore cannot authenticate to
  a private registry. On this host that is solved by mirroring images into a
  registry on the Umbrel itself (`localhost:5000`). Your images still go to
  GHCR; just know that the final pull is from a local mirror, so the image name
  in compose will not be the name you push.
- **umbreld names containers itself**, as `<app-id>_<service>_1`, and manages the
  app's Docker network. A `container_name:` or a custom `networks:` breaks the
  reverse proxy's ability to find the app.
- **umbreld removes every container before it pulls.** A failed pull or a failed
  start leaves the app completely stopped, not degraded. There is no safe
  partial failure, which is why the healthcheck and first-run requirements below
  are strict.
- **There is no UI for app secrets.** Secrets arrive as a `.env` file placed by
  hand in the app's data directory on the host, owned by uid 1000, mode 600.
- **Compose runs as the `umbrel` user, uid 1000.** Bind-mount sources that do
  not already exist are created root-owned, and a container that cannot write
  its data directory dies on start.

## 2. Dockerfiles

One Dockerfile per service, at the repo root, named `Dockerfile.<service>` (or a
single `Dockerfile` if there is genuinely one service).

- **Run as uid 1000 explicitly.** `useradd -u 1000` / `adduser -u 1000`, then
  `USER`. Not "a non-root user" — specifically 1000, because the host directory
  that gets bind-mounted is chowned to 1000 and the two must agree.
- **Pin base images to a digest**, not a tag. Resolve the real digest from the
  registry; do not invent one.
- **`COPY` whole source directories, never a hand-maintained list of files.**
  This has broken this setup twice: a file list in the Dockerfile drifted out of
  step with the code's imports, and the service crashlooped with
  `ModuleNotFoundError` on an import that worked fine locally. If you must
  exclude things, do it in `.dockerignore` and then re-read section 6.
- Build for **`linux/amd64`**. Add `linux/arm64` only if the app will also run on
  ARM hardware; it doubles build time.
- **No secrets, tokens, or `.env` files in the image.** Check `.dockerignore`
  covers them, and check the build context for anything already committed.
- **Log to stdout/stderr.** No log files inside the container.
- **Handle `SIGTERM`** and exit within 60 seconds.

## 3. State and first run

- **All persistent state in exactly one directory**, whose path comes from an
  environment variable (e.g. `APP_DB_PATH`, `DATA_DIR`). Default it to something
  under `/data`. Nothing persistent anywhere else in the filesystem — no caches
  that matter, no uploads beside the database, no state in `/tmp` that is
  assumed to survive.
- **Starting against an empty data directory must produce a working app.** This
  is the requirement most likely to be quietly broken, and Finance Casa does not
  meet it: its schema-creation script is excluded from the image, so a fresh
  install comes up with no tables and the only way in is to copy an existing
  database onto the host first. Do not repeat that. Run migrations or schema
  creation at startup, idempotently, from inside the image.
- **Never `chown`, `chmod`, or create the data directory at startup.** It is a
  bind mount owned by the host. Fail with a clear message if it is not writable.
- **No hardlinks or renames across the `/data` boundary** — it is a different
  device from the image layers.

## 4. Readiness

Every service that something else waits on needs a healthcheck that is **false
until the service can actually serve a request**, not merely until the process
has started. A container reporting healthy too early makes the dependent service
fail at boot; a healthcheck that can never pass makes the whole update hang.

Write the check using a tool that is genuinely present in the image. Do not
assume `curl` — most slim base images do not have it. Check, and use the
language runtime if that is what is there. For reference, Finance Casa's backend
uses a bare TCP connect because its HTTP routes could not be assumed:

```
python -c "import socket; socket.create_connection(('127.0.0.1', 8080), timeout=3).close()"
```

Tell the handover table the exact command, interval, retries, and start period
you have verified.

## 5. Publishing to GHCR

Add `.github/workflows/publish.yml`:

- Triggers on tags matching `v*`.
- Version comes from the tag: `VERSION=${GITHUB_REF_NAME#v}`.
- A build matrix over services with **`fail-fast: false`**, so one failing
  service does not cancel the others and leave a half-published version.
- `permissions: packages: write`, authenticating with the built-in
  `GITHUB_TOKEN`. No PAT in the workflow.
- Pushes `ghcr.io/<OWNER>/<APP_REPO>-<service>:$VERSION`.
- **Do not push `:latest`,** and never re-point a tag that has already been
  published. A mutable tag means the registry, the host's image cache, and GHCR
  can each hold different content under one name with nothing on screen to say
  which — move to the next version number instead.
- Packages inherit the repository's visibility. This repo is private, so the
  packages are private, which is intended. Do not make them public.

Verify a real run goes green on a real tag before you call this done.

## 6. Prove it works before handing over

Build locally and run each service the way umbrelOS will — as uid 1000, with an
empty bind-mounted data directory, nothing else:

```sh
DATA=$(mktemp -d) && chmod 777 "$DATA"
docker build -f Dockerfile.<service> -t test-<service> .
docker run --rm --user 1000:1000 -v "$DATA":/data -e <DATA_VAR>=/data/... test-<service>
```

Confirm all of these, and say so explicitly in your report:

1. It starts against the **empty** directory and creates whatever it needs.
2. It serves on the port you are claiming.
3. Stopping and re-running against the same directory preserves the data.
4. It writes nothing outside `/data` that it needs on the next start.
5. Every import resolves **in the built image**, not just in your checkout —
   run the real entrypoint, do not just `docker build` successfully.
6. The healthcheck command exits non-zero before ready and zero after.

If a service needs a secret, also confirm what happens without it. It must
either run with reduced function or fail with a message naming the missing
variable. A silent crashloop is a bug — it takes down the install with no
indication of why.

## 7. Handover table — your deliverable

Finish your work with this filled in. Everything the app store repo needs is
here and nowhere else:

| | |
|---|---|
| Image names | `ghcr.io/<OWNER>/<APP_REPO>-<service>:<version>` for each service |
| Architectures built | |
| Web-facing service | which service the Umbrel reverse proxy should target |
| Its internal port | |
| Other services and ports | and which services talk to which |
| Data directory in-container | per service |
| Env var for the data path | name and the value to set |
| Secrets | name, required or optional, what happens when absent |
| Other env vars | name, default, what it controls |
| Healthcheck | exact command, interval, timeout, retries, start period |
| First-run | confirmed working against an empty directory — yes/no |
| Schema changes | any migration this version applies on first start |
| Uid the process runs as | |

Also list, in prose:

- Any service that must start **after** another, and the condition.
- Anything that would make this app unsafe to expose on a LAN without auth in
  front of it, since the Umbrel auth layer is disabled on this install.

## 8. Things not to do

- No `container_name:`, no custom `networks:`, no `ports:` — the store repo
  handles all three, and overriding them breaks the proxy.
- No `privileged:`, no `network_mode: host`, no mounting the Docker socket.
  umbrelOS will run it, and it will be a hole in the box.
- No `version:` key in any compose file you write for reference — it is obsolete
  and umbreld warns on it.
- No writing to the app store repository. Hand over the table instead.
- Do not invent a digest, a port, or an env var name. Read them out of the code,
  or run the image and look.
