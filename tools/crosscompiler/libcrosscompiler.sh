###
### Facilities for performing platform indepentent cross compilation...
###
### Source this script from another script to "import" the functions defined
### here...
###

function crosscompiler::abspath {
  cd "${1?}" && pwd
}

function crosscompiler::log {
  printf "\e[1;33m<%s>\e[0;35m %s\e[0m\n" "$(date)" "${1?}" >&2
}

function crosscompiler::container_exists {
  crosscompiler::log "Checking if build container exists..."
  docker image ls --format '{{.Repository}}:{{.Tag}}' \
      | grep -q "${_CONTAINER_NAME}:${_CONTAINER_TAG}"
}

function crosscompiler::build_container {
  crosscompiler::log "Creating container to use to build cross compiler..."

  docker build \
      --compress \
      --file "${_SCRIPT_DIR}/Dockerfile" \
      --force-rm \
      --no-cache \
      --tag "${_CONTAINER_NAME}:${_CONTAINER_TAG}" \
      - <<< "${_DOCKERFILE_CONTENT}"
}

function crosscompiler::build_container_if_exists {
  # $1 - "true" if forcing the rebuild of the container, "false" otherwise

  if ! crosscompiler::container_exists || [[ "${1?}" == "true" ]]; then
    crosscompiler::build_container
  fi
}

function crosscompiler::user {
  # stdout: uid:gid for the current user.
  local user_name="${USER?}"
  local uid
  uid=$(id -u "${user_name}")
  local gid
  gid=$(id -g "${user_name}")
  echo "${uid}:${gid}"
}

function crosscompiler::start_container {
  # Start the container and leave it in the background. That way we can exec
  # into it multiple times to run commands a little more easily than just passing
  # around singular uber-scripts.
  #
  # $1     - working directory to mount and cd into.
  # stdout - the container ID

  crosscompiler::log "Starting build container in the background to schedule tasks within..."

  local image="${_CONTAINER_NAME}:${_CONTAINER_TAG}"
  local volume="${1}:${_WORKING_DIR}"
  local uid_gid
  uid_gid=$(crosscompiler::user)

  local container_id
  container_id=$(docker run \
      --cgroupns host \
      --detach \
      --init \
      --quiet \
      --rm \
      --user "${uid_gid}" \
      --volume "${volume}:Z" \
      --workdir "${_WORKING_DIR}" \
      "${image}" \
      'sleep infinity')

  crosscompiler::log "Created container ${container_id}"
  echo "${container_id}"
}

function crosscompiler::stop_container {
  crosscompiler::log "Stopping the build container."
  docker stop "${container_id?}" &> /dev/null
}

function crosscompiler::exec_in_container {
  local envvars=()
  # Always expect at least one argument after the
  # env tags.
  while [[ "${1?}" == "--env" ]]; do
    envvars+=(--env "${2?}")
    shift 2
  done

  crosscompiler::log "Running ${*@Q}"
  # Word-split and quote within the same string...
  docker exec "${envvars[@]}" "${container_id?}" /bin/bash -o errexit -c "${*@Q}"
}

readonly _CONTAINER_NAME="io.github.ascopes/kimono/crosscompiler"
readonly _CONTAINER_TAG="latest"
readonly _DOCKERFILE_CONTENT=$(cat <<'EOF'
FROM public.ecr.aws/debian/debian:trixie-slim

RUN apt-get update -yq \
    && apt-get install -qy --no-install-recommends \
        bash \
        bison \
        build-essential \
        ca-certificates \
        curl \
        flex \
        gcc \
        libgmp3-dev \
        libmpc-dev \
        libmpfr-dev \
        tar \
        texinfo \
        xz-utils \
    && apt-get clean autoclean \
    && apt-get autoremove --yes \
    && rm -rf /var/lib/apt \
    && rm -rf /var/lib/dpkg \
    && rm -rf /var/lib/cache \
    && rm -rf /var/lib/log

ENTRYPOINT ["/bin/bash", "-c"]
CMD        ["uname -a && make --version && gcc --version"]
EOF
)
readonly _REQUIREMENTS=(cat docker grep)
readonly _SCRIPT_DIR=$(crosscompiler::abspath "$(dirname "${BASH_SOURCE[0]}")")
readonly _WORKING_DIR="/workspace/"

for _required_application in "${_REQUIREMENTS[@]}"; do
  if ! command -v "${_required_application}" &> /dev/null; then
    echo "ERROR: Please install ${_required_application} before continuing..." >&2
    exit 2
  fi
done

if [[ "${DEBUG:-0}" != 0 ]]; then
  set -o xtrace
fi

# Ensure we run from the directory using this script.
cd "${_SCRIPT_DIR}"
