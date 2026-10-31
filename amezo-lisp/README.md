# amezo-lisp — Common Lisp (SBCL) 製ネット掲示板

あめぞう風掲示板と 2ちゃんねるのハイブリッドを目指した、オリジナルのネット掲示板です。
Python 版 (amezo-python) を SBCL / Common Lisp へ移植したもので、**データ形式は Python 版と完全互換**です。
同じ掲示板フォルダを Python 版と Lisp 版で交互に動かせます (相互運用テストで確認済み)。

## 特徴

- 板の一覧 (dai)、スレッド投稿・返信、トリップ、ID、キャップ
- ロックしたスレッド向けの認証キー発行・失効 (管理画面)
- 管理画面 (削除・非表示・復元、ログイン失敗制限つき)
- 署名つき中継ページ (jump) — 本文中の URL は署名つきリンクになる
- 過去ログの 2 段階 gzip 圧縮 (archive) と、gz のまま/展開しての配信
- 外部ライブラリ不要: SHA-256 / HMAC / PBKDF2 / base64 / base32 は自前実装、
  ソケットは sb-bsd-sockets、ロックは flock(2) を直接使う (Python 版の fcntl.flock と相互に効く)

## 動作環境

- SBCL (2.2.9 で開発・確認)
- 外部コマンド: `gzip` (過去ログ圧縮)、`df` (空き容量確認)
- 任意: `cloudflared` (`--tunnel` で公開する場合)

## 起動方法

```sh
# 1. 管理パスワードのハッシュを作る (delpass.txt が作られます)
sh run.sh --make-hash 好きなパスワード

# 2. サーバーを起動 (既定はローカルのみ、ポート 8000)
sh run.sh                 # http://127.0.0.1:8000/
sh run.sh --port 3000     # ポート変更
sh run.sh --tunnel        # cloudflared で公開 (明示したときだけ)
```

初回起動時に板フォルダ (`blist.txt` に載っている板) と秘密鍵ファイル
(`trip_secret.txt` など、パーミッション 600) が自動で作られます。

設定は `config.sample.ini` を `config.ini` にコピーして編集します。
検査を通らない値は無視され、既定値で動きます (起動時に理由が標準エラーへ出ます)。

## 過去ログの圧縮

```sh
sh archive.sh main --quiet=0   # 板 main の古い過去ログを圧縮 (段階1→次回に段階2)
sh archive.sh --all            # 全板
sh archive.sh --restore main o260101000000   # 展開して戻す
sh archive.sh --selftest       # 環境チェック
```

1 回目の実行で `o数字.html` が `.gz` になり (平文は残る)、2 回目の実行で平文が消えます。
配信時は `Accept-Encoding: gzip` のあるブラウザには gz のまま、無い場合は展開して返します。

## CGI モード

外部の CGI サーバーから呼ぶこともできます。

```sh
sbcl --script amezo.lisp --cgi amezo   # amezo / dai / admin / jump
```

## ファイル構成

| ファイル | 内容 |
|---|---|
| `amezo.lisp` | エントリ (sbcl --script 用) |
| `load.lisp` | `src/*.lisp` を古ければコンパイルして読み込む |
| `src/crypto.lisp` | SHA-256 / HMAC / PBKDF2 / base64 / base32 |
| `src/util.lisp` | 文字列・HTML・日時 (JST固定)・ファイル・flock |
| `src/config.lisp` | config.ini の読み込みと検証 |
| `src/core.lisp` | トリップ / ID / キャップ / 認証キー / jump 署名 |
| `src/post.lisp` | 投稿処理 |
| `src/regen.lisp` | 板 index.html の再生成、過去ログ一覧 |
| `src/dai.lisp` `src/jump.lisp` `src/admin.lisp` | 板一覧 / 中継 / 管理画面 |
| `src/archive.lisp` | 過去ログ圧縮 |
| `src/server.lisp` | HTTP サーバー (静的配信の許可リスト、gz 配信、CGI 振り分け) |
| `src/main.lisp` | コマンドライン処理 |
| `DESIGN.md` | 設計判断と Python 版との意図的な差分 |

## Python 版との意図的な差分

詳細は `DESIGN.md` を参照。要点:

- サーバー + CGI 子プロセスではなく、単一プロセスで処理する (CGI モードも残してある)
- 日時は OS のタイムゾーンではなく JST 固定で計算する
- 壊れたフォーム入力は CP932 フォールバックではなく UTF-8 置換文字として処理する
- トンネルは `--tunnel` を明示したときだけ (既定はローカルのみ)

## テスト

```sh
sbcl --script tests/unit-test.lisp   # 関数レベル (既知ベクトルとの照合) … 37 件
python3 tests/port_test.py           # サーバー結合テスト … 27 件
python3 tests/archive_test.py        # 圧縮テスト … 11 件
python3 tests/interop_test.py        # Python 版との相互運用 … 8 件 (~/workspace/amezo-python が必要)
```

全テスト合格を確認済み (2026-10-31)。`interop_test.py` では、Python 版が作ったスレッドへ
Lisp 版が返信し (トリップ一致)、Python 版の `make_hash` で作った delpass で
Lisp 版の管理画面にログインできることまで確認しています。
