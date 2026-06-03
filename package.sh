#!/usr/bin/env bash

export PATH="/go/bin:${PATH}"
HOST_UID="${HOST_UID:-$UID}"

nfpm pkg --packager rpm --config /scoutfs-fencing/nfpm.yaml --target /package
chown -R "${HOST_UID}" /package
