#!/usr/bin/env bash
# Isolated candidate validation and explicit default promotion; no image/boot I/O.

kernel_require_release_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
    fatal "Select an explicit release tag (vX.Y or vX.Y.Z), not master/latest: $1"
}

kernel_file_hash() { sha256sum -- "$1" | cut -d ' ' -f 1; }

kernel_inputs_hash() {
  # Relative paths make the fingerprint independent of the checkout location.
  # Include patches, fragments, hooks and the engine, but not docs/build outputs.
  (
    cd "${PROJECT_DIR}"
    find config lib boards kconfig scripts -type f -print0 |
      LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f 1
  )
}

kernel_check_dependencies() {
  local cmd
  local -a required=(git make gcc ld pkg-config aarch64-linux-gnu-gcc
    aarch64-linux-gnu-ld aarch64-linux-gnu-objcopy bc bison flex openssl
    perl python3 awk sed grep find sort xargs sha256sum tee mktemp)
  [[ "${MODERN_KERNEL}" == 1 ]] && required+=(pahole readelf)
  for cmd in "${required[@]}"; do
    have "${cmd}" || fatal "Kernel validation needs '${cmd}'. Install build dependencies first; this command never runs sudo."
  done
}

kernel_validation_steps() {
  local mode="$1" inputs="$2" commit tag_commit version dtb config_hash dtb_hash image_hash=""
  git_clone_or_refresh_shallow "${KERNEL_REPO}" "${KERNEL_REF}" "${KERNEL_SRC_DIR}"
  commit="$(git -C "${KERNEL_SRC_DIR}" rev-parse HEAD)"
  tag_commit="$(git -C "${KERNEL_SRC_DIR}" rev-parse "refs/tags/${KERNEL_REF}^{commit}")"
  [[ "${commit}" == "${tag_commit}" ]] || fatal "Checkout does not match release tag ${KERNEL_REF}."
  version="$(make -s -C "${KERNEL_SRC_DIR}" kernelversion)"
  local expected="${KERNEL_REF#v}"
  [[ "${expected}" =~ ^[0-9]+\.[0-9]+$ ]] && expected+=.0
  [[ "${version}" == "${expected}" ]] || fatal "Tag/version mismatch: ${KERNEL_REF} / ${version}"

  board_hook inject_kernel_sources
  kernel_dtb_has_source || fatal "Kernel tree cannot build ${KERNEL_DTB} (no .dts, no -dtbs rule)"
  board_hook prepare_modules
  STOP_AFTER_KCONFIG=0
  [[ "${mode}" == check ]] && STOP_AFTER_KCONFIG=1
  build_kernel
  if [[ "${mode}" == check ]]; then
    # Kconfig alone cannot detect obsolete DT labels/bindings. Compile this DTB.
    run make -C "${KERNEL_SRC_DIR}" O="${KERNEL_BUILD_DIR}" ARCH=arm64 \
      CROSS_COMPILE=aarch64-linux-gnu- "${KERNEL_DTB}"
  else
    fs_build_modules
    profile_build_modules
    board_hook build_modules
  fi
  dtb="${KERNEL_BUILD_DIR}/arch/arm64/boot/dts/${KERNEL_DTB}"
  [[ -s "${dtb}" ]] || fatal "Kernel DTB not generated: ${KERNEL_DTB}"
  [[ "$(kernel_inputs_hash)" == "${inputs}" ]] || fatal "Build inputs changed during validation; run again."
  config_hash="$(kernel_file_hash "${KERNEL_BUILD_DIR}/.config")"
  dtb_hash="$(kernel_file_hash "${dtb}")"
  if [[ "${mode}" == build ]]; then
    image_hash="$(kernel_file_hash "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image")"
  fi

  # Publish only on success. This is data, never a shell file to be sourced.
  {
    printf '%s\n' 'format=1' 'status=passed' "mode=${mode}" \
      "repo=${KERNEL_REPO}" "ref=${KERNEL_REF}" "commit=${commit}" \
      "version=${version}" "board=${BOARD}" "distro=${DISTRO}" "profile=${PROFILE}" \
      "defconfig=${KERNEL_DEFCONFIG}" "distro_kernel=${DISTRO_KERNEL}" \
      "docker_kernel=${DOCKER_KERNEL}" "modern_kernel=${MODERN_KERNEL}" \
      "dtb=${KERNEL_DTB}" "inputs_sha256=${inputs}" \
      "config_sha256=${config_hash}" "dtb_sha256=${dtb_hash}" "date=$(date -u +%FT%TZ)"
    if [[ "${mode}" == build ]]; then
      printf 'image_sha256=%s\n' "${image_hash}"
    fi
    if [[ -d "${AIC8800_DIR}/.git" ]]; then
      printf 'aic8800_repo=%s\n' "${AIC8800_REPO}"
      printf 'aic8800_commit=%s\n' "$(git -C "${AIC8800_DIR}" rev-parse HEAD)"
    fi
  } > "${WORKSPACE}/validation.txt.tmp"
  mv -- "${WORKSPACE}/validation.txt.tmp" "${WORKSPACE}/validation.txt"
  log "Validation passed (${mode}, ${BOARD}/${DISTRO}/${PROFILE}); this is NOT a hardware test."
  log "Report: ${WORKSPACE}/validation.txt"
}

run_kernel_validation() {
  local mode="$1" root inputs
  kernel_require_release_tag "${KERNEL_REF}"
  [[ "${SKIP_FETCH}" == 0 && "${SKIP_BUILD}" == 0 ]] ||
    fatal "Candidate validation requires SKIP_FETCH=0 and SKIP_BUILD=0."
  # Refuse legacy-only hooks instead of silently omitting a new board's patches.
  if declare -F board_inject_sources >/dev/null &&
     ! declare -F board_inject_kernel_sources >/dev/null &&
     ! declare -F board_inject_uboot_sources >/dev/null &&
     ! declare -F board_prepare_modules >/dev/null; then
    fatal "Split board_inject_sources into kernel/uboot/module hooks before kernel validation."
  fi
  kernel_check_dependencies
  inputs="$(kernel_inputs_hash)"
  root="${KERNEL_VALIDATION_ROOT:-${PROJECT_DIR}/work/kernel-validation}"
  mkdir -p -- "${root}"
  root="$(cd -- "${root}" && pwd)"
  # Always a fresh private workspace. Ignore normal WORKSPACE/CLEAN_WORKSPACE
  # and AIC8800_DIR overrides; never reset/delete a user's existing source tree.
  WORKSPACE="$(mktemp -d "${root}/${BOARD}-${DISTRO}-${KERNEL_REF}.XXXXXX")"
  DOWNLOAD_DIR="${WORKSPACE}/downloads"
  SRC_DIR="${WORKSPACE}/src"
  BUILD_DIR="${WORKSPACE}/build"
  KERNEL_SRC_DIR="${SRC_DIR}/linux"
  KERNEL_BUILD_DIR="${BUILD_DIR}/linux-build"
  UBOOT_DIR="${SRC_DIR}/u-boot"
  AIC8800_DIR="${SRC_DIR}/aic8800"
  CLEAN_KERNEL=0
  mkdir -p "${SRC_DIR}" "${BUILD_DIR}"
  log "Isolated kernel validation: ${WORKSPACE}"
  # A plain pipeline preserves errexit/pipefail, unlike an `if function` call.
  ( kernel_validation_steps "${mode}" "${inputs}" ) 2>&1 | tee "${WORKSPACE}/validation.log"
}

kernel_promote() {
  local report="$1" tested="$2" key value dir current remote commit line temp
  local -A fields=()
  [[ "${tested}" == 1 ]] || fatal "Promotion requires --tested (explicit confirmation of real-device tests)."
  [[ -f "${report}" ]] || fatal "Validation report not found: ${report}"
  while IFS='=' read -r key value; do
    case "${key}" in
      format|status|mode|repo|ref|commit|version|board|distro|profile|defconfig|distro_kernel|docker_kernel|modern_kernel|dtb|inputs_sha256|config_sha256|dtb_sha256|image_sha256|date|aic8800_repo|aic8800_commit)
        [[ ! -v "fields[${key}]" ]] || fatal "Duplicate report field: ${key}"
        fields["${key}"]="${value}" ;;
      *) fatal "Invalid report field: ${key}" ;;
    esac
  done < "${report}"
  [[ "${fields[format]:-}" == 1 && "${fields[status]:-}" == passed && "${fields[mode]:-}" == build ]] ||
    fatal "Promotion needs a successful kernel-build report, not dry-run/kernel-check."
  kernel_require_release_tag "${fields[ref]:-}"
  [[ -n "${fields[repo]:-}" && "${fields[commit]:-}" =~ ^[0-9a-f]{40}$ ]] || fatal "Incomplete kernel identity in report."
  [[ "${fields[board]:-}" =~ ^[a-z0-9-]+$ && "${fields[distro]:-}" =~ ^[a-z0-9-]+$ ]] || fatal "Invalid board/distro in report."
  [[ "${fields[dtb]:-}" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+\.dtb$ ]] || fatal "Invalid DTB in report."
  current="$(kernel_inputs_hash)"
  [[ "${fields[inputs_sha256]:-}" == "${current}" ]] || fatal "Build inputs changed since validation; rebuild the candidate."
  dir="$(cd -- "$(dirname -- "${report}")" && pwd)/build/linux-build"
  [[ -s "${dir}/arch/arm64/boot/Image" && -s "${dir}/.config" &&
     -s "${dir}/arch/arm64/boot/dts/${fields[dtb]}" ]] || fatal "Validated artifacts are missing beside the report."
  [[ "$(kernel_file_hash "${dir}/arch/arm64/boot/Image")" == "${fields[image_sha256]:-}" &&
     "$(kernel_file_hash "${dir}/.config")" == "${fields[config_sha256]:-}" &&
     "$(kernel_file_hash "${dir}/arch/arm64/boot/dts/${fields[dtb]}")" == "${fields[dtb_sha256]:-}" ]] ||
    fatal "Validated artifacts changed; rebuild the candidate."
  remote="$(git ls-remote --exit-code --tags -- "${fields[repo]}" "refs/tags/${fields[ref]}" "refs/tags/${fields[ref]}^{}")"
  commit="$(awk -v ref="refs/tags/${fields[ref]}" '$2 == ref { tag=$1 } $2 == ref "^{}" { peeled=$1 } END { print peeled ? peeled : tag }' <<< "${remote}")"
  [[ "${commit}" == "${fields[commit]}" ]] || fatal "Remote release tag changed since validation."
  [[ "$(kernel_inputs_hash)" == "${current}" ]] || fatal "Build inputs changed while checking the remote tag; retry validation."

  # Only the central kernel defaults change. Quote values as shell assignments,
  # preserve all other defaults, then replace the file atomically on the same FS.
  local file="${PROJECT_DIR}/config/versions.conf" repo_count=0 ref_count=0
  while IFS= read -r line; do
    case "${line}" in
      DEFAULT_KERNEL_REPO=*) repo_count=$((repo_count + 1)) ;;
      DEFAULT_KERNEL_REF=*) ref_count=$((ref_count + 1)) ;;
    esac
  done < "${file}"
  [[ "${repo_count}" == 1 && "${ref_count}" == 1 ]] || fatal "Expected one kernel repo/ref assignment in ${file}."
  temp="$(mktemp "${file}.XXXXXX")"
  while IFS= read -r line; do
    case "${line}" in
      DEFAULT_KERNEL_REPO=*) printf 'DEFAULT_KERNEL_REPO=%q\n' "${fields[repo]}" ;;
      DEFAULT_KERNEL_REF=*) printf 'DEFAULT_KERNEL_REF=%q\n' "${fields[ref]}" ;;
      *) printf '%s\n' "${line}" ;;
    esac
  done < "${file}" > "${temp}"
  chmod --reference="${file}" "${temp}"
  mv -f -- "${temp}" "${file}"
  log "Default kernel promoted to ${fields[ref]} (${fields[commit]})."
  log "Validated scope: ${fields[board]}/${fields[distro]}; hardware testing confirmed by the operator."
  log "Review git diff -- config/versions.conf and test other supported boards before release."
}
