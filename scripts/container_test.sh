#!/bin/bash

set -e

print_help() {
	echo "Usage: $0 [OPTIONS]

Options:
  --env                 Specify env settings for binutils/gdb/gcc/kernel/libc.
  --container-env K=V   Set an env var inside the build container (repeatable).
  --llvm                Use LLVM/Clang as a cross compiler
  --skip-system         Skip emerging the @system set after setting up crossdev.
  --tag <tag>           Specify the container tag to use. Default is 'latest'.
  --target <target>     Specify the target architecture for crossdev. Required.
  -h, --help            Show this help message and exit.

Environment Variables:
  CONTAINER_ENGINE      Specify the container engine to use (docker or podman).
                        Default is detected automatically.
  CONTAINER_NAME        Name of the container instance. Default is 'crossdev'.
  CONTAINER_URI         URI of the container image. Default is 'docker.io/gentoo/stage3'.

Examples:
  # Run with the default container and target architecture
  $0 --target aarch64-unknown-linux-gnu

  # Run with a specific container tag and skip emerging @system
  $0 --tag stable --target riscv64-unknown-linux-musl --skip-system

Notes:
  - You must specify a target using the --target option.
  - Ensure the container engine (docker or podman) is installed and available."
}

detect_container_engine() {
	if command -v podman &>/dev/null; then
		echo "podman"
	elif command -v docker &>/dev/null; then
		echo "docker"
	else
		echo "No container engine found. The supported ones are: docker, podman."
		exit 1
	fi
}

remove_container() {
	"${CONTAINER_ENGINE}" rm -f "${CONTAINER_NAME}" "$@"
}

run_in_container() {
	echo "+ $@"
	"${CONTAINER_ENGINE}" exec ${_CONTAINER_ARGS:+${_CONTAINER_ARGS}} "${CONTAINER_NAME}" "$@"
}

CONTAINER_ENGINE=${CONTAINER_ENGINE:-$(detect_container_engine)}
CONTAINER_NAME=${CONTAINER_NAME:-"crossdev"}
CONTAINER_URI=${CONTAINER_URI:-"docker.io/gentoo/stage3"}
CONTAINER_TAG="latest"
EMERGE_SYSTEM=1
USE_LLVM=0
CONTAINER_ENV=()
TOPDIR=$(git rev-parse --show-toplevel)

# Per-container scratch on local disk to avoid layer fs bottlenecks and parallel collisions.
CROSSDEV_TMPDIR="${CROSSDEV_TMPDIR:-/var/tmp/crossdev}/${CONTAINER_NAME}"

cleanup() {
	# Build files under the bind mount are root/portage-owned, so the host
	# user can't remove them. Wipe the mount contents from inside the
	# container (as root) before teardown, then drop the empty host dir.
	"${CONTAINER_ENGINE}" exec "${CONTAINER_NAME}" find /var/tmp/portage -mindepth 1 -delete 2>/dev/null || true
	remove_container
	rm -rf "${CROSSDEV_TMPDIR}"
}

remove_container || true
trap "cleanup" EXIT

while [[ $# -gt 0 ]]; do
	case $1 in
		-h|--help)
			print_help
			exit 0
			;;
		--llvm)
			USE_LLVM=1
			shift 1
			;;
		--skip-system)
			EMERGE_SYSTEM=0
			shift 1
			;;
		--tag)
			CONTAINER_TAG="$2"
			shift 2
			;;
		--target)
			TARGET="$2"
			shift 2
			;;
		--profile)
			PROFILE="$2"
			shift 2
			;;
		--container-env)
			CONTAINER_ENV+=("-e" "$2")
			shift 2
			;;
		*)
			echo "Unknown option: $1"
			print_help
			exit 1
			;;
	esac
done

EXTRA_ARGS=()
if [[ "${USE_LLVM}" -eq 1 ]]; then
	EXTRA_ARGS+="--llvm"
fi
if [[ -v ENV_SETTINGS ]]; then
	EXTRA_ARGS+=("--env" "${ENV_SETTINGS}")
fi

mkdir -p "${CROSSDEV_TMPDIR}"

"${CONTAINER_ENGINE}" run -d \
	--pull always \
	--name "${CONTAINER_NAME}" \
	"${CONTAINER_ENV[@]}" \
	-v "${CROSSDEV_TMPDIR}:/var/tmp/portage" \
	-v "${TOPDIR}:/workspace" \
	-w /workspace \
	"${CONTAINER_URI}:${CONTAINER_TAG}" \
	/bin/sleep inf

run_in_container emerge-webrsync
run_in_container getuto
run_in_container emerge --getbinpkg app-eselect/eselect-repository sys-apps/config-site
run_in_container make install
run_in_container eselect repository create crossdev

# Apply our toolchain fixes for non-multilib arm targets
run_in_container install -Dm644 /var/db/repos/gentoo/eclass/toolchain.eclass /var/db/repos/crossdev/eclass/toolchain.eclass
_CONTAINER_ARGS="-i" run_in_container patch -p1 -d /var/db/repos/crossdev < "${TOPDIR}/scripts/patches/toolchain-eclass-no-multilib.patch"
_CONTAINER_ARGS="-i" run_in_container patch -p1 -d /var/db/repos/crossdev < "${TOPDIR}/scripts/patches/toolchain-eclass-cflags-fix.patch"

# Fix newlib's libgloss -jN race where specs/ld are copied before arm/ dir exists
run_in_container mkdir -p "/etc/portage/patches/cross-${TARGET}/newlib"
run_in_container cp /workspace/scripts/patches/newlib-4.6.0.20260123-libgloss-specs-dirstamp.patch "/etc/portage/patches/cross-${TARGET}/newlib/newlib-libgloss-specs-dirstamp.patch"

run_in_container crossdev --show-fail-log "${EXTRA_ARGS[@]}" --target "${TARGET}" --portage "-v"
if [[ "${EMERGE_SYSTEM}" -eq 1 ]]; then
	[[ -v PROFILE ]] && _CONTAINER_ARGS="--env PORTAGE_CONFIGROOT=/usr/${TARGET}" run_in_container "eselect" profile set --force "${PROFILE}"
	run_in_container "${TARGET}-emerge" -v @system
fi
