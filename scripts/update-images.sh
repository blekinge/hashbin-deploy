#!/usr/bin/env bash
#
# Pin new image tags in overlays/production/kustomization.yaml.
#
# Usage:
#   scripts/update-images.sh <image:tag> [<image:tag> ...]
#
# Example (paste the refs from your CI / `docker pull` output):
#   scripts/update-images.sh \
#     harbor.tools.nyx.kb.dk/blekinge/hashbin-quarkus:1.0.0-SNAPSHOT-main-sha.05cb...-build.6 \
#     harbor.tools.nyx.kb.dk/blekinge/hashbin-web:0.1.0-master-sha.f8a1...-build.6
#
# Each ref is split into <name>:<tag>; the matching `images:` entry in the overlay is
# updated in place. Then review/commit:
#   git diff && git commit -am "bump images" && git push   # ArgoCD syncs on push
set -euo pipefail

overlay_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/overlays/production"

if ! command -v kustomize >/dev/null 2>&1; then
  echo "error: 'kustomize' is required (https://kubectl.docs.kubernetes.io/installation/kustomize/)." >&2
  exit 1
fi

if [ "$#" -lt 1 ]; then
  sed -n '2,18p' "${BASH_SOURCE[0]}" >&2   # print the usage header
  exit 1
fi

for ref in "$@"; do
  name="${ref%:*}"
  tag="${ref##*:}"
  if [ "$name" = "$ref" ] || [ -z "$tag" ] || [[ "$tag" == */* ]]; then
    echo "error: '$ref' is not <name>:<tag>" >&2
    exit 1
  fi
  # `kustomize edit set image <name>:<tag>` updates the newTag of the matching entry.
  ( cd "$overlay_dir" && kustomize edit set image "$ref" )
  echo "pinned ${name}:${tag}"
done

echo
echo "Rendered images:"
kustomize build "$overlay_dir" | grep -E 'image: harbor\.' | sed 's/^[[:space:]]*//' | sort -u
