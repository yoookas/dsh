#!/bin/sh
# 构建期执行：安装 GitHub CLI（gh）。
# 优先用官方 apt 源（Debian/Ubuntu），失败再回退到官方 release 二进制包；
# Alpine / Fedora 走各自仓库。
set -eu

log() { printf '[install-gh] %s\n' "$*"; }

if command -v gh >/dev/null 2>&1; then
  log "已安装：$(gh --version | head -n 1)"
  exit 0
fi

# ── 通用兜底：下载官方静态二进制 ────────────────────────────────────────
install_from_release() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7)  arch="armv6" ;;
    *) log "不支持的架构：$arch"; return 1 ;;
  esac

  version="${GH_VERSION:-}"
  if [ -z "$version" ] || [ "$version" = "latest" ]; then
    version="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest 2>/dev/null \
      | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)"
  fi
  [ -n "$version" ] || { log "无法解析 gh 版本号"; return 1; }

  log "下载 gh v${version}（linux-${arch}）"
  tmp="$(mktemp -d)"
  if ! curl -fsSL "https://github.com/cli/cli/releases/download/v${version}/gh_${version}_linux_${arch}.tar.gz" \
       | tar -xz -C "$tmp"; then
    log "下载或解压失败"
    rm -rf "$tmp"
    return 1
  fi
  install -m 0755 "${tmp}/gh_${version}_linux_${arch}/bin/gh" /usr/local/bin/gh
  rm -rf "$tmp"
}

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl
  mkdir -p -m 0755 /etc/apt/keyrings
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; then
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list
    apt-get update || true
    apt-get install -y --no-install-recommends gh || log "apt 安装 gh 失败，改用二进制包"
  else
    log "官方 apt 源 key 下载失败，改用二进制包"
  fi
  rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache github-cli || install_from_release
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y gh || install_from_release
elif command -v microdnf >/dev/null 2>&1; then
  microdnf install -y gh || install_from_release
fi

if ! command -v gh >/dev/null 2>&1; then
  install_from_release || { echo "[install-gh] 错误：gh 安装失败" >&2; exit 1; }
fi

log "安装完成：$(gh --version | head -n 1)"
