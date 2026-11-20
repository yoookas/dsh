#!/usr/bin/env bash
# 读取上游镜像的 ENTRYPOINT / CMD，生成桥接脚本 docker/upstream-launch.sh。
#
# 为什么需要它：Dockerfile 里 FROM 之后只要重新声明 ENTRYPOINT，
# 继承来的 CMD 就会被重置，而 Dockerfile 无法读取父镜像的启动配置。
# 因此由构建流程在 build 之前用 docker image inspect 取出真实配置并落成脚本。
#
# 用法：
#   bash scripts/gen-launcher.sh <image> [out-file]
#   ENTRYPOINT_JSON_FILE=/tmp/ep.json CMD_JSON_FILE=/tmp/cmd.json \
#     bash scripts/gen-launcher.sh --from-files [out-file]      # 单元测试用
set -euo pipefail

log() { printf '[gen-launcher] %s\n' "$*" >&2; }

image="${1:-${BASE_IMAGE:-smanx/deepseek-harness:latest}}"
out="${2:-docker/upstream-launch.sh}"

# 单引号安全转义，产出 POSIX sh 可用的字面量
shquote() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# 从 docker 读取配置；读不到时给空数组
read_json_field() {
  local expr=$1
  docker image inspect "$image" --format "{{json ${expr}}}" 2>/dev/null || printf 'null'
}

if [ "${1:-}" = "--from-files" ]; then
  out="${2:-docker/upstream-launch.sh}"
  entrypoint_json="$(cat "${ENTRYPOINT_JSON_FILE:?需要 ENTRYPOINT_JSON_FILE}")"
  cmd_json="$(cat "${CMD_JSON_FILE:?需要 CMD_JSON_FILE}")"
  image="(from files)"
else
  if ! command -v docker >/dev/null 2>&1; then
    log "本机没有 docker，保留仓库自带的兜底脚本：$out"
    exit 0
  fi
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "本地没有镜像 $image，尝试拉取 ..."
    docker pull "$image" >/dev/null || { log "拉取失败，保留兜底脚本"; exit 0; }
  fi
  entrypoint_json="$(read_json_field '.Config.Entrypoint')"
  cmd_json="$(read_json_field '.Config.Cmd')"
fi

normalize() {
  local raw=$1
  if [ -z "$raw" ] || [ "$raw" = "null" ] || [ "$raw" = "[]" ]; then
    printf '[]'
  else
    printf '%s' "$raw"
  fi
}

entrypoint_json="$(normalize "$entrypoint_json")"
cmd_json="$(normalize "$cmd_json")"

mapfile -t entrypoint < <(printf '%s' "$entrypoint_json" | jq -r '.[]')
mapfile -t cmd < <(printf '%s' "$cmd_json" | jq -r '.[]')

join_quoted() {
  local first=1 item
  for item in "$@"; do
    [ "$first" -eq 1 ] || printf ' '
    shquote "$item"
    first=0
  done
}

{
  printf '#!/bin/sh\n'
  printf '# 由 scripts/gen-launcher.sh 在构建期生成，请勿手工修改。\n'
  printf '# 上游镜像 : %s\n' "$image"
  printf '# ENTRYPOINT: %s\n' "$entrypoint_json"
  printf '# CMD       : %s\n' "$cmd_json"
  printf '#\n'
  printf '# 无参数 -> 运行上游默认命令；有参数 -> 把参数追加给上游 ENTRYPOINT。\n'
  if [ "${#entrypoint[@]}" -gt 0 ]; then
    printf 'exec %s "$@"\n' "$(join_quoted "${entrypoint[@]}")"
  elif [ "${#cmd[@]}" -gt 0 ]; then
    printf 'if [ "$#" -eq 0 ]; then\n'
    printf '  set -- %s\n' "$(join_quoted "${cmd[@]}")"
    printf 'fi\n'
    printf 'exec "$@"\n'
  else
    printf 'if [ "$#" -gt 0 ]; then exec "$@"; fi\n'
    printf 'echo "上游镜像未定义启动命令" >&2\n'
    printf 'exit 0\n'
  fi
} > "$out"

chmod 0755 "$out"
log "已生成 $out"
log "  上游 ENTRYPOINT: $entrypoint_json"
log "  上游 CMD       : $cmd_json"
