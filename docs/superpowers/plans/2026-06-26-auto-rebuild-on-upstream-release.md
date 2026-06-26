# Auto-rebuild on upstream release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `lolobored/radarr-sma` and `lolobored/sonarr-sma` rebuild automatically — but only when a new Radarr/Sonarr version or a new OCR fork commit exists — via a daily GitHub Actions check.

**Architecture:** One workflow per repo with two jobs. `resolve` (cheap, always runs) computes the current upstream Radarr/Sonarr version + OCR fork short-sha into a content tag `r<version>-s<sha>`, then decides whether to build: forced on `push`/manual, otherwise built only if that content tag is missing from Docker Hub. `build` (gated) runs the existing multi-arch build, pinning the resolved version + commit and pushing `:latest` plus the immutable content tag.

**Tech Stack:** GitHub Actions, Docker Buildx (amd64+arm64), Docker Hub + ghcr.io, bash, jq, `docker manifest inspect`.

## Global Constraints

- Multi-arch: `linux/amd64,linux/arm64`. Verbatim.
- Docker Hub image: `${{ secrets.DOCKER_USERNAME }}/<project>` where project = `radarr-sma` / `sonarr-sma`. ghcr image: `ghcr.io/${{ github.repository }}`.
- Build job needs `permissions: { contents: read, packages: write }` (ghcr push).
- Secrets already set on both repos: `DOCKER_USERNAME`, `DOCKER_PASSWORD`.
- OCR fork (verbatim): repo `https://github.com/lolobored/sickbeard_mp4_automator.git`, branch `feature/pgs-ocr-subtitles`.
- Cron (verbatim): `0 21 * * *` (21:00 UTC = 05:00 Asia/Singapore).
- Version resolution (verbatim, same as the Dockerfiles):
  - radarr: `curl -sL "https://radarr.servarr.com/v1/update/master/changes?runtime=netcore&os=linux" | jq -r '.[0].version'`
  - sonarr: `curl -sX GET "http://services.sonarr.tv/v1/releases" | jq -r 'first(.[] | select(.releaseChannel=="v4-stable") | .version)'`
- Existing force behavior must be preserved: `push` to master and manual `workflow_dispatch` still build.
- Do not push commits to master mid-plan except where a task explicitly says so (a push to master triggers a real ~15-min build).

## File Structure

- `radarr-sma/Dockerfile` — modify: declare `ARG RADARR_RELEASE` + `ARG SMA_COMMIT`, pin the OCR commit, add provenance labels.
- `radarr-sma/.github/workflows/docker-publish.yml` — rewrite: `resolve` + `build` jobs.
- `sonarr-sma/Dockerfile` — modify: same, with `ARG SONARR_VERSION`.
- `sonarr-sma/.github/workflows/docker-publish.yml` — rewrite: same, with sonarr version logic + project name.

Each repo's two files change together. Tasks 1–2 do radarr; Task 3 mirrors to sonarr; Task 4 is the live integration check.

---

### Task 1: radarr Dockerfile — pin version + OCR commit, add labels

**Files:**
- Modify: `radarr-sma/Dockerfile`

**Interfaces:**
- Produces (consumed by the workflow in Task 2): build-args `RADARR_RELEASE` (servarr version string) and `SMA_COMMIT` (OCR fork short-sha). When unset, the existing curl fallback / branch-HEAD clone behavior is preserved.

- [ ] **Step 1: Declare the new build args + provenance labels right after FROM**

Declaring the ARGs here (before any `LABEL` that uses them) keeps them in scope
for both the labels and the lower `RUN` steps in this single-stage build. In
`radarr-sma/Dockerfile`, find:
```dockerfile
LABEL maintainer="laurent.laborde@gmail.com"
LABEL description="Radarr (Debian) + sickbeard_mp4_automator with PGS->SRT subtitle OCR"
```
Replace with:
```dockerfile
LABEL maintainer="laurent.laborde@gmail.com"
LABEL description="Radarr (Debian) + sickbeard_mp4_automator with PGS->SRT subtitle OCR"

# Optional pins supplied by CI's resolve job so the built image matches exactly
# what the daily check saw. Both fall back to "resolve latest at build time"
# (the curl in the install step / the branch HEAD clone) when empty.
ARG RADARR_RELEASE
ARG SMA_COMMIT
# Provenance: `docker inspect` shows what's baked in. Empty on unpinned builds.
LABEL org.sma.app-version="${RADARR_RELEASE}"
LABEL org.sma.sma-commit="${SMA_COMMIT}"
```
Leave the existing `ARG RADARR_BRANCH="master"` and `ARG TARGETARCH` lines where
they are. (`${RADARR_RELEASE}` is still consumed by the existing
`${RADARR_RELEASE:-}` fallback in the Radarr install `RUN`; an ARG declared after
`FROM` stays in scope for the whole stage.)

- [ ] **Step 2: Pin the OCR commit in the SMA clone step**

Find:
```dockerfile
RUN set -eux; \
  git config --global --add safe.directory ${SMA_PATH}; \
  git clone --depth 1 -b "${SMA_BRANCH}" "${SMA_REPO}" ${SMA_PATH}; \
  python3 -m venv ${SMA_PATH}/venv; \
```
Replace with:
```dockerfile
RUN set -eux; \
  git config --global --add safe.directory ${SMA_PATH}; \
  git clone --depth 1 -b "${SMA_BRANCH}" "${SMA_REPO}" ${SMA_PATH}; \
  if [ -n "${SMA_COMMIT:-}" ]; then \
    git -C ${SMA_PATH} fetch --depth 1 origin "${SMA_COMMIT}"; \
    git -C ${SMA_PATH} checkout -q "${SMA_COMMIT}"; \
  fi; \
  python3 -m venv ${SMA_PATH}/venv; \
```

- [ ] **Step 3: Validate the Dockerfile parses**

Run:
```bash
cd /Users/laurentlaborde/projects/sma-ocr/radarr-sma
DOCKER_BUILDKIT=1 docker build --check .
```
Expected: `Check complete, no warnings found.` (or only pre-existing warnings; no errors). If `--check` is unavailable, run `docker buildx build --call=check .`.

- [ ] **Step 4: Commit**

```bash
cd /Users/laurentlaborde/projects/sma-ocr/radarr-sma
git add Dockerfile
git commit -m "Dockerfile: accept RADARR_RELEASE/SMA_COMMIT pins + provenance labels"
```

---

### Task 2: radarr workflow — resolve + gated build

**Files:**
- Rewrite: `radarr-sma/.github/workflows/docker-publish.yml`

**Interfaces:**
- Consumes: Dockerfile build-args `RADARR_RELEASE`, `SMA_COMMIT` (Task 1).
- Produces: published tags `:latest` and `:r<version>-s<sha>` on Docker Hub + ghcr.

- [ ] **Step 1: Write the new workflow file**

Overwrite `radarr-sma/.github/workflows/docker-publish.yml` with:
```yaml
name: Docker Publish

on:
  schedule:
    - cron: '0 21 * * *'        # daily 21:00 UTC = 05:00 Asia/Singapore
  push:
    branches: [ 'master' ]
  workflow_dispatch:
    inputs:
      force:
        description: 'Force a build even if the content tag already exists'
        type: boolean
        default: true

env:
  project: radarr-sma
  sma_repo: https://github.com/lolobored/sickbeard_mp4_automator.git
  sma_branch: feature/pgs-ocr-subtitles

jobs:
  resolve:
    runs-on: ubuntu-latest
    outputs:
      build: ${{ steps.decide.outputs.build }}
      app_version: ${{ steps.versions.outputs.app_version }}
      sma_sha: ${{ steps.versions.outputs.sma_sha }}
      want_tag: ${{ steps.versions.outputs.want_tag }}
    steps:
      - name: Resolve upstream versions
        id: versions
        run: |
          set -euo pipefail
          APP_VERSION=$(curl -sL "https://radarr.servarr.com/v1/update/master/changes?runtime=netcore&os=linux" | jq -r '.[0].version')
          [ -n "$APP_VERSION" ] && [ "$APP_VERSION" != "null" ] || { echo "could not resolve Radarr version"; exit 1; }
          SMA_SHA=$(git ls-remote "$sma_repo" "$sma_branch" | awk '{print substr($1,1,7)}')
          [ -n "$SMA_SHA" ] || { echo "could not resolve SMA sha"; exit 1; }
          WANT_TAG="r${APP_VERSION}-s${SMA_SHA}"
          {
            echo "app_version=$APP_VERSION"
            echo "sma_sha=$SMA_SHA"
            echo "want_tag=$WANT_TAG"
          } >> "$GITHUB_OUTPUT"
          echo "Resolved want_tag=$WANT_TAG"
      - name: Log in to Docker Hub (avoid anon rate limits on manifest read)
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      - name: Decide whether to build
        id: decide
        env:
          DOCKERHUB_IMAGE: ${{ secrets.DOCKER_USERNAME }}/${{ env.project }}
          WANT_TAG: ${{ steps.versions.outputs.want_tag }}
          FORCE: ${{ github.event.inputs.force }}
        run: |
          set -euo pipefail
          case "${{ github.event_name }}" in
            push)
              echo "push event -> force build"; echo "build=true" >> "$GITHUB_OUTPUT"; exit 0 ;;
            workflow_dispatch)
              if [ "$FORCE" = "true" ]; then
                echo "manual force -> build"; echo "build=true" >> "$GITHUB_OUTPUT"; exit 0
              fi ;;
          esac
          if docker manifest inspect "${DOCKERHUB_IMAGE}:${WANT_TAG}" >/dev/null 2>&1; then
            echo "tag ${WANT_TAG} already exists -> skip build"
            echo "build=false" >> "$GITHUB_OUTPUT"
          else
            echo "tag ${WANT_TAG} missing -> build"
            echo "build=true" >> "$GITHUB_OUTPUT"
          fi

  build:
    needs: resolve
    if: needs.resolve.outputs.build == 'true'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      - name: Login to DockerHub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      - name: Login to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.repository_owner }}
          password: ${{ github.token }}
      - name: Build and push (amd64 + arm64)
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile
          platforms: linux/amd64,linux/arm64
          push: true
          provenance: false
          build-args: |
            RADARR_RELEASE=${{ needs.resolve.outputs.app_version }}
            SMA_COMMIT=${{ needs.resolve.outputs.sma_sha }}
          tags: |
            ${{ secrets.DOCKER_USERNAME }}/${{ env.project }}:latest
            ${{ secrets.DOCKER_USERNAME }}/${{ env.project }}:${{ needs.resolve.outputs.want_tag }}
            ghcr.io/${{ github.repository }}:latest
            ghcr.io/${{ github.repository }}:${{ needs.resolve.outputs.want_tag }}
```

- [ ] **Step 2: Validate the workflow YAML**

Run (install actionlint on demand via Docker; no local install needed):
```bash
cd /Users/laurentlaborde/projects/sma-ocr/radarr-sma
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -color .github/workflows/docker-publish.yml
```
Expected: no output / exit 0. (If Docker image pull is undesirable, fall back to a YAML parse: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/docker-publish.yml'))" && echo OK`.)

- [ ] **Step 3: Dry-run the resolve logic locally (no CI spend)**

This reproduces exactly what the `resolve` job computes and decides, on your Mac:
```bash
cd /Users/laurentlaborde/projects/sma-ocr/radarr-sma
APP_VERSION=$(curl -sL "https://radarr.servarr.com/v1/update/master/changes?runtime=netcore&os=linux" | jq -r '.[0].version')
SMA_SHA=$(git ls-remote https://github.com/lolobored/sickbeard_mp4_automator.git feature/pgs-ocr-subtitles | awk '{print substr($1,1,7)}')
WANT_TAG="r${APP_VERSION}-s${SMA_SHA}"
echo "want_tag=$WANT_TAG"
if docker manifest inspect "lolobored/radarr-sma:${WANT_TAG}" >/dev/null 2>&1; then echo "DECISION: skip (tag exists)"; else echo "DECISION: build (tag missing)"; fi
```
Expected: prints a sensible tag like `want_tag=r6.2.1.10461-s<sha>` and `DECISION: build (tag missing)` (the content tag does not exist yet — this is the first/priming build the spec calls out).

- [ ] **Step 4: Commit (do NOT push yet — push happens in Task 4)**

```bash
cd /Users/laurentlaborde/projects/sma-ocr/radarr-sma
git add .github/workflows/docker-publish.yml
git commit -m "ci: daily scheduled rebuild gated on Radarr version + OCR fork sha"
```

---

### Task 3: sonarr — mirror Dockerfile + workflow

**Files:**
- Modify: `sonarr-sma/Dockerfile`
- Rewrite: `sonarr-sma/.github/workflows/docker-publish.yml`

**Interfaces:**
- Same as Tasks 1–2 but the version build-arg is `SONARR_VERSION` and the project is `sonarr-sma`.

- [ ] **Step 1: sonarr Dockerfile — declare args + provenance labels after FROM**

In `sonarr-sma/Dockerfile`, find:
```dockerfile
LABEL maintainer="laurent.laborde@gmail.com"
LABEL description="Sonarr (Debian) + sickbeard_mp4_automator with PGS->SRT subtitle OCR"
```
Replace with:
```dockerfile
LABEL maintainer="laurent.laborde@gmail.com"
LABEL description="Sonarr (Debian) + sickbeard_mp4_automator with PGS->SRT subtitle OCR"

# Optional pins supplied by CI's resolve job so the built image matches exactly
# what the daily check saw. Both fall back to "resolve latest at build time"
# (the curl in the install step / the branch HEAD clone) when empty.
ARG SONARR_VERSION
ARG SMA_COMMIT
# Provenance: `docker inspect` shows what's baked in. Empty on unpinned builds.
LABEL org.sma.app-version="${SONARR_VERSION}"
LABEL org.sma.sma-commit="${SMA_COMMIT}"
```
Leave the existing `ARG TARGETARCH` line where it is. `${SONARR_VERSION}` is
consumed by the existing `${SONARR_VERSION:-}` fallback in the Sonarr install
`RUN` (an ARG declared after `FROM` stays in scope for the whole stage).

- [ ] **Step 2: sonarr Dockerfile — pin OCR commit**

Find:
```dockerfile
RUN set -eux; \
  git config --global --add safe.directory ${SMA_PATH}; \
  git clone --depth 1 -b "${SMA_BRANCH}" "${SMA_REPO}" ${SMA_PATH}; \
  python3 -m venv ${SMA_PATH}/venv; \
```
Replace with:
```dockerfile
RUN set -eux; \
  git config --global --add safe.directory ${SMA_PATH}; \
  git clone --depth 1 -b "${SMA_BRANCH}" "${SMA_REPO}" ${SMA_PATH}; \
  if [ -n "${SMA_COMMIT:-}" ]; then \
    git -C ${SMA_PATH} fetch --depth 1 origin "${SMA_COMMIT}"; \
    git -C ${SMA_PATH} checkout -q "${SMA_COMMIT}"; \
  fi; \
  python3 -m venv ${SMA_PATH}/venv; \
```

- [ ] **Step 3: sonarr workflow — overwrite**

Overwrite `sonarr-sma/.github/workflows/docker-publish.yml` with the Task 2 file, changed in exactly these spots:
- `env.project: sonarr-sma`
- In the `Resolve upstream versions` step, replace the `APP_VERSION=...` line with:
  ```bash
  APP_VERSION=$(curl -sX GET "http://services.sonarr.tv/v1/releases" | jq -r 'first(.[] | select(.releaseChannel=="v4-stable") | .version)')
  [ -n "$APP_VERSION" ] && [ "$APP_VERSION" != "null" ] || { echo "could not resolve Sonarr version"; exit 1; }
  ```
- In the build job `build-args`, replace `RADARR_RELEASE=...` with:
  ```yaml
            SONARR_VERSION=${{ needs.resolve.outputs.app_version }}
            SMA_COMMIT=${{ needs.resolve.outputs.sma_sha }}
  ```
Everything else (job names, `decide` step, tags using `${{ env.project }}`, ghcr `${{ github.repository }}`) is identical.

- [ ] **Step 4: Validate + dry-run (sonarr)**

```bash
cd /Users/laurentlaborde/projects/sma-ocr/sonarr-sma
DOCKER_BUILDKIT=1 docker build --check .
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest -color .github/workflows/docker-publish.yml
APP_VERSION=$(curl -sX GET "http://services.sonarr.tv/v1/releases" | jq -r 'first(.[] | select(.releaseChannel=="v4-stable") | .version)')
SMA_SHA=$(git ls-remote https://github.com/lolobored/sickbeard_mp4_automator.git feature/pgs-ocr-subtitles | awk '{print substr($1,1,7)}')
echo "want_tag=r${APP_VERSION}-s${SMA_SHA}"
```
Expected: Dockerfile check clean, actionlint silent, `want_tag` like `r4.0.18.2971-s<sha>`.

- [ ] **Step 5: Commit (do NOT push yet)**

```bash
cd /Users/laurentlaborde/projects/sma-ocr/sonarr-sma
git add Dockerfile .github/workflows/docker-publish.yml
git commit -m "ci: daily scheduled rebuild gated on Sonarr version + OCR fork sha"
```

---

### Task 4: Live integration — prime, verify content tag, verify skip

**Files:** none (push + GitHub Actions verification).

**Interfaces:** consumes everything above.

- [ ] **Step 1: Push both repos (this triggers the priming build)**

A push to master is a `push` event → forced build. This is the intended one-time priming build that mints the first content tag.
```bash
git -C /Users/laurentlaborde/projects/sma-ocr/radarr-sma push origin HEAD:master
git -C /Users/laurentlaborde/projects/sma-ocr/sonarr-sma push origin HEAD:master
```

- [ ] **Step 2: Watch the runs finish**

```bash
gh run watch -R lolobored/radarr-sma "$(gh run list -R lolobored/radarr-sma -L1 --json databaseId --jq '.[0].databaseId')" --exit-status || true
gh run watch -R lolobored/sonarr-sma "$(gh run list -R lolobored/sonarr-sma -L1 --json databaseId --jq '.[0].databaseId')" --exit-status || true
```
Expected: both runs succeed, `resolve` → `build=true` → `build` job builds + pushes.

- [ ] **Step 3: Verify the content tag now exists on both registries**

```bash
for img in radarr-sma sonarr-sma; do
  echo "=== $img tags ==="
  curl -s "https://hub.docker.com/v2/repositories/lolobored/$img/tags/?page_size=5" | jq -r '.results[].name'
done
```
Expected: each repo shows `latest` **and** a `r<version>-s<sha>` tag.

- [ ] **Step 4: Verify the skip path (no wasted build)**

Now that the content tag exists, a non-forced check must skip. Exercise it with a manual dispatch passing `force=false`:
```bash
gh workflow run "Docker Publish" -R lolobored/radarr-sma --ref master -f force=false
sleep 8
RID=$(gh run list -R lolobored/radarr-sma -L1 --json databaseId --jq '.[0].databaseId')
gh run watch -R lolobored/radarr-sma "$RID" --exit-status || true
gh run view "$RID" -R lolobored/radarr-sma --json jobs --jq '.jobs[] | "\(.name): \(.conclusion // .status)"'
```
Expected: the `resolve` job runs and succeeds; the `build` job is **skipped** (because `build=false`). The whole run completes in well under a minute with no image build.

- [ ] **Step 5: Confirm the daily schedule is registered**

```bash
gh workflow view "Docker Publish" -R lolobored/radarr-sma | head -20
gh workflow view "Docker Publish" -R lolobored/sonarr-sma | head -20
```
Expected: shows the workflow is active with a `schedule` trigger. (Reminder: GitHub auto-disables cron after 60 days of repo inactivity; a manual run or commit resets it.)

---

## Notes for the implementer

- Two pushes to master in Task 4 each cost one ~15-min multi-arch build (the priming builds). That is expected and one-time.
- The `force=false` dispatch in Task 4 Step 4 is the only way to exercise the skip branch without waiting for the 05:00 SGT cron; it is safe and cheap.
- After this lands, steady state: each daily run ends in `resolve` with `build=false` unless Radarr/Sonarr or the OCR fork changed.
