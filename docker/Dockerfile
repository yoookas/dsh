# syntax=docker/dockerfile:1.7
#
# deepseek-harness-ssh
# ────────────────────
# 在官方第三方镜像 smanx/deepseek-harness 之上加装 OpenSSH Server，
# root 密码由环境变量 SSH_ROOT_PASSWORD 在容器启动时注入（不打进镜像层）。
#
# 跟踪的上游变体：devtools-<版本>（自带 git/vim/python3/pnpm/uv 等，适合 SSH 进去干活）
#
# 上游镜像事实（2026-11 核对）：
#   * 基础镜像 node:24-slim（Debian 12 bookworm）
#   * WORKDIR /app，ENTRYPOINT ["/app/entrypoint.sh"]，默认监听 3080
#   * 以 root 运行
# 因此这里可以直接 apt-get 安装 openssh-server，并用 entrypoint 包裹上游入口。
#
# 本地构建：
#   bash scripts/gen-launcher.sh smanx/deepseek-harness:devtools-latest docker/upstream-launch.sh
#   docker build -f docker/Dockerfile -t dsh-ssh:local .

ARG BASE_IMAGE=smanx/deepseek-harness:devtools-latest

FROM ${BASE_IMAGE}

# 重新声明，供 LABEL / ENV 使用
ARG BASE_IMAGE
ARG SOURCE_URL=unknown
ARG BUILD_REVISION=dev
ARG BUILD_DATE=unknown
ARG UPSTREAM_VERSION=unknown

LABEL org.opencontainers.image.title="deepseek-harness-ssh" \
      org.opencontainers.image.description="DeepSeek Harness + OpenSSH Server；root 密码通过环境变量 SSH_ROOT_PASSWORD 注入" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      io.github.dsh-ssh.base-image="${BASE_IMAGE}"

# 上游若将来改成非 root，这里强制回到 root，否则装不了包也起不了 sshd
USER root

# ── 1. 安装 OpenSSH Server（apt / apk / dnf 自适应）────────────────────
COPY docker/install-openssh.sh /usr/local/bin/dsh-install-openssh.sh
RUN chmod 0755 /usr/local/bin/dsh-install-openssh.sh \
 && /usr/local/bin/dsh-install-openssh.sh

# ── 2. GitHub CLI（gh）：devtools 变体自带 git/curl，这里补上 gh ─────────
COPY docker/install-gh.sh /usr/local/bin/dsh-install-gh.sh
RUN chmod 0755 /usr/local/bin/dsh-install-gh.sh \
 && /usr/local/bin/dsh-install-gh.sh

# ── 3. 启动脚本 / 健康检查 / 上游入口桥接 ──────────────────────────────
COPY docker/entrypoint.sh /usr/local/bin/dsh-ssh-entrypoint.sh
COPY docker/healthcheck.sh /usr/local/bin/dsh-ssh-healthcheck.sh
COPY docker/upstream-launch.sh /usr/local/bin/dsh-upstream-launch.sh
RUN chmod 0755 /usr/local/bin/dsh-ssh-entrypoint.sh \
                /usr/local/bin/dsh-ssh-healthcheck.sh \
                /usr/local/bin/dsh-upstream-launch.sh

# ── 4. 运行参数默认值（均可在 docker run -e 覆盖）──────────────────────
ENV SSH_ENABLED=true \
    SSH_PORT=22 \
    SSH_LISTEN_ADDRESS=0.0.0.0 \
    SSH_PERMIT_ROOT_LOGIN=yes \
    SSH_PASSWORD_AUTHENTICATION=auto \
    DSH_APP_ENABLED=true

# 22 = sshd；3080 由上游 EXPOSE 声明并自动继承
EXPOSE 22

# 上游 WORKDIR 为 /app，这里显式声明一次，保证 SSH 登录后与容器内目录一致
WORKDIR /app

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/dsh-ssh-healthcheck.sh"]

# 注意：设置 ENTRYPOINT 会重置继承来的 CMD，因此上游的启动命令
# 由 /usr/local/bin/dsh-upstream-launch.sh 在构建期捕获并保存（见 scripts/gen-launcher.sh）。
ENTRYPOINT ["/usr/local/bin/dsh-ssh-entrypoint.sh"]
