#!/usr/bin/env bash
# .github/scripts/release.sh TAG TARGET DIR [--prerelease]
#
# Publishes the images and kernel packages in DIR, each with its .sha256 from
# the build, as the release TAG on commit TARGET. A release that already exists
# gets the files added, or replaced where the names match. AP_NOTES, when set,
# opens the release notes. Needs GH_TOKEN and GH_REPO.
set -Eeuo pipefail

tag="$1" target="$2" dir="$3" prerelease="${4:-}"
cd "${dir}"
shopt -s nullglob
files=(*.img.xz *.kernel.tar.xz)
(( ${#files[@]} )) || { echo "::error::${dir} 里没有可发布的镜像或内核包"; exit 1; }

assets=()
{
  [[ -z "${AP_NOTES:-}" ]] || printf '%s\n\n' "${AP_NOTES}"
  echo "构建自 \`${GITHUB_SHA:0:12}\`，[运行记录](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})。"
  echo
  echo "| 文件 | SHA-256 |"
  echo "| --- | --- |"
  for f in "${files[@]}"; do
    [[ -f "${f}.sha256" ]] || { echo "::error::${f} 缺少 ${f}.sha256" >&2; exit 1; }
    echo "| \`${f}\` | \`$(cut -d' ' -f1 "${f}.sha256")\` |"
    assets+=("${f}" "${f}.sha256")
  done
} > notes.md

flags=()
[[ "${prerelease}" != --prerelease ]] || flags+=(--prerelease)
if gh release view "${tag}" > /dev/null 2>&1; then
  gh release upload "${tag}" "${assets[@]}" --clobber
else
  gh release create "${tag}" --target "${target}" --title "${tag}" --notes-file notes.md "${flags[@]}" "${assets[@]}"
fi
