#!/usr/bin/env bash
set -euo pipefail

# Install missing CLI tools needed by this repo: k3d, helm, kubectl.
# Idempotent — anything already on PATH is left alone.
#
# Docker is intentionally NOT installed by this script. Inside WSL the only
# supported path is Docker Desktop (Windows side) with WSL integration
# enabled — that's a manual host-side step. We detect it and print
# instructions, but we cannot fix it from here.

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---- arch detection for binary downloads -----------------------------------
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) red "unsupported architecture: $(uname -m)"; exit 1 ;;
esac

# ---- Docker (host-side only) -----------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  green "docker      already working — skipping"
else
  yellow "docker      cannot be auto-installed from inside WSL."
  yellow "            1. Install Docker Desktop on Windows:"
  yellow "               https://www.docker.com/products/docker-desktop/"
  yellow "            2. Docker Desktop → Settings → Resources → WSL Integration"
  yellow "               → enable the toggle for this Ubuntu distro → Apply & Restart"
  yellow "            3. In Windows PowerShell:  wsl --shutdown"
  yellow "               then reopen this terminal."
  yellow ""
fi

# ---- k3d -------------------------------------------------------------------
if command -v k3d >/dev/null 2>&1; then
  green "k3d         already installed — skipping"
else
  step "Installing k3d"
  # Official install script — uses sudo internally to drop the binary in
  # /usr/local/bin, so you'll be prompted for your WSL user's password.
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

# ---- helm ------------------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
  green "helm        already installed — skipping"
else
  step "Installing helm"
  # Same pattern: official script, prompts for sudo to install to /usr/local/bin.
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ---- kubectl ---------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
  green "kubectl     already installed — skipping"
else
  step "Installing kubectl"
  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  sudo install -o root -g root -m 0755 "$TMP/kubectl" /usr/local/bin/kubectl
fi

step "Done"
echo "Now run:  make prereqs"
