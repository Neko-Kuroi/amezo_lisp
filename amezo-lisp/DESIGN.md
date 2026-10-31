# SBCL 移植の設計

Python 版 (`amezo-python`、最新パッチ適用済み) を SBCL / Common Lisp へ移植する際の決定事項。

## 方針

1. **データ互換を最優先**にする。Python 版と Lisp 版が同じ掲示板フォルダを
   交互に使えること (スレッドファイル、板 index、`blist.txt`、`ng.txt`、
   `cap.txt`、`delpass.txt`、`*_secret.txt`、`global.mem`、`admin_fail.mem`、
   `<板>/keys.txt`、`kako.txt`、過去ログ `.gz` の形式はすべて不変)。
2. **ハッシュ・署名の互換**: PBKDF2-HMAC-SHA256 (`pbkdf2_sha256$…` 形式)、
   トリップ (HMAC-SHA256 → base64 先頭10文字、`+`→`.` / `/`→`_`)、
   ID (同 8文字)、jump 署名 (HMAC-SHA256 → base64url 先頭22文字)、
   認証キー (base32 24文字、HMAC の hex) は Python 版と同一の計算にする。
   そのため Python 版で作った `delpass.txt` やトリップがそのまま通用する。
3. **外部ライブラリに依存しない**。Quicklisp が無くても動くよう、
   SHA-256 / HMAC / PBKDF2 / base64 / base32 は自前実装し、
   ソケットは `sb-bsd-sockets`、スレッドは `sb-thread`、
   ファイルロックは libc の `flock(2)` を使う (Python 版の `fcntl.flock` と相互に効く)。
   gzip の作成・展開だけ外部の `gzip` コマンドを使う。
4. **構成の違い**: Python 版は「サーバ + CGI サブプロセス」だが、Lisp 版は
   1プロセスに統合する。`setup_expose.py` のルーティング (許可リスト配信、
   不正パス 400、過去ログ gz 配信) と各 CGI の処理を、リクエスト構造体を
   受け取ってレスポンス構造体を返す関数として実装し、サーバが直接呼ぶ。
   CGI として外部サーバから呼ぶための `--cgi` モードも残す。
5. 日時は Python 版と同じく **JST 固定**。OS のタイムゾーンに頼らず、
   エポック秒 + 9時間 から暦計算で求める。

## あめぞう × 2ちゃんねる ハイブリッドとしての性格 (Python 版から継承)

- あめぞう式: レスが付くとスレッドが先頭に浮上する板 index を投稿のたびに再生成、
  読む側は静的 HTML、スレッド = 1ファイル、板一覧フレーム (dai) + HEAD LINE。
- 2ちゃんねる式: トリップ (`名前#パスワード` → `◆`)、日替わり ID (`ID:xxxxxxxx`)、
  キャップ (`★`)、sage の代わりにメール欄リンク、二重カキコ防止。
- 独自拡張 (PHP→Python 移植で入ったもの): 鍵つきスレッド + 認証キー発行、
  署名つき中継ページ (jump)、設定ファイル `config.ini` (実行されない形式)、
  過去ログの 2段階 gzip 圧縮 (archive)。

## ファイル対応表

| Python 版 | Lisp 版 |
|---|---|
| `setup_expose.py` | `src/server.lisp` + `src/main.lisp` |
| `amezo.py` | `src/core.lisp` (投稿・再生成・鍵・中継リンク) |
| `dai.py` | `src/dai.lisp` |
| `admin.py` | `src/admin.lisp` |
| `jump.py` | `src/jump.lisp` |
| `archive.py` | `src/archive.lisp` |
| (共通部品) | `src/util.lisp`, `src/crypto.lisp`, `src/config.lisp` |

## Python 版との意図的な差異

- 大きなスレッド (256KB超) の末尾だけ読む最適化は行わず、毎回全行を読む
  (結果は同じ。巨大スレッドでは Python 版より遅くなりうる)。
- フォームの不正なバイト列は、Python 版は CP932 でも解釈を試みるが、
  Lisp 版は UTF-8 として置換文字で受ける。
- Cloudflare トンネルは `--tunnel` 指定時だけ `cloudflared` を起動する
  (Python 版は既定でトンネルを張る。Lisp 版の既定はローカル起動)。
  cloudflared の用意 (PATH に無ければアプリフォルダへ自動ダウンロード)・
  公開URLの表示・終了時の後片付けは Python 版 `setup_expose.py` の
  `start_tunnel` 相当を `src/server.lisp` に実装した。
  事前準備だけを行う `--setup-tunnel` サブコマンドもある。
