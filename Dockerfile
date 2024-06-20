FROM golang:latest

# Set build arguments with default values
ARG VERSION="none"
ARG BUILD="none"
ARG TIME="none"
ARG GOPROXY=http://yum-repo.vpn.versity.com:4000

# Set environment variables
ENV VERSION=${VERSION}
ENV BUILD=${BUILD}
ENV TIME=${TIME}
ENV GOPROXY=${GOPROXY}

ENV CGO_ENABLED=0
RUN go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest

COPY fencing/fence-remote-host /scoutfs-fencing/
COPY fencing/README.md /scoutfs-fencing/

COPY package.sh /

ENTRYPOINT [ "/bin/bash" ]
