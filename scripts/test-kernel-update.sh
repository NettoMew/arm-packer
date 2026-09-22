#!/usr/bin/env bash
# Offline workflow integration tests. Git is real; compiler/make output is mocked.
# Never treat this suite as proof that a Linux release compiles or boots.
set -Eeuo pipefail
unset KERNEL_REF REPORT HARDWARE_TESTED
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${PROJECT_DIR}/work"
root="$(mktemp -d "${PROJECT_DIR}/work/test-kernel-update.XXXXXX")"
trap 'printf "Test fixtures/logs: %s\n" "${root}"' EXIT
project="${root}/project"
upstream="${root}/upstream"
mkdir -p "${project}" "${upstream}/arch/arm64/boot/dts/test" "${root}/bin"
cp -a "${PROJECT_DIR}"/{config,lib,boards,kconfig,scripts} "${project}/"

git -C "${upstream}" init -q
git -C "${upstream}" config user.name Test
git -C "${upstream}" config user.email test@example.invalid
git -C "${upstream}" config commit.gpgsign false
git -C "${upstream}" config tag.gpgsign false
git -C "${upstream}" config core.autocrlf false
printf 'fake kernel\n' > "${upstream}/Makefile"
printf '/dts-v1/; / {};\n' > "${upstream}/arch/arm64/boot/dts/test/test.dts"
git -C "${upstream}" add .
git -C "${upstream}" commit -qm fixture
git -C "${upstream}" tag -a v99.0.1 -m fixture
mkdir -p "${project}/boards/testboard"
cat > "${project}/boards/testboard/board.conf" <<'EOF'
BOARD_VENDOR=rockchip
BOARD_SOC=rk3528
BOARD_UBOOT_DEFCONFIG=not-used
BOARD_KERNEL_DTB=test/test.dtb
BOARD_IMAGE_PREFIX=test
BOARD_HOSTNAME=test
BOARD_MENU_TITLE=test
BOARD_SERIAL_CONSOLE=ttyS0
EOF
cat > "${project}/boards/testboard/hooks.sh" <<'EOF'
board_inject_uboot_sources() { fatal 'TEST: bootloader hook must never run'; }
board_inject_kernel_sources() { printf 'patch\n' > "${KERNEL_SRC_DIR}/test-patched"; }
board_prepare_modules() { printf 'driver source\n' > "${SRC_DIR}/test-driver"; }
board_build_modules() {
  [[ -f "${SRC_DIR}/test-driver" && -f "${KERNEL_SRC_DIR}/test-patched" ]] || fatal 'Hooks skipped'
  [[ "${TEST_FAIL_MODULES:-0}" == 0 ]] || fatal 'TEST: module compile failed'
  printf 'driver built\n' > "${BUILD_DIR}/test-driver-built"
}
board_inject_sources() { board_inject_uboot_sources; board_inject_kernel_sources; board_prepare_modules; }
EOF
cat > "${root}/bin/make" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ "${TEST_FAIL_MAKE:-0}" == 0 ]] || exit 23
out=""; target="${!#}"
for arg in "$@"; do
  case "${arg}" in O=*) out="${arg#O=}" ;; esac
done
case "${target}" in
  kernelversion) echo 99.0.1 ;;
  defconfig|olddefconfig)
    mkdir -p "${out}"
    printf 'CONFIG_TEST=y\n' > "${out}/.config" ;;
  modules|test/test.dtb)
    mkdir -p "${out}/arch/arm64/boot/dts/test"
    printf 'dtb\n' > "${out}/arch/arm64/boot/dts/test/test.dtb"
    if [[ "${target}" == modules ]]; then printf 'image\n' > "${out}/arch/arm64/boot/Image"; fi ;;
  *) echo "Unexpected make: $*" >&2; exit 24 ;;
esac
EOF
mkdir -p "${upstream}/scripts/kconfig"
printf '#!/usr/bin/env bash\nexit 0\n' > "${upstream}/scripts/kconfig/merge_config.sh"
git -C "${upstream}" add .
git -C "${upstream}" update-index --chmod=+x scripts/kconfig/merge_config.sh
git -C "${upstream}" commit -qm merge-fixture
git -C "${upstream}" tag -fa v99.0.1 -m fixture >/dev/null
tag_object="$(git -C "${upstream}" rev-parse refs/tags/v99.0.1)"

# Missing compiler tools are dependency-only stubs; unexpected invocation fails.
for cmd in gcc ld pkg-config aarch64-linux-gnu-gcc aarch64-linux-gnu-ld \
  aarch64-linux-gnu-objcopy bc bison flex openssl perl python3 pahole sudo; do
  printf '#!/usr/bin/env bash\necho "Unexpected tool: %s" >&2\nexit 25\n' "${cmd}" > "${root}/bin/${cmd}"
done
chmod +x "${root}/bin/"*
export PATH="${root}/bin:${PATH}"
export BOARD=testboard DISTRO=alpine KERNEL_REPO="${upstream}"
export KERNEL_VALIDATION_ROOT="${root}/validation"
export WORKSPACE="${root}/normal-work" CLEAN_WORKSPACE=1 CLEAN_KERNEL=1
export SKIP_FETCH=0 SKIP_BUILD=0
mkdir -p "${WORKSPACE}/src/u-boot"
printf 'keep me\n' > "${WORKSPACE}/src/u-boot/sentinel"
script="${project}/scripts/kernel-update.sh"
versions="${project}/config/versions.conf"
before="$(sha256sum "${versions}")"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  if "$@" > "${root}/expected-failure.log" 2>&1; then fail "unexpected success: $*"; fi
  [[ "$(sha256sum "${versions}")" == "${before}" ]] || fail 'defaults changed on failure'
}

expect_failure bash "${script}" check master
expect_failure bash "${script}" check
bash "${script}" check v99.0.1 --dry-run > "${root}/dry-run.log" 2>&1
[[ ! -d "${KERNEL_VALIDATION_ROOT}" ]] || fail 'dry-run created a workspace'
expect_failure env SKIP_FETCH=1 bash "${script}" check v99.0.1
expect_failure env SKIP_BUILD=1 bash "${script}" build v99.0.1
cp "${project}/boards/testboard/hooks.sh" "${root}/hooks.saved"
printf 'board_inject_sources() { :; }\n' > "${project}/boards/testboard/hooks.sh"
expect_failure bash "${script}" check v99.0.1
grep -Fq 'Split board_inject_sources' "${root}/expected-failure.log"
cp "${root}/hooks.saved" "${project}/boards/testboard/hooks.sh"
expect_failure bash "${script}" check v99.0.404
[[ "$(find "${KERNEL_VALIDATION_ROOT}" -name validation.txt | wc -l)" -eq 0 ]] || fail 'missing tag published a report'
echo 'PASS explicit release selection / dry-run / skip guards'

bash "${script}" check v99.0.1 > "${root}/check.log" 2>&1
check_report="$(find "${KERNEL_VALIDATION_ROOT}" -name validation.txt -print)"
grep -qx 'mode=check' "${check_report}"
[[ ! -f "${check_report%/*}/build/test-driver-built" ]] || fail 'check compiled modules'
expect_failure bash "${script}" promote "${check_report}" --tested
echo 'PASS check phase and refusal to promote a check-only report'

expect_failure env TEST_FAIL_MAKE=1 bash "${script}" build v99.0.1
expect_failure env TEST_FAIL_MODULES=1 bash "${script}" build v99.0.1
[[ "$(find "${KERNEL_VALIDATION_ROOT}" -name validation.txt | wc -l)" -eq 1 ]] || fail 'failed build published a report'
STOP_AFTER_KCONFIG=1 bash "${script}" build v99.0.1 > "${root}/build.log" 2>&1
build_report=""
while IFS= read -r file; do
  if grep -qx 'mode=build' "${file}"; then build_report="${file}"; fi
done < <(find "${KERNEL_VALIDATION_ROOT}" -name validation.txt -print)
[[ -n "${build_report}" && -s "${build_report%/*}/build/test-driver-built" ]] || fail 'module build missing'
[[ "$(cat "${WORKSPACE}/src/u-boot/sentinel")" == 'keep me' ]] || fail 'normal workspace touched'
[[ "$(sha256sum "${versions}")" == "${before}" ]] || fail 'validation changed defaults'
echo 'PASS build failures / driver hooks / private workspace / unchanged defaults'

expect_failure bash "${script}" promote "${build_report}"
cp "${build_report}" "${root}/report.saved"
printf 'mode=build\n' >> "${build_report}"
expect_failure bash "${script}" promote "${build_report}" --tested
cp "${root}/report.saved" "${build_report}"
printf '$(touch SHOULD_NOT_EXIST)=bad\n' >> "${build_report}"
expect_failure bash "${script}" promote "${build_report}" --tested
cp "${root}/report.saved" "${build_report}"
cp "${project}/lib/kernel.sh" "${root}/kernel.sh.saved"
printf '\n# changed\n' >> "${project}/lib/kernel.sh"
expect_failure bash "${script}" promote "${build_report}" --tested
cp "${root}/kernel.sh.saved" "${project}/lib/kernel.sh"
img="${build_report%/*}/build/linux-build/arch/arm64/boot/Image"
cp "${img}" "${root}/Image.saved"
printf 'changed\n' >> "${img}"
expect_failure bash "${script}" promote "${build_report}" --tested
cp "${root}/Image.saved" "${img}"
git -C "${upstream}" update-ref refs/tags/v99.0.1 HEAD~1
expect_failure bash "${script}" promote "${build_report}" --tested
git -C "${upstream}" update-ref refs/tags/v99.0.1 "${tag_object}"
echo 'PASS hardware confirmation / stale inputs / changed artifacts / moved tag guards'

grep -v '^DEFAULT_KERNEL_\(REPO\|REF\)=' "${versions}" > "${root}/other-defaults.before"
bash "${script}" promote "${build_report}" --tested > "${root}/promote.log" 2>&1
grep -v '^DEFAULT_KERNEL_\(REPO\|REF\)=' "${versions}" > "${root}/other-defaults.after"
cmp "${root}/other-defaults.before" "${root}/other-defaults.after"
source "${versions}"
[[ "${DEFAULT_KERNEL_REF}" == v99.0.1 && "${DEFAULT_KERNEL_REPO}" == "${upstream}" ]] || fail 'promotion did not update central defaults'
output="$(env -u KERNEL_REF -u KERNEL_REPO bash "${project}/scripts/build.sh" --dry-run 2>&1)"
grep -Fq "kernel source: ${upstream} @ v99.0.1" <<< "${output}"
echo 'PASS atomic promotion changes only central kernel defaults / normal builds inherit'
echo 'All workflow tests passed (mock compilation, NOT a real kernel build).'
