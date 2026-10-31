#!/bin/sh
# 使い方: sh run.sh [--port 8000] [--tunnel] [--verbose]
#         sh run.sh --make-hash パスワード   (delpass.txt を作って終了)
#         sh run.sh --setup-tunnel           (cloudflared を用意して終了。--tunnel の事前準備)
cd "$(dirname "$0")" || exit 1
if [ "$1" = "--make-hash" ]; then
  exec sbcl --script amezo.lisp --make-delpass "$2"
fi
exec sbcl --script amezo.lisp "$@"
