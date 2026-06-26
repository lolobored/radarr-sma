# syntax=docker/dockerfile:1
#
# Radarr on a Debian (glibc) base so the sickbeard_mp4_automator OCR extras
# (easyocr / PyTorch) install from wheels, which are unavailable on the
# upstream Alpine/musl image. Built on the LinuxServer ffmpeg image, which
# provides the same s6-overlay v3 scaffolding (init-config / init-services)
# the SMA init scripts depend on, plus a VAAPI/QSV-capable ffmpeg.

FROM ghcr.io/linuxserver/ffmpeg

LABEL maintainer="laurent.laborde@gmail.com"
LABEL description="Radarr (Debian) + sickbeard_mp4_automator with PGS->SRT subtitle OCR"

# SMA_REPO/SMA_BRANCH are baked as ENV (not just ARG) so the init-sma-config
# runtime auto-update (SMA_UPDATE=true) pulls from the same fork/branch that
# was cloned at build time. SMA_OCR=true makes update.py enable PGS OCR.
ENV SMA_PATH=/usr/local/sma \
    SMA_RS=Radarr \
    SMA_UPDATE=false \
    SMA_OCR=true \
    SMA_FFMPEG_PATH=ffmpeg \
    SMA_FFPROBE_PATH=ffprobe \
    SMA_REPO=https://github.com/lolobored/sickbeard_mp4_automator.git \
    SMA_BRANCH=feature/pgs-ocr-subtitles \
    EASYOCR_MODULE_PATH=/usr/local/sma/config/.EasyOCR \
    XDG_CONFIG_HOME=/config/xdg \
    COMPlus_EnableDiagnostics=0 \
    TMPDIR=/run/radarr-temp

ARG RADARR_BRANCH="master"
# buildx provides TARGETARCH (amd64 / arm64); map it to the servarr arch token.
ARG TARGETARCH

# System packages: Radarr runtime (libicu/sqlite), helpers, python, and the
# shared libs easyocr/opencv/torch load at runtime (libGL, glib, OpenMP).
RUN set -eux; \
  apt-get update; \
  apt-get install --no-install-recommends -y \
    curl jq xmlstarlet unzip \
    libicu-dev libsqlite3-dev \
    python3 python3-venv python3-pip git \
    libgl1 libglib2.0-0 libgomp1 \
    fontconfig fonts-dejavu; \
  rm -rf /var/lib/apt/lists/*

# Install Radarr (servarr self-contained .NET build).
RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) RADARR_ARCH=x64 ;; \
    arm64) RADARR_ARCH=arm64 ;; \
    arm)   RADARR_ARCH=arm ;; \
    *)     RADARR_ARCH=x64 ;; \
  esac; \
  mkdir -p /app/radarr/bin; \
  if [ -z "${RADARR_RELEASE:-}" ]; then \
    RADARR_RELEASE=$(curl -sL "https://radarr.servarr.com/v1/update/${RADARR_BRANCH}/changes?runtime=netcore&os=linux" | jq -r '.[0].version'); \
  fi; \
  curl -o /tmp/radarr.tar.gz -L "https://radarr.servarr.com/v1/update/${RADARR_BRANCH}/updatefile?version=${RADARR_RELEASE}&os=linux&runtime=netcore&arch=${RADARR_ARCH}"; \
  tar xzf /tmp/radarr.tar.gz -C /app/radarr/bin --strip-components=1; \
  printf 'UpdateMethod=docker\nBranch=%s\nPackageVersion=sma\nPackageAuthor=lolobored\n' "${RADARR_BRANCH}" > /app/radarr/package_info; \
  rm -rf /app/radarr/bin/Radarr.Update /tmp/*

# Install the mp4 automator fork and its python environment (including the
# optional OCR extras). Baked at build time so the container starts fast.
RUN set -eux; \
  git config --global --add safe.directory ${SMA_PATH}; \
  git clone --depth 1 -b "${SMA_BRANCH}" "${SMA_REPO}" ${SMA_PATH}; \
  python3 -m venv ${SMA_PATH}/venv; \
  ${SMA_PATH}/venv/bin/pip install --no-cache-dir --upgrade pip; \
  ${SMA_PATH}/venv/bin/pip install --no-cache-dir \
    -r ${SMA_PATH}/setup/requirements.txt \
    -r ${SMA_PATH}/setup/requirements-ocr.txt; \
  rm -rf /root/.cache

EXPOSE 7878

VOLUME /config
VOLUME /usr/local/sma/config

# update.py sets FFMPEG/FFPROBE paths, API key, Radarr settings and OCR toggle
# in autoProcess.ini
COPY extras/ ${SMA_PATH}/
COPY root/ /

# The ffmpeg base overrides ENTRYPOINT to /ffmpegwrapper.sh (CLI use); reset it
# to the s6-overlay init so the init scripts and svc-radarr service actually run.
ENTRYPOINT ["/init"]
