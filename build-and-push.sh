#!/bin/bash
set -euo pipefail

# Set variables here
REPO="adclab/onlydropbox"
VERSION="v0.4"

# Build image with both tags
docker build \
  -t "${REPO}:${VERSION}" \
  -t "${REPO}:latest" \
  .

# Push both tags
docker push "${REPO}:${VERSION}"
docker push "${REPO}:latest"
