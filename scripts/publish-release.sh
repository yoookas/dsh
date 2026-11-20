#!/usr/bin/env bash
# 创建 / 更新 GitHub Release 并上传镜像 tar 包。
#
# 只依赖 curl + jq，不依赖 gh CLI。
# 已存在同名 Release 时复用；同名附件先删除再上传，保证可重复执行。
#
# 需要环境变量：
#   GITHUB_TOKEN       有 contents:write 的 token
#   GITHUB_REPOSITORY  owner/repo
#   RELEASE_TAG        Release tag（与上游 tag 对齐）
#   RELEASE_NAME       Release 标题（可选，默认同 tag）
#   RELEASE_BODY_FILE  说明文件路径（可选）
#   ASSET_DIR          附件目录（上传其中的 *.tar.gz / SHA256SUMS.txt）
#   PRERELEASE         true/false（可选，默认 false）
#   PRUNE_ASSETS       1 时删除同一 Release 里本次没有上传的旧附件
#   DRY_RUN            1 时只打印将执行的操作
set -euo pipefail

: "${GITHUB_TOKEN:?缺少 GITHUB_TOKEN}"
: "${GITHUB_REPOSITORY:?缺少 GITHUB_REPOSITORY}"
: "${RELEASE_TAG:?缺少 RELEASE_TAG}"

RELEASE_NAME="${RELEASE_NAME:-$RELEASE_TAG}"
PRERELEASE="${PRERELEASE:-false}"
ASSET_DIR="${ASSET_DIR:-dist}"
PRUNE_ASSETS="${PRUNE_ASSETS:-0}"
DRY_RUN="${DRY_RUN:-0}"

API="https://api.github.com/repos/${GITHUB_REPOSITORY}"
AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}"
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28")

log() { printf '[release] %s\n' "$*"; }

BODY_JSON='""'
if [ -n "${RELEASE_BODY_FILE:-}" ] && [ -f "$RELEASE_BODY_FILE" ]; then
  BODY_JSON="$(jq -Rs . < "$RELEASE_BODY_FILE")"
fi

# ── 0. 干跑：只打印计划，不访问网络 ────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  shopt -s nullglob
  FILES=("$ASSET_DIR"/*.tar.gz "$ASSET_DIR"/SHA256SUMS.txt)
  shopt -u nullglob
  [ "${#FILES[@]}" -gt 0 ] || { echo '[release] 没有可上传的附件' >&2; exit 1; }

# 清理改名/换架构后遗留在同一个 Release 里的旧附件
if [ "$PRUNE_ASSETS" = '1' ]; then
  KEEP="$(for f in "${FILES[@]}"; do basename "$f"; done)"
  jq -r '.assets[]? | "\(.id) \(.name)"' "$TMP/release.json" 2>/dev/null \
    | while read -r asset_id asset_name; do
        [ -n "$asset_id" ] || continue
        if ! printf '%s\n' "$KEEP" | grep -qx -- "$asset_name"; then
          log "删除过期附件 ${asset_name}（id=${asset_id}）"
          curl -sS -o /dev/null -X DELETE "${AUTH[@]}" "${API}/releases/assets/${asset_id}" || true
        fi
      done
fi
  log "DRY_RUN：将创建/更新 Release ${RELEASE_TAG}（prerelease=${PRERELEASE}）"
  for f in "${FILES[@]}"; do
    log "  + 上传 $(basename "$f")（$(du -h "$f" | cut -f1)）"
  done
  exit 0
fi

# ── 1. 查找已有 Release ────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HTTP="$(curl -sS -o "$TMP/release.json" -w '%{http_code}' "${AUTH[@]}" \
  "${API}/releases/tags/${RELEASE_TAG}")"

if [ "$HTTP" = "200" ]; then
  log "Release ${RELEASE_TAG} 已存在，复用"
elif [ "$HTTP" = "404" ]; then
  log "创建 Release ${RELEASE_TAG}"
  curl -sS -o "$TMP/release.json" -X POST "${AUTH[@]}" \
    -H 'Content-Type: application/json' \
    --data "$(jq -n \
      --arg tag "$RELEASE_TAG" \
      --arg name "$RELEASE_NAME" \
      --argjson body "$BODY_JSON" \
      --arg sha "${GITHUB_SHA:-}" \
      --argjson pre "$PRERELEASE" \
      '{tag_name:$tag, name:$name, body:$body,
        target_commitish:(if $sha == "" then "main" else $sha end),
        draft:false, prerelease:$pre}')" \
    "${API}/releases" >/dev/null
  curl -sS -o "$TMP/release.json" "${AUTH[@]}" "${API}/releases/tags/${RELEASE_TAG}"
else
  echo "[release] 查询 Release 失败（HTTP $HTTP）：" >&2
  cat "$TMP/release.json" >&2
  exit 1
fi

RELEASE_ID="$(jq -r '.id' "$TMP/release.json")"
UPLOAD_URL="$(jq -r '.upload_url' "$TMP/release.json" | sed 's/{.*}//')"
[ -n "$RELEASE_ID" ] && [ "$RELEASE_ID" != "null" ] || { echo '[release] 响应里没有 release id' >&2; exit 1; }

log "Release id=${RELEASE_ID}"

# 已存在的 Release 也要更新标题/说明（改名或改文案后重新发布会用到）
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  --data "$(jq -n --arg name "$RELEASE_NAME" --argjson body "$BODY_JSON" \
    '{name:$name, body:$body}')" \
  "${API}/releases/${RELEASE_ID}")"
[ "$HTTP" = "200" ] || log "警告：更新 Release 说明失败（HTTP ${HTTP}）"

# ── 2. 上传附件 ────────────────────────────────────────────────────────
shopt -s nullglob
FILES=("$ASSET_DIR"/*.tar.gz "$ASSET_DIR"/SHA256SUMS.txt)
shopt -u nullglob

[ "${#FILES[@]}" -gt 0 ] || { echo '[release] 没有可上传的附件' >&2; exit 1; }

# 清理改名/换架构后遗留在同一个 Release 里的旧附件
if [ "$PRUNE_ASSETS" = '1' ]; then
  KEEP="$(for f in "${FILES[@]}"; do basename "$f"; done)"
  jq -r '.assets[]? | "\(.id) \(.name)"' "$TMP/release.json" 2>/dev/null \
    | while read -r asset_id asset_name; do
        [ -n "$asset_id" ] || continue
        if ! printf '%s\n' "$KEEP" | grep -qx -- "$asset_name"; then
          log "删除过期附件 ${asset_name}（id=${asset_id}）"
          curl -sS -o /dev/null -X DELETE "${AUTH[@]}" "${API}/releases/assets/${asset_id}" || true
        fi
      done
fi

for file in "${FILES[@]}"; do
  name="$(basename "$file")"
  size="$(du -h "$file" | cut -f1)"
  existing_id="$(jq -r --arg n "$name" '.assets[]? | select(.name==$n) | .id' "$TMP/release.json" | head -n 1)"
  if [ -n "$existing_id" ]; then
    log "删除同名旧附件 ${name}（id=${existing_id}）"
    curl -sS -o /dev/null -X DELETE "${AUTH[@]}" "${API}/releases/assets/${existing_id}" || true
  fi

  log "上传 ${name}（${size}）..."
  # 用 --upload-file 流式上传，避免把几百 MB 的镜像包整个读进内存
  HTTP="$(curl -sS --retry 3 --retry-delay 5 -o "$TMP/upload.json" -w '%{http_code}' \
    -X POST "${AUTH[@]}" \
    -H 'Content-Type: application/octet-stream' \
    --upload-file "$file" \
    "${UPLOAD_URL}?name=$(jq -rn --arg n "$name" '$n|@uri')")"
  if [ "$HTTP" != "201" ]; then
    echo "[release] 上传 ${name} 失败（HTTP $HTTP）：" >&2
    cat "$TMP/upload.json" >&2
    exit 1
  fi
  log "上传完成：$(jq -r '.browser_download_url' "$TMP/upload.json")"
done

log "Release 已发布：https://github.com/${GITHUB_REPOSITORY}/releases/tag/${RELEASE_TAG}"
