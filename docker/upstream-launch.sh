#!/bin/sh
# 上游镜像默认启动命令的兜底版本。
#
# 正式构建时，scripts/gen-launcher.sh 会读取真实镜像的
# .Config.Entrypoint / .Config.Cmd 重新生成同名文件（覆盖本文件），
# 所以上游改了入口也不会失效。这里只是保证「没有 docker 的环境也能直接 build」。
#
# 当前上游（smanx/deepseek-harness）的 ENTRYPOINT 为 /app/entrypoint.sh。
exec /app/entrypoint.sh "$@"
