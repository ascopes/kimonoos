#!/usr/bin/env bash

###
### Script for generating os-specific cross compilers using binutils, GCC, and GDB.
###
### Requires Docker.
###

set -o errexit
set -o nounset

source "$(dirname "${BASH_SOURCE[0]}")/libcrosscompiler.sh"

### DEFAULTS ##################################################################

readonly DEFAULT_ARCH="i686-elf"
readonly DEFAULT_BINUTILS_VERSION="2.42"
readonly DEFAULT_GCC_VERSION="13.2.0"
readonly DEFAULT_GDB_VERSION="14.1"

### USAGE #####################################################################

function buildgcc::usage {
  echo "USAGE: ${BASH_SOURCE[0]} <flags>"
  echo "Builds a GCC-based cross-compiler for a given platform, as well as "
  echo "the corresponding binutils and GDB distributions."
  echo
  echo "    --help                Show this message and exit."
  echo
  echo "Optional arguments:"
  echo "    --arch <name>               Set the architecture to build. Defaults to "
  echo "                                ${DEFAULT_ARCH}."
  echo "    --binutils <version>        Set the version of binutils to build."
  echo "                                Defaults to ${DEFAULT_BINUTILS_VERSION}."
  echo "    --force-rebuild-container   Force rebuild the container if it already"
  echo "                                exists."
  echo "    --gcc <version>             Set the version of GCC to build. Defaults"
  echo "                                to ${DEFAULT_GCC_VERSION}."
  echo "    --gdb <version>             Set the version of GDB to build. Defaults"
  echo "                                to ${DEFAULT_GDB_VERSION}."
}

### ARGUMENT PARSING ##########################################################

arch="${DEFAULT_ARCH}"
binutils_version="${DEFAULT_BINUTILS_VERSION}"
force_rebuild_container="false"
gcc_version="${DEFAULT_GCC_VERSION}"
gdb_version="${DEFAULT_GDB_VERSION}"

until [[ $# -eq 0 ]]; do
  case "${1}" in

    --arch)
      readonly arch="${2}"
      shift 17
      ;;

    --binutils)
      readonly binutils_version="${2}"
      shift 1
      ;;

    --force-rebuild-container)
      readonly force_rebuild_container="true"
      ;;

    --gcc)
      readonly gcc_version="${2}"
      shift 1
      ;;

    --gdb)
      readonly gdb_version="${2}"
      shift 1
      ;;

    -h|--help)
      usage
      exit 0
      ;;

    *)
      echo "ERROR: Unknown argument '${1}' provided..."
      usage
      exit 1
      ;;

  esac

  shift 1
done

### DIRECTORY NAMES ###########################################################

readonly BASE_DIR=target/
readonly SRC_DIR="src/"
readonly BIN_DIR="${arch}/bin/"

### FUNCTIONS #################################################################

function buildgcc::prepare_directories {
  crosscompiler::log "Preparing directories..."
  mkdir -vp "${BASE_DIR}" "${BASE_DIR}${SRC_DIR}" "${BASE_DIR}${BIN_DIR}"
}

function buildgcc::download_and_extract_xz {
  local url="${1?URL}"
  local tempfile=$(crosscompiler::exec_in_container mktemp)
  crosscompiler::exec_in_container curl --fail "${url}" -o "${tempfile}"
  crosscompiler::exec_in_container tar -C "${SRC_DIR}" -xf "${tempfile}"
}

function buildgcc::build_binutils {
  buildgcc::download_and_extract_xz "https://ftp.gnu.org/gnu/binutils/binutils-${binutils_version}.tar.xz"
  crosscompiler::exec_in_container \
      --env "SRC_DIR=${SRC_DIR}binutils-${binutils_version}" \
      --env "BIN_DIR=${BIN_DIR}" \
      --env "TARGET=${arch}" \
      /bin/bash -o errexit -o xtrace -c '
        export PREFIX="$(pwd)/${TARGET}"
        BASEDIR=$(pwd)
        trap '"'"'mv config.log "${BASEDIR}/binutils-config.log"'"'"' EXIT INT TERM

        cd "$(mktemp -d)"
        "${BASEDIR}/${SRC_DIR}/configure" \
            --target "${TARGET}" \
            --prefix "${PREFIX}" \
            --with-sysroot \
            --disable-nls \
            --disable-werror

        make -j16
        make install
      '
}

function buildgcc::build_gcc {
  buildgcc::download_and_extract_xz "https://ftp.gnu.org/gnu/gcc/gcc-${gcc_version}/gcc-${gcc_version}.tar.xz"
  crosscompiler::exec_in_container \
      --env "SRC_DIR=${SRC_DIR}gcc-${gcc_version}" \
      --env "BIN_DIR=${BIN_DIR}" \
      --env "TARGET=${arch}" \
      /bin/bash -o errexit -o xtrace -c '
        export PREFIX="$(pwd)/${TARGET}"
        BASEDIR=$(pwd)
        trap '"'"'mv config.log "${BASEDIR}/gcc-config.log"'"'"' EXIT INT TERM

        cd "$(mktemp -d)"
        "${BASEDIR}/${SRC_DIR}/configure" \
            --target "${TARGET}" \
            --prefix "${PREFIX}" \
            --enable-languages=c,c++ \
            --without-headers \
            --disable-nls \
            --disable-werror

        make -j16 all-gcc
        make -j16 all-target-libgcc
        make install-gcc
        make install-target-libgcc
      '
}

function buildgcc::build_gdb {
  buildgcc::download_and_extract_xz "https://ftp.gnu.org/gnu/gdb/gdb-${gdb_version}.tar.xz"
  crosscompiler::exec_in_container \
      --env "SRC_DIR=${SRC_DIR}gdb-${gdb_version}" \
      --env "BIN_DIR=${BIN_DIR}" \
      --env "TARGET=${arch}" \
      /bin/bash -o errexit -o xtrace -c '
        export PREFIX="$(pwd)/${TARGET}"
        BASEDIR=$(pwd)
        trap '"'"'mv config.log "${BASEDIR}/gdb-config.log"'"'"' EXIT INT TERM

        cd "$(mktemp -d)"
        "${BASEDIR}/${SRC_DIR}/configure" \
            --target "${TARGET}" \
            --prefix "${PREFIX}" \
            --disable-nls \
            --disable-werror

        make -j16 all-gdb
        make install-gdb
      '
}

### ENTRYPOINT ################################################################

buildgcc::prepare_directories

crosscompiler::build_container_if_exists "${force_rebuild_container}"

readonly container_id=$(crosscompiler::start_container "$(crosscompiler::abspath "${BASE_DIR}")")
trap 'crosscompiler::stop_container' EXIT INT TERM

buildgcc::build_binutils
buildgcc::build_gcc
buildgcc::build_gdb
