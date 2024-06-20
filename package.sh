#!/usr/bin/env bash

export PATH="/go/bin:${PATH}"

nfpm pkg --packager rpm --conf /scoutfs-fencing/nfpm.yaml --target /package
