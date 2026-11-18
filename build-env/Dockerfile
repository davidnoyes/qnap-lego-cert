# Build environment for qbuild (QNAP's QDK) on Linux.
FROM docker.io/library/ubuntu:24.04

ARG QDK_VERSION=2.5.3
# sha256 of the QDK 2.5.3 release .debs, checked before install.
ARG QDK_SHA256_amd64=17b3841b7d4590a4ee025844ba583304b5e3c497d9fa8934d5175131d3908022
ARG QDK_SHA256_arm64=4b00c009cb48c0ffa7e4b7b00c5a6a1982a0955d663c0c6ec57020353e68eeb9
# Set by BuildKit: amd64 or arm64 (QDK publishes a .deb for both).
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL -o /tmp/qdk.deb \
      "https://github.com/qnap-dev/QDK/releases/download/v${QDK_VERSION}/qdk_${QDK_VERSION}_${TARGETARCH}.deb" \
 && want=$(eval echo "\$QDK_SHA256_${TARGETARCH}") \
 && echo "${want}  /tmp/qdk.deb" | sha256sum -c - \
 && apt-get install -y --no-install-recommends /tmp/qdk.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/qdk.deb

WORKDIR /src
ENTRYPOINT ["qbuild"]
