#!/usr/bin/env bash
# lib/profile/base.sh — the plain image: the board, its distro and nothing more.
#
# A profile says what the machine is for, independently of board, vendor, distro
# and root filesystem. It defines the profile_* contract:
#   profile_env_summary       one log line for the build summary and dry run
#   profile_check_config      refuse a board/distro/fs combination it cannot serve
#   profile_check_host        what the build host must provide, checked before any build
#   profile_kernel_contracts  names of kconfig/<name>.contract the kernel must meet
#   profile_build_modules     out-of-tree modules the role needs, against the new kernel
#   profile_install           the role's userspace, after the base system is set up
# and may set PROFILE_IMAGE_TAG (appended to the image name) and
# PROFILE_IMAGE_SIZE (the root size the role needs, before first-boot growth).
#
# shellcheck disable=SC2034  # PROFILE_* vars are read by scripts/build.sh.

PROFILE_IMAGE_TAG=""
PROFILE_IMAGE_SIZE=""

profile_env_summary()      { log "profile: base (no role beyond the distro)"; }
profile_check_config()     { :; }
profile_check_host()       { :; }
profile_kernel_contracts() { :; }
profile_build_modules()    { :; }
profile_install()          { :; }
