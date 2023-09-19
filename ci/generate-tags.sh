#!/bin/bash

prefix=$(echo "$CURRENT_TAG" | awk -F':' '{print $1}')
suffix=$(echo "$CURRENT_TAG" | awk -F':' '{print $2}')

if [ "$build_type" == "branch" ]; then
  cat <<EOF > "${GITHUB_OUTPUT:-/dev/stdout}"
TAGS<<EOT
$(printf "%s\n" "${prefix}:${suffix}" "${prefix}-conda:${suffix}")
EOT
EOF
else
  cat <<EOF > "${GITHUB_OUTPUT:-/dev/stdout}"
TAGS<<EOT
$(printf "%s\n" "$CURRENT_TAG")
EOT
EOF
fi
