FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04
RUN apt-get update && apt-get install -y --no-install-recommends nodejs && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/node-baseline && command -v node > /opt/node-baseline/path && node --version > /opt/node-baseline/version && sha256sum /usr/bin/node > /opt/node-baseline/checksum
RUN ! command -v npm
