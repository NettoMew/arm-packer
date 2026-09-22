#!/bin/sh
# Run INSIDE a disposable Alpine/aarch64 build environment, not on the board.
# Uses upstream abuild; no custom binary/package format and no host installation.
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != aarch64 ] || ! command -v apk >/dev/null 2>&1; then
    echo 'Run in a disposable Alpine/aarch64 build environment.' >&2
    exit 1
fi
out=${1:?Usage: sh scripts/build-swupdate-apks.sh /output-directory}
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd)
case "$out" in *[!a-zA-Z0-9_./-]*) echo 'Output path must not contain shell metacharacters.' >&2; exit 1;; esac
[ -z "$(find "$out" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
    echo 'Use an empty output directory; published packages/keys are never overwritten.' >&2; exit 1;
}
# Restrict automatic dependency installation and temporary APK keys to an explicit
# disposable builder. Never run this on an installed system as an update action.
[ "${ARM_PACKER_DISPOSABLE_BUILDER:-}" = 1 ] || {
    echo 'Set ARM_PACKER_DISPOSABLE_BUILDER=1 inside the disposable builder.' >&2; exit 1;
}
[ "$(id -u)" = 0 ] || { echo 'Builder must run as root inside its isolated environment.' >&2; exit 1; }
apk add --no-cache alpine-sdk cmake python3 openssl cpio libarchive-tools
# abuild resolves makedepends from cached indices (unlike apk --no-cache above).
apk update
work=$(mktemp -d /tmp/arm-packer-apks.XXXXXX)
trap 'echo "APK build workspace: $work"' EXIT
set -a
. "$project/config/versions.conf"
SWUPDATE_CONFIG_SHA512=$(sha512sum "$project/config/swupdate.fragment" | cut -d ' ' -f 1)
REPODEST="$work/packages"
SRCDEST=${SWUPDATE_SOURCE_CACHE:-$work/distfiles}
PACKAGER='arm-packer test builder <builder@example.invalid>'
JOBS=${JOBS:-2}
set +a
mkdir -p "$work/aports/arm-packer" "$work/home" "$SRCDEST"
export HOME="$work/home"
# APK repository key is unrelated to the long-lived SWU signing key. Export only
# the public half, so the image trusts these explicitly supplied build packages.
abuild-keygen -a -n
cp "$HOME"/.abuild/*.pub /etc/apk/keys/
for package in libubootenv swupdate; do
    mkdir -p "$work/aports/arm-packer/$package"
    cp "$project/packaging/alpine/$package/APKBUILD" "$work/aports/arm-packer/$package/"
    if [ "$package" = swupdate ]; then
        cp "$project/config/swupdate.fragment" "$work/aports/arm-packer/$package/"
    fi
    (cd "$work/aports/arm-packer/$package"; abuild -F -r)
    if [ "$package" = libubootenv ]; then
        apk add --repository "$REPODEST/arm-packer" \
            "libubootenv=$LIBUBOOTENV_VERSION-r0" "libubootenv-dev=$LIBUBOOTENV_VERSION-r0"
    fi
done
apk add --repository "$REPODEST/arm-packer" "swupdate=$SWUPDATE_VERSION-r0"
# Test the exact newly packaged binary/libraries even when a reused disposable
# SDK still has a previous build with the same version installed.
mkdir -p "$work/runtime"
bsdtar -xf "$REPODEST/arm-packer/aarch64/libubootenv-$LIBUBOOTENV_VERSION-r0.apk" -C "$work/runtime"
bsdtar -xf "$REPODEST/arm-packer/aarch64/swupdate-$SWUPDATE_VERSION-r0.apk" -C "$work/runtime"
LD_LIBRARY_PATH="$work/runtime/usr/lib" \
    sh "$project/scripts/test-swupdate-runtime.sh" "$work/runtime/usr/sbin/swupdate"
mkdir -p "$out/aarch64"
cp "$REPODEST/arm-packer/aarch64/libubootenv-$LIBUBOOTENV_VERSION-r0.apk" \
    "$REPODEST/arm-packer/aarch64/swupdate-$SWUPDATE_VERSION-r0.apk" "$out/aarch64/"
apk index -o "$out/aarch64/APKINDEX.tar.gz" "$out/aarch64/"*.apk
abuild-sign "$out/aarch64/APKINDEX.tar.gz"
cp "$HOME"/.abuild/*.pub "$out/"
# Ship the corresponding upstream sources and exact build recipes with binaries.
mkdir -p "$out/sources/project/config" "$out/sources/project/packaging" "$out/sources/project/scripts"
cp "$SRCDEST/swupdate-$SWUPDATE_VERSION.tar.gz" "$SRCDEST/libubootenv-$LIBUBOOTENV_VERSION.tar.gz" "$out/sources/"
cp "$project/config/versions.conf" "$project/config/swupdate.fragment" "$out/sources/project/config/"
cp -R "$project/packaging/alpine" "$out/sources/project/packaging/"
cp "$project/scripts/build-swupdate-apks.sh" "$project/scripts/test-swupdate-runtime.sh" "$out/sources/project/scripts/"
apk info -vv > "$out/build-packages.txt"
printf 'swupdate=%s\nswupdate_commit=%s\nlibubootenv=%s\nlibubootenv_commit=%s\n' \
    "$SWUPDATE_VERSION" "$SWUPDATE_COMMIT" "$LIBUBOOTENV_VERSION" "$LIBUBOOTENV_COMMIT" > "$out/build.txt"
(cd "$out"; sha256sum ./aarch64/*.apk ./aarch64/APKINDEX.tar.gz ./*.pub ./sources/*.tar.gz > SHA256SUMS)
echo "Packages and PUBLIC repository key: $out"
