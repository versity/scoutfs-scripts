#!/usr/bin/env bash

export PATH="/go/bin:${PATH}"

cd /scoutfs-fencing && nfpm pkg --packager rpm --conf /scoutfs-fencing/nfpm.yaml --target /package
