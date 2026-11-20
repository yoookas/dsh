#!/usr/bin/env bash
# 计算上游镜像的「指纹」，用于判断是否有新版本。
#
# 两种模式（环境变量 UPSTREAM_TRACK）：
#   version ——（默认）在全部 tag 里挑最高版本号（如 0.2.2-rc.5），
#              出现更高版本就重建；发布的 Release tag 直接沿用该版本号；
#   tag     —— 盯住某个固定 tag（默认 latest），manifest 变了就重建。
#   version 模式下若找不到版本号形式的 tag，会自动回退到 tag 模式。
#
# 输出（stdout，JSON 单行）：
#   {"repository":"smanx/deepseek-harness","tag":"0.2.2-rc.5","mode":"version",
#    "digest":"sha256:...","fingerprint":"...","last_updated":"...","source":"hub-api"}
#
# 退出码：
#   0 成功；2 参数错误；3 找不到 tag；4 网络/接口不可用
set -euo pipefail

REPO="${UPSTREAM_REPO:-smanx/deepseek-harness}"
# 前缀：未设置时默认 devtools；设为空或 none 则匹配纯版本号（0.2.2-rc.5）
PREFIX="${UPSTREAM_TAG_PREFIX-devtools}"
if [ "$PREFIX" = "none" ]; then
  PREFIX=''
fi
if [ -n "$PREFIX" ]; then
  TAG="${UPSTREAM_TAG:-${PREFIX}-latest}"
else
  TAG="${UPSTREAM_TAG:-latest}"
fi
MODE="${UPSTREAM_TRACK:-version}"
HUB_API="https://hub.docker.com/v2/repositories/${REPO}"

log() { printf '[upstream] %s\n' "$*" >&2; }

CURL_OPTS=(
  --silent --show-error --location
  --connect-timeout 10 --max-time 40
  --retry 3 --retry-delay 2 --retry-connrefused
  -H 'Accept: application/json'
  -H 'User-Agent: deepseek-harness-ssh-watcher/1.0'
)
if [ -n "${DOCKERHUB_USER:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
  CURL_OPTS+=(-u "${DOCKERHUB_USER}:${DOCKERHUB_TOKEN}")
fi

hub_get() { curl "${CURL_OPTS[@]}" "$1"; }

# 从 tag JSON 里取 manifest 摘要；多架构 tag 的顶层 digest 可能为空，
# 退化用各平台镜像摘要拼一个稳定值。
digest_of() {
  jq -r '
    if (.digest // "") != "" then .digest
    else [(.images // [])[] | "\(.os)/\(.architecture):\(.digest)"] | sort | join(",")
    end
  ' <<<"$1"
}

by_registry() {
  local ref="docker.io/${REPO}:${TAG}"
  command -v docker >/dev/null 2>&1 || return 1
  docker buildx version >/dev/null 2>&1 || return 1
  log "改用 docker buildx 直接读取 registry manifest"
  docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2>/dev/null \
    | jq -r '.digest // empty'
}

resolve_tag() {
  local tag="$1" raw digest
  log "查询 Docker Hub API：${REPO}:${tag}"
  if ! raw="$(hub_get "${HUB_API}/tags/${tag}/" 2>/dev/null)"; then
    log "tag 接口请求失败，尝试 registry 兜底"
    digest="$(by_registry || true)"
    [ -n "$digest" ] || return 4
    jq -n --arg repo "$REPO" --arg tag "$tag" --arg mode "$MODE" \
          --arg digest "$digest" --arg fp "$digest" --arg updated "" \
          --arg source "registry" \
      '{repository:$repo, tag:$tag, mode:$mode, digest:$digest, fingerprint:$fp,
        last_updated:$updated, source:$source}'
    return 0
  fi

  if [ "$(jq -r '.message // empty' <<<"$raw" 2>/dev/null)" != "" ]; then
    log "接口返回错误：$(jq -r '.message' <<<"$raw")"
    return 3
  fi

  digest="$(digest_of "$raw")"
  if [ -z "$digest" ]; then
    log "tag ${tag} 未返回可用摘要"
    return 3
  fi

  jq -n --arg repo "$REPO" --arg tag "$tag" --arg mode "$MODE" \
        --arg digest "$digest" --arg fp "$digest" \
        --arg updated "$(jq -r '.last_updated // ""' <<<"$raw")" \
        --arg source "hub-api" \
    '{repository:$repo, tag:$tag, mode:$mode, digest:$digest, fingerprint:$fp,
      last_updated:$updated, source:$source}'
}

list_tags() {
  local page=1 max_pages="${1:-5}" body next
  while [ "$page" -le "$max_pages" ]; do
    body="$(hub_get "${HUB_API}/tags/?page_size=100&ordering=last_updated&page=${page}" 2>/dev/null)" || return 1
    jq -r '.results[]?.name' <<<"$body"
    next="$(jq -r '.next // ""' <<<"$body")"
    [ -n "$next" ] || break
    page=$((page + 1))
  done
}

resolve_version() {
  local tags newest json pattern
  log "枚举 ${REPO} 的 tag，挑选最高版本号"
  if ! tags="$(list_tags 5)"; then
    log "tag 列表接口不可用"
    return 4
  fi
  [ -n "$tags" ] || { log "tag 列表为空"; return 3; }

  # 只认「<前缀>-语义化版本」，如 devtools-0.2.2-rc.5；
  # 前缀为空则匹配纯版本号（0.2.2-rc.5）
  if [ -n "$PREFIX" ]; then
    pattern="^${PREFIX}-[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$"
  else
    pattern='^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$'
  fi

  newest="$(printf '%s\n' "$tags" \
    | grep -E "$pattern" \
    | sed "s/^${PREFIX}-//" \
    | sort -V | tail -n 1 || true)"
  [ -n "$newest" ] || { log "没有匹配到 ${PREFIX}-<版本号> 形式的 tag"; return 3; }

  if [ -n "$PREFIX" ]; then
    newest="${PREFIX}-${newest}"
  fi
  log "最高版本 tag：$newest"

  json="$(resolve_tag "$newest")" || return $?
  # 版本模式下，指纹 = hash(版本号@摘要)，保证「同摘要换 tag」也能识别
  jq --arg fp "$(printf '%s@%s' "$newest" "$(jq -r '.digest' <<<"$json")" | sha256sum | awk '{print $1}')" \
     '.fingerprint = $fp | .mode = "version"' <<<"$json"
}

case "$MODE" in
  version)
    if ! resolve_version; then
      code=$?
      [ "$code" -eq 3 ] || exit "$code"
      log "回退到 tag 模式：${TAG}"
      MODE=tag resolve_tag "$TAG"
    fi
    ;;
  tag)
    resolve_tag "$TAG"
    ;;
  *)
    log "未知的 UPSTREAM_TRACK：$MODE（可选 version / tag）"
    exit 2
    ;;
esac
