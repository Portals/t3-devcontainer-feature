#!/usr/bin/env bash
set -euo pipefail

groups=(
    'fontconfig'
    'fonts-dejavu-core'
    'libnss3'
    'libglib2.0-0t64 libglib2.0-0'
    'libatk1.0-0t64 libatk1.0-0'
    'libatk-bridge2.0-0t64 libatk-bridge2.0-0'
    'libatspi2.0-0t64 libatspi2.0-0'
    'libdbus-1-3'
    'libx11-6'
    'libxcb1'
    'libxcomposite1'
    'libxdamage1'
    'libxext6'
    'libxfixes3'
    'libxrandr2'
    'libxkbcommon0'
    'libgbm1'
    'libasound2t64 libasound2'
    'libexpat1'
)
packages=()

for group in "${groups[@]}"; do
    found=false
    for candidate in $group; do
        if apt-cache show "$candidate" 2>/dev/null | grep -Fx "Package: $candidate" >/dev/null; then
            packages+=("$candidate")
            found=true
            break
        fi
    done
    [[ "$found" == true ]] || { echo "No available browser dependency for $group" >&2; exit 1; }
done

apt-get install -y --no-install-recommends "${packages[@]}"
