#!/usr/bin/env bash
set -euo pipefail

if command -v aws >/dev/null 2>&1; then
  echo "aws already installed: $(aws --version 2>&1)"
  exit 0
fi

sudo apt-get update
sudo apt-get install -y curl unzip

arch="$(uname -m)"
case "$arch" in
  x86_64) arch="x86_64" ;;
  aarch64) arch="aarch64" ;;
  *)
    echo "Unsupported architecture for AWS CLI v2 installer: $arch"
    exit 1
    ;;
esac

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmpdir/awscliv2.zip"
unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
sudo "$tmpdir/aws/install" --update

aws --version
