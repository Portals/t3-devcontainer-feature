#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    no-node)
        if command -v node >/dev/null || command -v npm >/dev/null; then
            echo 'Unexpected Node.js/npm installation.' >&2
            exit 1
        fi
        echo 'T3 operates without Node.js or npm installed.'
        ;;
    existing-node)
        [[ "$(command -v node)" == "$(cat /opt/node-baseline/path)" ]]
        [[ "$(node --version)" == "$(cat /opt/node-baseline/version)" ]]
        sha256sum --check --status /opt/node-baseline/checksum
        if command -v npm >/dev/null; then
            echo 'The feature unexpectedly installed npm.' >&2
            exit 1
        fi
        echo 'Existing Node.js path, version, and executable are unchanged; npm remains absent.'
        ;;
    *) echo 'Usage: test/runtime-check.sh no-node|existing-node' >&2; exit 1 ;;
esac
t3 --version
test "$(readlink -f /usr/local/bin/t3)" = /usr/local/share/t3-code/t3-launcher
t3-code-browser-check
