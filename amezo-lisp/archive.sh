#!/bin/sh
# 使い方: sh archive.sh 板名… | --all [--quiet=秒] [--limit=件数] [--dry-run] [-v]
#         sh archive.sh --restore 板名 oN
#         sh archive.sh --selftest [板名]
cd "$(dirname "$0")" || exit 1
exec sbcl --script amezo.lisp archive "$@"
