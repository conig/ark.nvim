FROM rust:1.94-bookworm

ARG DEBIAN_FRONTEND=noninteractive
ARG NVIM_REF=v0.12.1

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    gettext \
    git \
    libssl-dev \
    libtool \
    libtool-bin \
    pkg-config \
    r-base \
    r-base-dev \
    r-cran-tidyverse \
    ripgrep \
    tmux \
    unzip \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${NVIM_REF}" https://github.com/neovim/neovim /tmp/neovim \
  && make -C /tmp/neovim CMAKE_BUILD_TYPE=RelWithDebInfo \
  && make -C /tmp/neovim install \
  && rm -rf /tmp/neovim

RUN cargo install --locked tree-sitter-cli --version 0.26.8 --no-default-features

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
ENV CARGO_HOME=/home/ark/.cargo
ENV R_HOME=/usr/lib/R
ENV LD_LIBRARY_PATH=/usr/lib/R/lib
ENV TERM=xterm-256color

RUN mkdir -p "${CARGO_HOME}"
RUN cargo build -p ark-lsp
RUN nvim --headless -u testing/readme-minimal/init.lua -c "Lazy! sync" -c "qa"
RUN ark-bootstrap-readme-parsers

ENTRYPOINT ["/usr/local/bin/ark-readme-test"]
CMD ["interactive"]
