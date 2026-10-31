# amezo-lisp コード解説

Common Lisp (SBCL) 製のネット掲示板「amezo-lisp」のソースコード解説です。
対象: `https://github.com/Neko-Kuroi/amezo_lisp` (コミット `4189ef3 cloudflared tunnel` 時点)

- 規模: `src/*.lisp` 合計 約3,300行、外部ライブラリなし
- 元になったもの: Python 版 `amezo-python` の移植。**データ形式は Python 版と完全互換**
- 動作: 1つの SBCL プロセスが HTTP サーバー + 各 CGI 処理を兼ねる

---

## 1. 全体像

```
ブラウザ ──HTTP──▶ server.lisp (ソケット受付・ルーティング)
                      │
                      ├─ /amezo.cgi ─▶ post.lisp   投稿・レス表示
                      ├─ /dai.cgi   ─▶ dai.lisp    板一覧 + HEAD LINE
                      ├─ /admin.cgi ─▶ admin.lisp  管理画面
                      ├─ /jump.cgi  ─▶ jump.lisp   署名つき中継ページ
                      ├─ /板名/xxx.html ─▶ 静的ファイル配信 (許可リスト方式)
                      └─ /板名/oN.html ─▶ 過去ログ (.gz のまま / 展開して配信)

共通部品: util.lisp / crypto.lisp / config.lisp / core.lisp / regen.lisp
別系統:   archive.lisp (過去ログ圧縮、コマンドラインから実行)
```

DB は使いません。**ファイルがそのままデータ**です。

- スレッド = `板名/<番号>.html` の1ファイル (読む側は静的 HTML)
- 板の一覧ページ = 投稿のたびに再生成される `板名/index.html`
- 設定・秘密鍵・制限情報 = テキストファイル

---

## 2. 起動の流れ

### 2.1 `run.sh`

```sh
cd "$(dirname "$0")"
exec sbcl --script amezo.lisp "$@"
```

`--make-hash パス` だけは `--make-delpass` に読み替えて `amezo.lisp` へ渡します。

### 2.2 `amezo.lisp`

`load.lisp` を読み込み、`(amezo:main sb-ext:*posix-argv*)` を呼ぶだけの薄いスクリプトです。
未処理のエラーは標準エラーに出して終了コード 1 で終わります。

### 2.3 `load.lisp`

`src/` の各ファイルを**この順番で**読み込みます。順番が依存関係そのものです。

```
package → util → crypto → config → core → regen → post → dai → jump → admin → archive → server → main
```

- 各 `.lisp` について `.fasl` が無いか、ソースの方が新しければ `compile-file` してから `load`
- 最後に `*root-dir*` (アプリのルートフォルダ) を設定

### 2.4 `main.lisp` の `main`

引数で処理が分岐します。

| 引数 | 動作 |
|---|---|
| `archive ...` | `archive-main` (過去ログ圧縮) |
| `--make-hash PW` | パスワードハッシュを表示 |
| `--make-delpass PW` | `delpass.txt` を作成 (パーミッション 600) |
| `--setup-tunnel` | cloudflared を用意する |
| `--cgi 名前` | CGI モード (標準入出力で1リクエスト処理) |
| (その他) | HTTP サーバー起動。`--port N` `--tunnel` `--verbose` |

`main` は最初に `*app-dir*` を決め、`load-config` で `config.ini` を読みます。

---

## 3. 各ファイルの解説

### 3.1 `package.lisp` — パッケージ定義

- `sb-posix` と `sb-bsd-sockets` を `require`
- `:amezo` パッケージを定義 (公開シンボルは `main` `archive-main` `make-hash` `verify-hash`)
- **前方宣言**: 読み込み順より後で定義される変数・関数 (`*hash-iterations*`、`utf8` など) を先に宣言し、初回コンパイル時の警告を避ける

### 3.2 `util.lisp` — 汎用ユーティリティ

| 分類 | 主な関数 |
|---|---|
| 文字列 | `split-string` `split-once` `join-strings` `replace-all` `starts-with-p` `ends-with-p` `trim-space` `digits-p` `safe-integer` |
| HTML | `html-escape` `html-unescape` `strip-tags` `ccut` (HTML実体を1文字と数えて切る) `html-chars-len` `strip-invisible` (不可視文字の除去) |
| URL/UTF-8 | `url-decode` `url-encode` `utf8-decode` |
| 日時 | `epoch->jst` `jst->epoch` `format-jst-date` `format-res-number` |
| ファイル | `app-path` `read-file-lines` `write-file-string` `write-file-atomic` `file-mtime-of` `rename-path` `list-dir-names` など |
| ロック | `fd-open` `fd-lock` `fd-unlock` `call-with-fd-lock` |
| IP | `ipv4-valid-p` `ip-valid-p` `ip-unit` |

押さえておく点:

- **日時は JST 固定**。OS のタイムゾーンを使わず、エポック秒 + 9時間から暦計算します (`civil-from-days`)。
- **ファイルロック**は libc の `flock(2)` を直接呼びます。Python 版の `fcntl.flock` と同じファイルを相互に排他できます。
- `call-with-fd-lock` はロックを取れたら関数を実行し、タイムアウトしたら `:busy` を返します。`unwind-protect` で必ず解放します。
- `ip-unit` は IP を集計単位に丸める関数です (IPv6 の扱いなどを吸収)。

### 3.3 `crypto.lisp` — 暗号部品 (自前実装)

外部ライブラリを使わないため、以下をすべて自前で実装しています。

- `sha256-*` (SHA-256 本体、ファイルのダイジェスト `sha256-file` も)
- `hmac-sha256` / `hmac-sha256-hex`
- `pbkdf2-sha256`
- `base64-encode` / `b64url-encode` / `b64url-decode` / `base32-encode`
- `constant-time-equal` (比較時間でバレないための定数時間比較)
- `random-octets` (乱数バイト列)

**パスワードハッシュの形式** (Python 版と同一):

```
pbkdf2_sha256$<反復回数>$<salt の hex>$<ハッシュの hex>
```

`verify-hash` は反復回数が 1〜5,000,000 の範囲にあるときだけ検証します。
既定の反復回数は 100,000 (`*hash-iterations*`)。

### 3.4 `config.lisp` — 設定

1. `defparameter` で既定値を定義 (投稿間隔、最大スレッド数、文字数上限、秘密鍵ファイル名など)
2. `config-schema` に「キー → (型 既定値 最小 最大)」の表がある
3. `load-config` が `config.ini` を読み、**検査に通った値だけ**を対応する変数に `set`
4. 通らなかった値は標準エラーに理由を出して無視 (既定値で動く)

`config.ini` はただのテキストで、プログラムとして実行されません。
旧形式の `config.php` があれば「読み込まない」と警告します。

主な設定: `POST_INTERVAL` (連投制限 5秒) / `GLOBAL_WINDOW` (同一IPの新規スレッド間隔 180秒) /
`MAX_THREADS` (200) / `PAGE_CACHE` (10秒) / `COMM_MAX` (400字) / `TRUSTED_PROXIES` / `JUMP_ENABLED` / `ARCHIVE_QUIET_SECONDS` (600秒)

### 3.5 `core.lisp` — 中核部品

#### リクエスト/レスポンスの抽象

```lisp
(defstruct request  method query-string body headers remote-addr script-name)
(defstruct response status headers body)
```

HTTP サーバーモードでも CGI モードでも、処理側は `request` を受け取って `response` を返すだけ、という形に統一されています。

#### `bbs-exit` と `bail` — 非局所脱出

Python 版は `sys.exit` で処理を打ち切っていました。Lisp 版では:

```lisp
(define-condition bbs-exit (error) ((response ...)))
(defun bail (resp) (error 'bbs-exit :response resp))
```

`bail` が「レスポンスを持った condition」を投げ、`handle-amezo` などの `handler-case` が受け取ってそのレスポンスを返します。
`page-error` (200 でエラー文を表示) や `redirect-response` (303) も内部で `bail` します。
深い関数の中から一気に抜けられるのがポイントです。

#### 秘密鍵: `load-secret`

`trip_secret.txt` `id_secret.txt` `key_secret.txt` `jump_secret.txt` に 32バイトの鍵を 64桁の hex で保存します。無ければ生成します。

- 一時ファイル (0600) に書いてから `link` で本番名に置く → **同時に複数プロセスが作っても最初の鍵が全員に使われる**
- ハードリンクが使えない環境向けのフォールバックあり

#### クライアント IP: `client-ip`

接続元が `*trusted-proxies*` (既定 `127.0.0.1` `::1`) のときだけ、`CF-Connecting-IP`、無ければ `X-Forwarded-For` の最後の要素を採用します。
Cloudflare Tunnel 経由だと接続元は常にローカルになるため、この仕組みで本当の IP を取ります。

#### トリップ・ID・キャップ

| 機能 | 関数 | 計算 |
|---|---|---|
| トリップ `◆` | `make-trip` | パスワードから空白除去・全角→半角・100字まで → HMAC-SHA256 (トリップ鍵) → base64 先頭10文字 → `+`→`.` `/`→`_` |
| ID | `make-id` | `"id:" + ip-unit + "\|日付(JST)\|" + 板名` を HMAC-SHA256 (ID鍵) → 先頭8文字。**日替わり・板ごと**に変わる |
| キャップ `★` | `is-cap` | `cap.txt` の「名前,ハッシュ」行と照合 |

投稿者名に元から含まれる `◆` `★` は `◇` `☆` に置き換えられ、なりすましを防ぎます。

#### 投稿制限

- `post-interval-left` / `touch-lasttime`: 板ごとの連投制限 (`板/lasttime.txt`)
- `check-global-ip`: 同じ IP の**新規スレッド**を `GLOBAL_WINDOW` 秒止める。IP は HMAC で匿名化して `global.mem` に保存し、ロックして読み書き

#### 中継リンク (jump) 用の関数

- `url-is-valid`: `http(s)://` のみ、2000バイト以下、許可文字だけ
- `jump-sign`: `"jump:" + URL` の HMAC-SHA256 → base64url 先頭22文字
- `jump-href`: `../jump.cgi?u=<URLのbase64url>&s=<署名>` を作る
- `linkify-urls`: エスケープ済み本文から URL を探してリンク化。末尾の `.` `,` `)` などは URL に含めない (括弧の対応も見る)

#### 認証キー (鍵つきスレッド)

- キーは **base32 24文字** (`XXXX-XXXX-...` 表示)。先頭4文字が ID
- `板/keys.txt` にタブ区切り6列で保存: `ID, ラベル, ハッシュ, スコープ, 作成時刻, 状態(active/revoked)`
- 保存するのは `HMAC(鍵, "key:" + キー)` の hex で、**キー本体は保存しない**
- スコープは `*` (板全体) か特定のスレッド番号
- `keys-update` は `keys.lock` をロックし、一時ファイル → `rename` でアトミックに書き換え
- スレッドの鍵は `<番号>.lock` ファイルの有無で表し、`thread-set-lock` がスレッド末尾の返信フォームも書き換える (キー入力欄を出す/消す)

### 3.6 `post.lisp` — 投稿処理 (掲示板の心臓部)

#### フォームの解析

`parse-form-body` が POST 本体 (octet) を処理します。

1. `&` で分割し、キーと値を `url-decode`
2. `strip-invisible` で不可視文字を除去
3. `name` は**最初の `#`** で分割 → 左が名前、右がトリップ用パスワード
4. `html-escape`
5. 改行を正規化し、`comm` の改行は `<br>` に
6. 制御文字を除去

#### `amezo-main` の流れ

```
本体サイズ検査 (MAX_POST_BYTES)
  → 板名の決定 (フォーム → クエリ → Referer の順) と検査
  → "sub" ボタンなら res-view (レス表示) で終了
  → ページ番号の決定
  → 入力検査 (改行数・文字数・題名長)
  → 名前の加工 (◆★除去、空白除去、長さ制限)
  → NGワード処理 (ng.txt)
  → [page=1 かつ reload でないとき] 投稿処理
       キャップ判定 → 必須項目検査 → 連投制限 → 新規スレなら global-IP 制限
       → URL リンク化 → トリップ/キャップ付与 → メール欄リンク化
       → ID 生成 → 日時 → post-write
  → regen-index で板 index を再生成
  → 303 リダイレクト
```

- `reload-flag`: 名前・題名・本文がすべて空 (または同一) のときは「再読み込み」とみなし、書き込みをしない
- NGワード (`ng.txt` の `語,n` / `語,c` / `語`): `n` は名前に含まれたら投稿扱いを取りやめ、`c` は本文、無印は4項目から語を削除
- 管理者名 (`*admin-name*`) を名乗ってもキャップがなければ `＃サポート` のように無効化される

#### `post-write` と `write-post-under-lock`

スレッドファイルの形式がこのプログラムの要です。

```
1行目 : <html><head>...<title>題名</title>...</head><body><dl><dt>1 <font ...><b>題名 </b></font>投稿者：...</dl>
2行目〜: <dl><dt>N 投稿者：... 投稿日：... ID:xxxx<br><dd>本文 </dl>
末尾  : 返信フォーム (<form ...>) と </body></html>
```

- **1レス = 1行** (`<dt>番号` で始まる)。読む側は静的 HTML のまま
- 新規スレッド: `O_EXCL` で番号ファイルを作成。重複していたら番号を +1 して最大30回試す
- 返信: スレッドファイル自体を `flock` し、
  - ロック待ちの間に archive が消していたら (`nlink = 0`) 書かない
  - 鍵つきスレッドなら `key-verify` で認証キーを検査
  - 直前のレスと**名前・本文が同じなら「二重カキコ」**として拒否 (`parse-prev-post`)
  - 末尾の `<dt>` 行までを残し、新しい行と返信フォームを追記して全体を書き直す

#### `res-view`

`from` 以降のレスだけを切り出して返します。長いスレッド向けの表示で、`../style.css` などの相対パスを置換して板フォルダの外から開けるようにします。

### 3.7 `regen.lisp` — 板 index の再生成

`regen-index` が「あめぞう式」の挙動 (**レスが付くとスレが先頭に浮上**) を作ります。

- **並び順は各スレッドファイルの更新時刻の降順** (`scan-threads`)。だから投稿 (= ファイル更新) するだけで浮上する
- 1ページ目:
  - `regen.lock` を `flock`。reload のときは待たずに `"busy"`、投稿のときは最大10秒待つ
  - `MAX_THREADS` を超えた古いスレッドは `o<番号>.html` に改名して**過去ログへ退避**し、`kako.txt` / `kako.html` を更新
  - `write-index-page` で一時ファイルに書き、`rename` で置き換え (アトミック)
  - 10分以上前の `index2.html` 以降を掃除
- 2ページ目以降: `PAGE_CACHE` 秒のあいだは作成済みのファイルを再利用 (`"cached"`)
- `write-index-page` は `<!-- HEAD LINE -->` 〜 `<!-- HEAD LINE END -->` の間にスレッド題名一覧を出す。`dai.lisp` はここを読んで板一覧に載せる

### 3.8 `dai.lisp` — 板一覧

- `blist.txt` (`フォルダ名,背景色,タイトル` のCSV) を読み、板ごとに `<table>` を出力
- 各板の `index.html` から HEAD LINE を最大20行読み、リンクを `フォルダ名/数字.html` に直す (`replace-first-digit-html`)
- フォルダ名に `/` `..` や先頭 `.` があるものは無視

### 3.9 `jump.lisp` — 署名つき中継ページ

本文中の URL は直リンクではなく `jump.cgi?u=...&s=...` になります。

1. `u` を base64url でデコード、`jump-verify` で署名を検査
2. 署名が合わなければ「開けません」画面 (URL は**リンクにせず**テキスト表示)
3. 合えば「移動先のホスト名」と「URL 全体」を見せ、「進む」ボタンを出す (**自動転送しない**)
4. ホスト名に `xn--` (国際化ドメイン) があれば警告
5. `ad.html` があれば iframe (sandbox) で広告を表示

レスポンスには `Content-Security-Policy` (nonce つき)、`Referrer-Policy: no-referrer`、`X-Robots-Tag: noindex` などが付きます。

### 3.10 `admin.lisp` — 管理画面

- `POST` のみ。パスワードは `adminpass` で毎回送る (セッション無し)
- **ログイン失敗の制限**: 5回失敗で 900秒ロック。誰かは `HMAC(ID鍵, "adm:" + IP)` で匿名化し、`admin_fail.mem` に `誰 回数 時刻` で保存
- パスワードは `delpass.txt` の PBKDF2 ハッシュと `verify-hash` で照合

操作 (`act`):

| act | 内容 |
|---|---|
| `boards` / `threads` / `replies` | 板・スレッド・レスの一覧表示 |
| `delete` | 選んだレスを削除 (**1番は削除不可**)。削除後も並び順を保つため、更新時刻を「残った最後のレスの投稿日時 + 1秒」に設定 |
| `hide` / `restore` | スレッドを `x<番号>.html` に改名/戻す (非表示・復元) |
| `lock` / `unlock` | スレッドの鍵 |
| `keys` / `issue` / `revoke` | 認証キーの一覧・発行・失効 |

どの操作も成功したら `admin-regen` で板 index を作り直します。

### 3.11 `archive.lisp` — 過去ログの2段階圧縮

`sh archive.sh ...` から呼ばれます (`archive-main`)。外部コマンドの `gzip` と `df` を使います。

**段階1 (`arch-stage1`)**: `oN.html` → `oN.html.gz` (平文は残す)

1. 最終書き込みから `--quiet` 秒 (既定600) 経っていなければスキップ
2. ディスクの空きが足りなければスキップ
3. `gzip` で一時ファイルへ圧縮
4. **展開して SHA-256 を平文と比較**。一致しなければ一時ファイルを消して NG
5. 圧縮中に元が変わっていないか (サイズ・更新時刻) 再確認
6. gz の更新時刻を平文に合わせ、`rename`

**段階2 (`arch-stage2`)**: 次回以降の実行で平文を削除

1. gz の更新時刻が平文と違えば (平文が更新された) 古い gz を削除し、次回に再圧縮
2. gz 作成から `--quiet` 秒待つ
3. gz の中身を再度ハッシュ検証。不一致なら**どちらも消さず** gz を `.bad` に改名
4. 平文を `flock` で押さえ、サイズ・更新時刻が変わっていないことを確認してから削除

その他: `--restore 板 oN` (展開して戻す)、`--dry-run`、`--limit=件数`、`--selftest` (環境チェック)。板ごとに `archive.lock` で多重起動を防止します。

### 3.12 `server.lisp` — HTTP サーバー

#### 起動 (`serve`)

1. `setup-bbs-directories`: 必須ファイルの存在確認、`flock` が効くかのテスト、各板フォルダと初期 `index.html` を作成
2. `start-server`: `127.0.0.1` のみに bind。**接続ごとに `sb-thread` でスレッド**を作る
3. `/style.css` が 200 を返すまで待ち、`self-check`
4. `--tunnel` なら `start-tunnel`、そうでなければローカル URL を表示
5. Ctrl+C で終了 (トンネルのプロセスも止める)

#### リクエスト処理 (`handle-connection` → `route-request`)

- リクエスト行とヘッダーを読む。`Content-Length` が 65536 を超えたら本文を読まずに **413**
- `malformed-path-p`: 空、`//`、`%`、`\`、NUL、`..`、`.` セグメントを含むパスは **400**
- ルーティング順:
  1. `GET/HEAD` で `板/oN.html` に `.gz` があれば `serve-archived`
  2. `/amezo.cgi` `/dai.cgi` `/admin.cgi` `/jump.cgi` (`.py` も可。**許可リスト `*allowed-cgi*` のみ**) → `dispatch-cgi`
  3. `GET/HEAD` の静的ファイルは `static-allowed-p` の許可リストに合うものだけ
  4. 上記以外の `POST` は 501

静的ファイルの許可:

- ルート: `/` `/index.html` `/style.css` `/hide.js` `/ad.html`
- 板フォルダ内: `index*.html` `kako.html` `<数字>.html` `o<数字>.html` だけ
  (`keys.txt` や `*.lock` などは**見えない**)

#### 過去ログ配信 (`serve-archived`)

`Accept-Encoding: gzip` があれば gz をそのまま (`Content-Encoding: gzip`)、無ければ外部 `gzip -dc` で展開して返します。

#### Cloudflare Tunnel

- `ensure-cloudflared`: PATH に無ければアプリフォルダへ公式リリースをダウンロード (x86_64 / ARM64)
- `start-tunnel`: `cloudflared tunnel --url http://127.0.0.1:<port>` を起動し、出力を読むスレッドで `https://….trycloudflare.com` を拾って表示 (最大20秒待つ)

---

## 4. 実行時に生成されるデータファイル

| ファイル | 内容 | 作るところ |
|---|---|---|
| `delpass.txt` | 管理パスワードのハッシュ (600) | `--make-hash` |
| `*_secret.txt` | トリップ / ID / キー / jump 用の鍵 (600) | `load-secret` |
| `blist.txt` | 板の一覧 (手で編集) | — |
| `ng.txt` `cap.txt` | NGワード / キャップ (手で編集) | — |
| `config.ini` | 設定 (任意) | — |
| `global.mem` | 新規スレッドの IP 制限 (匿名化済み) | `check-global-ip` |
| `admin_fail.mem` | 管理ログイン失敗の記録 | `admin-fail-store` |
| `板/N.html` | スレッド | `post-write` |
| `板/xN.html` | 非表示スレッド | `admin-do-hide` |
| `板/oN.html(.gz)` | 過去ログ | `regen-index` / archive |
| `板/N.lock` | 鍵つきスレッドの印 | `thread-set-lock` |
| `板/keys.txt` | 認証キー (ハッシュ) | `keys-update` |
| `板/index*.html` `kako.html` `kako.txt` | 一覧・過去ログ一覧 | `regen-index` |
| `板/lasttime.txt` | 連投制限用の最終投稿時刻 | `touch-lasttime` |
| `板/regen.lock` `keys.lock` `archive.lock` | ロック専用 | 各所 |

---

## 5. 並行処理とデータ保全の設計

サーバーは接続ごとのスレッドで動くので、同時書き込みを前提にした工夫が随所にあります。

| 場面 | 対策 |
|---|---|
| スレッドへの返信 | スレッドファイルを `flock` |
| 板 index の再生成 | `regen.lock` を `flock` + 一時ファイル → `rename` |
| 秘密鍵の初回作成 | `O_EXCL` + `link` で「最初の1つ」に統一 |
| keys.txt 更新 | `keys.lock` + 一時ファイル → `rename` |
| 投稿中に archive が走る | 書き込み前に `nlink = 0` を検査、archive 側もロックして再確認 |
| 圧縮の失敗 | SHA-256 で展開内容を検証、不一致なら消さずに `.bad` へ退避 |
| NFS 等で `flock` が効かない | 起動時に `check-flock-works` で警告 |

---

## 6. セキュリティ設計のまとめ

- **パスワード・キーは平文保存しない** (PBKDF2 / HMAC)。比較は定数時間
- **パストラバーサル対策**: `malformed-path-p`、板名の `/` `..` 検査、静的ファイル・CGI の許可リスト
- **XSS 対策**: 入力は先頭で `html-escape`。URL は検証してからリンク化
- **外部リンク**: 署名つき中継ページ + 自動転送なし + CSP
- **総当たり対策**: 管理ログイン失敗の回数制限 (IP は匿名化)
- **プライバシー**: IP はそのまま保存せず HMAC で匿名化。ID は日替わり
- **既定はローカルのみ**: `127.0.0.1` に bind、トンネルは `--tunnel` を明示したときだけ
- **設定は実行されない**: `config.ini` は検査して不正値を無視

---

## 7. Lisp として読むときのポイント

- **`defstruct`**: `request` `response` `key-row` `archiver` などのデータ型
- **`handler-case` / `unwind-protect`**: エラー処理と後始末 (ロックやファイルの解放)
- **`define-condition` + `error`**: `bbs-exit` による非局所脱出
- **`multiple-value-bind` / `values`**: 複数の戻り値 (`regen-index` は index名と状態を返す)
- **`labels` / `flet`**: 関数内のローカル関数 (`res-view` など)
- **`with-output-to-string`**: HTML 組み立て
- **`loop`**: 繰り返し。`for ... while ... do` の形が多い
- **`return-from`**: 関数からの早期脱出 (ガード節として多用)
- **special variable**: `*request*` を `let` で束縛し、`client-ip` が参照
- **`sb-posix` / `sb-ext:run-program` / `sb-thread` / `sb-bsd-sockets`**: SBCL 拡張。ここが SBCL 依存部分

---

## 8. テスト

| ファイル | 内容 |
|---|---|
| `tests/unit-test.lisp` | 関数レベル。SHA-256 / HMAC / PBKDF2 などを既知ベクトルと照合 |
| `tests/port_test.py` | サーバーを起動しての結合テスト |
| `tests/archive_test.py` | 過去ログ圧縮 |
| `tests/interop_test.py` | Python 版との相互運用 (`~/workspace/amezo-python` が必要) |

---

## 9. 読む順番のおすすめ

1. `README.md` → `DESIGN.md` (全体と設計判断)
2. `main.lisp` → `server.lisp` の `route-request` (入口)
3. `post.lisp` の `amezo-main` → `write-post-under-lock` (投稿の一連)
4. `regen.lisp` の `regen-index` (一覧の再生成)
5. `core.lisp` (トリップ・ID・認証キー・jump)
6. `admin.lisp` / `archive.lisp` (運用機能)
7. `crypto.lisp` / `util.lisp` (部品。必要になったら)
