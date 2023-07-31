#!/bin/bash
set -euo pipefail

HUB_TOKEN=$(
  curl -s -H "Content-Type: application/json" \
    -X POST \
    -d "{\"username\": \"${GPUCIBOT_DOCKERHUB_USER}\", \"password\": \"${GPUCIBOT_DOCKERHUB_TOKEN}\"}" \
    https://hub.docker.com/v2/users/login/ | jq -r .token \
)
echo "::add-mask::${HUB_TOKEN}"

full_repo_name=${IMAGE_NAME%%:*}
tag=${IMAGE_NAME##*:}

for arch in $(echo "$ARCHES" | jq .[] -r); do
  curl --fail-with-body -i -X DELETE \
    -H "Accept: application/json" \
    -H "Authorization: JWT $HUB_TOKEN" \
    "https://hub.docker.com/v2/repositories/$full_repo_name/tags/$tag-$arch/"
done

# Logout
curl -X POST \
  -H "Authorization: JWT $HUB_TOKEN" \
  "https://hub.docker.com/v2/logout/"
