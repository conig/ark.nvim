FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG NVIM_REF=v0.12.1
ARG TREE_SITTER_VERSION=v0.26.8

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    python3 \
    r-base \
    r-base-dev \
    r-cran-data.table \
    r-cran-jsonlite \
    ripgrep \
    tmux \
    unzip \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --silent --show-error \
    "https://github.com/neovim/neovim/releases/download/${NVIM_REF}/nvim-linux-x86_64.tar.gz" \
    --output /tmp/nvim.tar.gz \
  && tar -C /opt -xzf /tmp/nvim.tar.gz \
  && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim \
  && rm -f /tmp/nvim.tar.gz

RUN curl --fail --location --silent --show-error \
    "https://github.com/tree-sitter/tree-sitter/releases/download/${TREE_SITTER_VERSION}/tree-sitter-linux-x64.gz" \
    --output /tmp/tree-sitter.gz \
  && gzip -d /tmp/tree-sitter.gz \
  && install -m 755 /tmp/tree-sitter /usr/local/bin/tree-sitter \
  && rm -f /tmp/tree-sitter

RUN useradd --create-home --shell /bin/bash ark \
  && install -d -o ark -g ark /work/ark.nvim

WORKDIR /work/ark.nvim
COPY --chown=ark:ark . /work/ark.nvim
COPY --chown=ark:ark docker/readme-minimal/bootstrap-parsers.sh /usr/local/bin/ark-bootstrap-readme-parsers
COPY --chown=ark:ark docker/readme-minimal/entrypoint.sh /usr/local/bin/ark-readme-test
COPY --chown=ark:ark docker/readme-minimal/run-smoke.sh /usr/local/bin/ark-readme-test-smoke
COPY --chown=ark:ark docker/readme-minimal/smoke-session.sh /usr/local/bin/ark-readme-test-smoke-session

RUN chmod 755 \
  /usr/local/bin/ark-bootstrap-readme-parsers \
  /usr/local/bin/ark-readme-test \
  /usr/local/bin/ark-readme-test-smoke \
  /usr/local/bin/ark-readme-test-smoke-session

USER ark

ENV HOME=/home/ark
ENV R_HOME=/usr/lib/R
ENV LD_LIBRARY_PATH=/usr/lib/R/lib
ENV TERM=xterm-256color
ENV ARK_NVIM_INSTALL_ROOT=/home/ark/.local/share/nvim/ark

RUN asset=$(find dist/readme -maxdepth 1 -type f -name 'ark-lsp-*' ! -name '*.sha256' -print -quit) \
  && test -n "${asset}" \
  && scripts/install-release.sh install \
    --version "$(python3 -c 'import json; print(json.load(open("release-manifest.json"))["product_version"])')" \
    --target "$(python3 -c 'import json; print(json.load(open("release-manifest.json"))["release_targets"][0]["rust_target"])')" \
    --asset-url "file:///work/ark.nvim/${asset}" \
    --checksum-url "file:///work/ark.nvim/${asset}.sha256" \
    --install-root "${HOME}/.local/share/nvim/ark"
RUN ! command -v cargo && ! command -v rustc
RUN nvim --headless -u testing/readme-minimal/init.lua -c "Lazy! sync" -c "qa"
RUN ark-bootstrap-readme-parsers

ENTRYPOINT ["/usr/local/bin/ark-readme-test"]
CMD ["interactive"]
