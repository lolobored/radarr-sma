# Auto-rebuild images on upstream release — design

- **Date:** 2026-06-26
- **Status:** Approved (pending implementation)
- **Repos:** `lolobored/radarr-sma`, `lolobored/sonarr-sma` (identical change, app-specific values)

## Problem

The `*-sma` images bake a Radarr/Sonarr release plus the SMA OCR fork. Today an
image only rebuilds on a push to the repo's `master` or a manual
`workflow_dispatch`. When the Radarr/Sonarr team ships a new version, or the OCR
fork branch gets new commits, nothing rebuilds automatically. We want GitHub to
check regularly and rebuild **only when something actually changed** — never a
wasteful daily torch build for nothing.

## Goal / scope

**In scope:** a single scheduled GitHub Actions workflow per repo that, daily,
detects whether a new Radarr/Sonarr version OR a new OCR fork commit exists and,
if so, builds + pushes the multi-arch image. Keeps `:latest` fresh and mints an
immutable content tag.

**Out of scope:** NUC delivery — GitHub only keeps `:latest` fresh; the operator
pulls manually (`docker compose pull && up -d`). Base-image (linuxserver/ffmpeg)
update tracking is not watched.

## Change-detection mechanism (Approach 1: tag-existence gate)

The container registry is the source of truth — no state file, no extra secrets.

Each build pushes two tags:

- `:latest`
- `:r<APP_VERSION>-s<SMA_SHA>` — e.g. `r6.2.1.10461-s1a2b3c4` (the baked
  Radarr/Sonarr version + the OCR fork short sha)

The daily check computes the content tag from the *current* upstream state and
asks whether it already exists in the registry. Exists → already built → skip.
Missing → build. Immutable content tags accumulate and double as rollback
history.

## Workflow: `.github/workflows/docker-publish.yml`

### Triggers
```yaml
on:
  schedule:
    - cron: '0 21 * * *'       # daily 21:00 UTC = 05:00 Asia/Singapore
  push:
    branches: [ 'master' ]      # repo changes -> force build
  workflow_dispatch:            # manual force
```

### Job `resolve` (cheap; always runs)
Outputs: `build` (bool), `app_version`, `sma_sha`, `want_tag`.

1. `APP_VERSION` — resolved the same way the Dockerfile does:
   - **radarr:** `curl -sL "https://radarr.servarr.com/v1/update/master/changes?runtime=netcore&os=linux" | jq -r '.[0].version'`
   - **sonarr:** `curl -sX GET "http://services.sonarr.tv/v1/releases" | jq -r 'first(.[] | select(.releaseChannel=="v4-stable") | .version)'`
2. `SMA_SHA` — `git ls-remote https://github.com/lolobored/sickbeard_mp4_automator.git feature/pgs-ocr-subtitles`, take the sha, shorten to 7.
3. `WANT_TAG="r${APP_VERSION}-s${SMA_SHA}"`.
4. Decide `build`:
   - `github.event_name` is `push` or `workflow_dispatch` → `build=true` (force).
   - `schedule` → `docker manifest inspect <DOCKERHUB_IMG>:${WANT_TAG}` returns 0 → `build=false`; non-zero → `build=true`.
     (Anonymous read is fine for the public repo; log in first anyway to avoid Docker Hub anon rate limits.)

### Job `build` (`needs: resolve`, `if: needs.resolve.outputs.build == 'true'`)
Same as today plus pinning + content tag:

- Steps: checkout, setup-qemu, setup-buildx, login Docker Hub, login ghcr.
- `permissions: { contents: read, packages: write }` (already present).
- `docker/build-push-action`:
  - `platforms: linux/amd64,linux/arm64`
  - build-args:
    - radarr: `RADARR_RELEASE=${{ needs.resolve.outputs.app_version }}`
    - sonarr: `SONARR_VERSION=${{ needs.resolve.outputs.app_version }}`
    - both: `SMA_COMMIT=${{ needs.resolve.outputs.sma_sha }}`
  - tags (Docker Hub + ghcr, both):
    - `…/<img>:latest`
    - `…/<img>:${{ needs.resolve.outputs.want_tag }}`

## Dockerfile additions

- Declare the version ARG so `resolve` can pin the exact checked version (the
  existing `curl` fallback stays for empty/manual builds):
  - radarr: `ARG RADARR_RELEASE` (already consumed as a shell var in the install RUN)
  - sonarr: `ARG SONARR_VERSION` (already consumed)
- Add `ARG SMA_COMMIT`. After `git clone --depth 1 -b "${SMA_BRANCH}" …`, when
  `SMA_COMMIT` is non-empty, fetch + `git checkout "${SMA_COMMIT}"` so the built
  OCR code is exactly the sha that was checked. (Use a non-shallow fetch of that
  sha, or clone the branch then `git fetch origin "${SMA_COMMIT}"` + checkout.)
- Stamp provenance: `LABEL org.sma.app-version="${RADARR_RELEASE|SONARR_VERSION}" org.sma.sma-commit="${SMA_COMMIT}"`.

## Caveats

- **Cron auto-disable:** GitHub disables scheduled workflows after 60 days of
  repo inactivity (it emails first). Any manual run / commit resets it. Active
  use keeps it alive.
- **Priming build:** the first scheduled run sees `:latest` but no `:r…-s…` tag,
  so it builds once to mint the content tag, then steady-state skips until
  something changes. (Alternatively, seed by running one `workflow_dispatch`.)
- **Tag accumulation:** immutable `:r…-s…` tags pile up. Cheap; pruning/retention
  is a possible later follow-up.
- **Fork scheduling:** Actions must stay enabled on the fork (already is);
  scheduled workflows only run from the default branch.

## Success criteria

1. A day with no upstream change → scheduled run ends in the `resolve` job,
   `build=false`, no image build (seconds, ~free).
2. A new Radarr/Sonarr release or a new OCR fork commit → next scheduled run
   builds + pushes `:latest` and a new `:r…-s…` tag (multi-arch).
3. `push` to master and manual `workflow_dispatch` still force a build as today.
4. The built image's baked app version + OCR commit match the `:r…-s…` tag.
