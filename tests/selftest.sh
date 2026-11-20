#!/usr/bin/env bash
# 纯本地自测：不依赖 docker、不联网（curl 用 mock 替换）。
# CI 的 lint job 会跑这个脚本。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

check_eq() { # 期望 实际 描述
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3（期望 [$1]，实际 [$2]）"; fi
}

check_contains() { # 文件 子串 描述
  if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3（$1 里没有 [$2]）"; fi
}

echo '== gen-launcher：上游有 ENTRYPOINT =='
mkdir -p "$TMP/bin"
cat > "$TMP/app.sh" <<'EOF'
#!/bin/sh
printf 'ARGS:'; for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'
EOF
chmod +x "$TMP/app.sh"

printf '["%s/app.sh"]' "$TMP" > "$TMP/ep1.json"
echo 'null' > "$TMP/cmd1.json"
ENTRYPOINT_JSON_FILE="$TMP/ep1.json" CMD_JSON_FILE="$TMP/cmd1.json" \
  bash "$ROOT/scripts/gen-launcher.sh" --from-files "$TMP/out1.sh" >/dev/null 2>&1
check_contains "$TMP/out1.sh" "exec '$TMP/app.sh' \"\$@\"" '入口桥接追加参数'
if sh "$TMP/out1.sh" a 'b c' 2>/dev/null | grep -qx 'ARGS:\[a\]\[b c\]'; then
  ok '参数原样透传（含空格）'
else
  bad '参数透传错误'
fi

echo '== gen-launcher：上游只有 CMD =='
echo 'null' > "$TMP/ep2.json"
printf '["%s/app.sh","--default"]' "$TMP" > "$TMP/cmd2.json"
ENTRYPOINT_JSON_FILE="$TMP/ep2.json" CMD_JSON_FILE="$TMP/cmd2.json" \
  bash "$ROOT/scripts/gen-launcher.sh" --from-files "$TMP/out2.sh" >/dev/null 2>&1
check_contains "$TMP/out2.sh" 'set --' '无入口时用 CMD 兜底'
if sh "$TMP/out2.sh" 2>/dev/null | grep -qx 'ARGS:\[--default\]'; then
  ok '无参数时执行默认 CMD'
else
  bad '默认 CMD 未执行'
fi

echo '== gen-launcher：单引号路径安全转义 =='
printf '["/tmp/it'"'"'s.sh","a b"]' > "$TMP/ep3.json"
echo '[]' > "$TMP/cmd3.json"
ENTRYPOINT_JSON_FILE="$TMP/ep3.json" CMD_JSON_FILE="$TMP/cmd3.json" \
  bash "$ROOT/scripts/gen-launcher.sh" --from-files "$TMP/out3.sh" >/dev/null 2>&1
if sh -n "$TMP/out3.sh" 2>/dev/null; then ok '生成脚本语法合法'; else bad '生成脚本语法错误'; fi
check_contains "$TMP/out3.sh" "'/tmp/it'\\''s.sh'" '单引号已转义'

echo '== upstream-fingerprint：版本模式 =='
mkdir -p "$TMP/mock"
cat > "$TMP/mock/curl" <<'MOCK'
#!/usr/bin/env bash
for last; do :; done
url="$last"
LIST='{"results":[{"name":"0.2.2-rc.5"},{"name":"0.2.2-rc.4"},{"name":"0.1.9"},{"name":"devtools-0.2.2-rc.5"},{"name":"latest"}],"next":"https://hub.docker.com/v2/repositories/x/y/tags/?page=2"}'
TAGV='{"name":"devtools-0.2.2-rc.5","digest":"sha256:aaaa","last_updated":"2026-11-20T10:00:00Z","images":[]}'
TAGL='{"name":"devtools-latest","digest":null,"last_updated":"2026-11-20T10:00:00Z","images":[{"os":"linux","architecture":"amd64","digest":"sha256:cccc"}]}'
case "$url" in
  *page=2*) echo '{"results":[],"next":null}' ;;
  *"/tags/?page_size"*) echo "$LIST" ;;
  *"/tags/devtools-0.2.2-rc.5/") echo "$TAGV" ;;
  *"/tags/devtools-latest/") echo "$TAGL" ;;
  *"/tags/0.2.2-rc.5/") echo '{"name":"0.2.2-rc.5","digest":"sha256:plain","images":[]}' ;;
  *"/tags/latest/") echo '{"name":"latest","digest":"sha256:plainlatest","images":[]}' ;;
  *) echo '{"message":"not found"}' ;;
esac
MOCK
chmod +x "$TMP/mock/curl"

OUT="$(PATH="$TMP/mock:$PATH" UPSTREAM_TRACK=version UPSTREAM_TAG=latest \
  bash "$ROOT/scripts/upstream-fingerprint.sh" 2>/dev/null)"
check_eq "devtools-0.2.2-rc.5" "$(jq -r '.tag' <<<"$OUT")" '版本模式选中最高 devtools 版本'
check_eq "version" "$(jq -r '.mode' <<<"$OUT")" '模式标记正确'
check_eq "sha256:aaaa" "$(jq -r '.digest' <<<"$OUT")" '摘要取自 tag 接口'

echo '== upstream-fingerprint：tag 模式（digest 为 null）=='
OUT="$(PATH="$TMP/mock:$PATH" UPSTREAM_TRACK=tag UPSTREAM_TAG=devtools-latest \
  bash "$ROOT/scripts/upstream-fingerprint.sh" 2>/dev/null)"
check_eq "devtools-latest" "$(jq -r '.tag' <<<"$OUT")" 'tag 模式沿用指定 tag'
check_eq "linux/amd64:sha256:cccc" "$(jq -r '.digest' <<<"$OUT")" '多架构摘要正确拼接'

echo '== upstream-fingerprint：前缀置空时匹配纯版本号 =='
OUT="$(PATH="$TMP/mock:$PATH" UPSTREAM_TAG_PREFIX=none UPSTREAM_TRACK=version \
  bash "$ROOT/scripts/upstream-fingerprint.sh" 2>/dev/null)"
check_eq "0.2.2-rc.5" "$(jq -r '.tag' <<<"$OUT")" '空前缀下匹配纯版本 tag'

echo '== upstream-fingerprint：tag 不存在 =='
PATH="$TMP/mock:$PATH" UPSTREAM_TRACK=tag UPSTREAM_TAG=devtools-nope \
  bash "$ROOT/scripts/upstream-fingerprint.sh" >/dev/null 2>&1
check_eq "3" "$?" '不存在的 tag 返回 3'

echo '== publish-release：dry-run 不联网 =='
mkdir -p "$TMP/dist"
head -c 64 /dev/urandom > "$TMP/dist/dsh-0.0.1-linux-amd64.tar.gz"
(cd "$TMP/dist" && sha256sum ./*.tar.gz > SHA256SUMS.txt)
OUT="$(GITHUB_TOKEN=dummy GITHUB_REPOSITORY=owner/repo RELEASE_TAG=0.0.1 \
  ASSET_DIR="$TMP/dist" DRY_RUN=1 bash "$ROOT/scripts/publish-release.sh" 2>&1)"
check_eq "0" "$?" 'dry-run 退出码为 0'
check_contains <(printf '%s' "$OUT") '上传 dsh-0.0.1-linux-amd64.tar.gz' '列出待上传附件'

echo '== make-release-notes =='
NOTES="$(RELEASE_TAG=0.0.1 ASSET_DIR="$TMP/dist" bash "$ROOT/scripts/make-release-notes.sh")"
# shellcheck disable=SC2016  # 反引号是 markdown，不是命令替换
if grep -q 'dsh `0.0.1`' <<<"$NOTES"; then ok '说明包含版本号'; else bad '说明缺少版本号'; fi

echo
printf '通过 %d，失败 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
