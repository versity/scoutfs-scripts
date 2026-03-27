#!/usr/bin/env bash
set -ex

PULL="${PULL:-true}"
GOLANG_IMAGE_NAME="${GOLANG_IMAGE_NAME:-golang}"
GOLANG_IMAGE_VERSION="${GOLANG_IMAGE_VERSION:-latest}"

export VERSION
VERSION="$(git describe --tags)"

docker build --pull="${PULL}" \
    --build-arg "GOLANG_IMAGE_NAME=${GOLANG_IMAGE_NAME}" \
    --build-arg "GOLANG_IMAGE_VERSION=${GOLANG_IMAGE_VERSION}" \
    -t "versity-scripts:${VERSION}" .

docker run --rm -e "HOST_UID=${UID}" -e "VERSION=${VERSION}" -v "${PWD}/package:/package" "versity-scripts:${VERSION}"
