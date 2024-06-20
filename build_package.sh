#!/usr/bin/env bash
set -ex

export VERSION
VERSION="$(git describe --all)"

docker build -t versity-scripts:latest .

docker run --rm -e "VERSION=${VERSION}" -v /package:${PWD}/package supportbuilder:latest
