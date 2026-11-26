#!/usr/bin/env bash
# Install the kubectl plugin matching the Argo Rollouts controller release.
set -euo pipefail

version=v1.10.2
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64) arch=amd64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
case "$os" in
  darwin|linux) ;;
  *) echo "unsupported operating system: $os" >&2; exit 1 ;;
esac

asset="kubectl-argo-rollouts-$os-$arch"
destination=${ARGO_ROLLOUTS_BIN_DIR:-"$HOME/.local/bin"}
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/argo-rollouts-cli.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$destination"
curl --fail --location --silent --show-error \
  "https://github.com/argoproj/argo-rollouts/releases/download/$version/$asset" \
  -o "$tmpdir/$asset"
chmod 0755 "$tmpdir/$asset"
mv "$tmpdir/$asset" "$destination/kubectl-argo-rollouts"
echo "Installed Argo Rollouts CLI $version at $destination/kubectl-argo-rollouts"
echo "Add $destination to PATH, then run: kubectl argo rollouts version"
