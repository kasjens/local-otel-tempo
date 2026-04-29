#!/usr/bin/env bash
set -euo pipefail

# Verify all the tools we need are installed and reachable.
# Run from WSL2 Ubuntu (or any Linux shell with Docker available).

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

missing=0

check_present() {
  # Only verifies the binary is on PATH. We deliberately don't try to print
  # a version string — different tools disagree on the right flag and the
  # noise just hides the signal.
  local name=$1 cmd=$2 hint=$3
  if command -v "$cmd" >/dev/null 2>&1; then
    green "  ok    $name"
  else
    red   "  MISS  $name"
    yellow "        install: $hint"
    missing=$((missing + 1))
  fi
}

echo "Checking prerequisites..."

# Docker is special: a working `docker` on PATH inside WSL doesn't mean the
# daemon is reachable. Docker Desktop ships a stub that exits with an error
# when WSL integration isn't enabled. So we treat docker as "ok" only when
# `docker info` actually succeeds.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  green "  ok    docker"
else
  red   "  FAIL  docker (or daemon not reachable from this WSL distro)"
  yellow "        Docker Desktop → Settings → Resources → WSL Integration"
  yellow "        Enable the toggle for your Ubuntu distro, Apply & Restart."
  yellow "        Then in Windows PowerShell:  wsl --shutdown"
  yellow "        Reopen the WSL terminal and try again."
  missing=$((missing + 1))
fi

check_present k3d     k3d     "curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
check_present kubectl kubectl "https://kubernetes.io/docs/tasks/tools/  (or: sudo snap install kubectl --classic)"
check_present helm    helm    "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

if [ $missing -gt 0 ]; then
  red "$missing prerequisite(s) missing."
  yellow "To auto-install k3d / helm / kubectl, run:  make install-tools"
  yellow "(Docker still has to be enabled manually — see above.)"
  exit 1
fi

green "All prerequisites OK."
