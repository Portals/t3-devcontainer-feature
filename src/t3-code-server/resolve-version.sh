#!/usr/bin/env bash
set -euo pipefail
requested=${1:?Version or release channel required}
output=${2:?Manifest output path required}
[[ "$requested" == stable || "$requested" == latest || "$requested" == nightly || "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?$ ]] || {
    echo 'Use stable, nightly, or an exact T3 version.' >&2
    exit 1
}
fetch() {
    curl --fail --show-error --silent --location --retry 2 --max-time 60 \
        --header 'User-Agent: t3-devcontainer-feature' "$1" || {
        echo "Could not fetch release metadata: $1" >&2
        return 1
    }
}
cached="${T3CODE_HOME:-/var/lib/t3-code}/runtime/versions/$requested/.resolved-version.json"
if [[ ! -r "$cached" && -r /usr/local/share/t3-code/versions.json ]] &&
    jq -e --arg version "$requested" '.t3 == $version' /usr/local/share/t3-code/versions.json >/dev/null; then
    cached=/usr/local/share/t3-code/versions.json
fi
if [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?$ && -r "$cached" ]] &&
    jq -e --arg version "$requested" '
        try (. as $manifest |
            .t3 == $version and
            (.browser | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) and
            (.source | test("^https://raw\\.githubusercontent\\.com/pingdotgg/t3code/[a-f0-9]{40}/apps/server/src/preview/PreviewBrowser\\.ts$")) and
            all(["linux-arm64", "linux-x64"][];
                . as $key | $manifest.t3Archives[$key] |
                .url == ("https://github.com/pingdotgg/t3code/releases/download/v" + $version + "/t3-" + $version + "-" + $key + ".tar.gz") and
                (.sha256 | test("^[a-f0-9]{64}$")) and (.bytes | type == "number" and . > 0)) and
            all(["linux-arm64", "linux64"][];
                . as $key | $manifest.archives[$key] |
                (.sha256 | test("^[a-f0-9]{64}$")) and (.bytes | type == "number" and . > 0))) catch false
    ' "$cached" >/dev/null; then
    cp "$cached" "$output"
    printf 'Resolved cached T3 %s\n' "$requested" >&2
    exit 0
fi
case "$requested" in
    stable|latest) release=$(fetch https://api.github.com/repos/pingdotgg/t3code/releases/latest) ;;
    nightly)
        release=$(fetch 'https://api.github.com/repos/pingdotgg/t3code/releases?per_page=20' | jq -e '
            [.[] | select(.draft == false and .prerelease == true and (.tag_name | contains("-nightly."))) |
             select(any(.assets[]; (.name | endswith("-linux-arm64.tar.gz")) and ((.digest // "") | test("^sha256:[a-f0-9]{64}$"))) and
                    any(.assets[]; (.name | endswith("-linux-x64.tar.gz")) and ((.digest // "") | test("^sha256:[a-f0-9]{64}$"))))][0]')
        ;;
    *) release=$(fetch "https://api.github.com/repos/pingdotgg/t3code/releases/tags/v$requested") ;;
esac
version=$(jq -er '.tag_name | ltrimstr("v")' <<<"$release")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][a-zA-Z0-9.-]+)?$ ]]
if [[ "$requested" != stable && "$requested" != latest && "$requested" != nightly && "$version" != "$requested" ]]; then
    echo 'Release returned a different T3 version.' >&2
    exit 1
fi
native_archive() {
    jq -e --arg name "t3-$version-$1.tar.gz" '
        .assets[] | select(.name == $name) |
        select(.digest | test("^sha256:[a-f0-9]{64}$")) |
        {url:.browser_download_url, sha256:(.digest | ltrimstr("sha256:")), bytes:.size}' <<<"$release"
}
arm=$(native_archive linux-arm64)
x64=$(native_archive linux-x64)
commit=$(jq -r '.target_commitish' <<<"$release")
if [[ ! "$commit" =~ ^[a-f0-9]{40}$ ]]; then
    object=$(fetch "https://api.github.com/repos/pingdotgg/t3code/git/ref/tags/v$version" | jq -e '.object')
    for _attempt in 1 2; do
        [[ "$(jq -r '.type' <<<"$object")" == tag ]] || break
        sha=$(jq -er '.sha' <<<"$object")
        [[ "$sha" =~ ^[a-f0-9]{40}$ ]]
        object=$(fetch "https://api.github.com/repos/pingdotgg/t3code/git/tags/$sha" | jq -e '.object')
    done
    [[ "$(jq -r '.type' <<<"$object")" == commit ]]
    commit=$(jq -er '.sha' <<<"$object")
fi
[[ "$commit" =~ ^[a-f0-9]{40}$ ]]
source_url="https://raw.githubusercontent.com/pingdotgg/t3code/$commit/apps/server/src/preview/PreviewBrowser.ts"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
fetch "$source_url" > "$temporary/browser.ts"
browser=$(sed -nE 's/^const VERSION = "([0-9.]+)";$/\1/p' "$temporary/browser.ts")
[[ "$browser" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo 'The T3 release uses an unsupported browser manifest format.' >&2
    exit 1
}
browser_archive() {
    awk -v platform="$1" '
        $0 ~ "^  (" platform "|\"" platform "\"): \\{" { inside = 1; next }
        inside && /^  },/ { exit }
        inside && /bytes:/ { value = $0; gsub(/[^0-9]/, "", value); print value }
        inside && /sha256:/ { split($0, fields, "\""); print fields[2] }
    ' "$temporary/browser.ts"
}
mapfile -t browser_x64 < <(browser_archive linux64)
mapfile -t browser_arm < <(browser_archive linux-arm64)
[[ "${#browser_x64[@]}" == 2 && "${#browser_arm[@]}" == 2 ]]
for digest in "${browser_x64[1]}" "${browser_arm[1]}"; do
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]]
done
for bytes in "${browser_x64[0]}" "${browser_arm[0]}"; do
    [[ "$bytes" =~ ^[1-9][0-9]+$ ]]
done
jq -n --arg t3 "$version" --arg browser "$browser" --arg source "$source_url" \
    --argjson arm "$arm" --argjson x64 "$x64" \
    --argjson arm_bytes "${browser_arm[0]}" --arg arm_sha "${browser_arm[1]}" \
    --argjson x64_bytes "${browser_x64[0]}" --arg x64_sha "${browser_x64[1]}" \
    '{t3:$t3, browser:$browser, source:$source,
      t3Archives:{"linux-arm64":$arm,"linux-x64":$x64},
      archives:{"linux-arm64":{bytes:$arm_bytes,sha256:$arm_sha},linux64:{bytes:$x64_bytes,sha256:$x64_sha}}}' > "$output"
printf 'Resolved T3 %s and browser %s\n' "$version" "$browser" >&2
