#!/usr/bin/env bash
# 从上游镜像里读出 DSH 的版本号，供构建时写进镜像 tag / label。
# 读不到就输出 unknown，绝不失败（不阻断构建）。
set -uo pipefail

IMAGE="${1:-${BASE_IMAGE:-smanx/deepseek-harness:latest}}"
VERSION=""

if command -v docker >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
  VERSION="$(docker run --rm --entrypoint sh "$IMAGE" -c '
    if [ -r /tmp/app_version.env ]; then
      grep -o "APP_VERSION=.*" /tmp/app_version.env 2>/dev/null | head -n 1 | sed "s/APP_VERSION=//"
    fi
    for p in /opt/dsh/lib/node_modules/@deepseek-ai/dsh/package.json \
             /usr/local/lib/node_modules/@deepseek-ai/dsh/package.json; do
      if [ -r "$p" ]; then
        node -p "require(\"$p\").version" 2>/dev/null
        break
      fi
    done
  ' 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
fi

case "$VERSION" in
  ''|*[!0-9A-Za-z.+-]*) VERSION="unknown" ;;
esac

printf 'app_version=%s\n' "${VERSION:-unknown}"
