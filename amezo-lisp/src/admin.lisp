;;;; admin.lisp - 管理画面 (Python 版 admin.py)
(in-package :amezo)

(defparameter *admin-max-body* 65536)
(defparameter *admin-max-fails* 5)
(defparameter *admin-lock-sec* 900)
(defparameter *admin-fail-file* "admin_fail.mem")
(defparameter *admin-list-limit* 100)
(defparameter *admin-body-preview* 60)
(defparameter *admin-style*
  "<style>
body { font-family: sans-serif; margin: 12px; }
table { border-collapse: collapse; }
th, td { border: 1px solid #999; padding: 4px 8px; vertical-align: top; }
td.body { max-width: 32em; word-break: break-all; }
form.inline { display: inline; }
.msg { padding: 6px 10px; border: 1px solid #c33; margin: 8px 0; }
.msg.ok { border-color: #393; }
.keybox { border: 2px solid #c60; padding: 10px 14px; margin: 10px 0; background: #fff8e8; }
.keybox code { font-size: 1.3em; letter-spacing: 0.05em; user-select: all; }
button { padding: 4px 12px; }
</style>")

(defun admin-page (title body)
  (bail (make-response :status 200
                       :headers (list (cons "Content-Type" "text/html; charset=UTF-8")
                                      (cons "Cache-Control" "no-store")
                                      (cons "X-Robots-Tag" "noindex"))
                       :body (format nil "<!DOCTYPE html>~%<html lang=\"ja\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"robots\" content=\"noindex\"><title>~a</title>~a</head><body>~%<h2>~a</h2>~%~a~%</body></html>~%"
                                     (html-escape title) *admin-style* (html-escape title) body))))

(defun admin-msg (message &optional (ok t))
  (if (or (null message) (string= message ""))
      ""
      (format nil "<div class=\"~a\">~a</div>" (if ok "msg ok" "msg") (html-escape message))))

(defun admin-hidden (pw &rest fields)
  (with-output-to-string (out)
    (format out "<input type=\"hidden\" name=\"adminpass\" value=\"~a\">" (html-escape pw))
    (loop for (k v) on fields by #'cddr
          do (format out "<input type=\"hidden\" name=\"~a\" value=\"~a\">" (html-escape (string k)) (html-escape (format nil "~a" v))))))

(defun admin-btn (pw label &key confirm act folder res id)
  (let ((fields (append (when act (list :act act)) (when folder (list :folder folder))
                        (when res (list :res res)) (when id (list :id id)))))
    (format nil "<form method=\"post\" action=\"admin.cgi\" class=\"inline\">~a<button type=\"submit\"~a>~a</button></form>"
            (apply #'admin-hidden pw fields)
            (if confirm (format nil " onclick=\"return confirm('~a')\"" (html-escape confirm)) "")
            (html-escape label))))

(defun admin-nav (pw &optional folder)
  (format nil "<p>~a~a</p>"
          (admin-btn pw "板一覧" :act "boards")
          (if folder (format nil " ~a" (admin-btn pw (format nil "「~a」のスレッド一覧" folder) :act "threads" :folder folder)) "")))

(defun admin-fatal (pw message)
  (admin-page "エラー" (format nil "~a~a" (admin-msg message nil) (admin-nav pw))))

(defun admin-login-page (&optional (message ""))
  (admin-page "管理画面"
              (format nil "~a<form method=\"post\" action=\"admin.cgi\"><input type=\"hidden\" name=\"act\" value=\"boards\">管理用パスワード <input type=\"password\" name=\"adminpass\" autocomplete=\"current-password\"> <button type=\"submit\">ログイン</button></form>"
                      (admin-msg message nil))))

;;; ---------- 認証 (失敗回数の制限つき) ----------
(defun admin-fail-store (update-fn)
  "admin_fail.mem をロックして UPDATE-FN(fails now) を実行し書き戻す。開けなければ :error。
   fails は hash-table: who -> (回数 時刻)"
  (let ((path (app-path *admin-fail-file*)) (result :error))
    (call-with-fd-lock path
                       (lambda (fd)
                         (declare (ignore fd))
                         (let ((now (epoch-now)) (fails (make-hash-table :test #'equal)))
                           (dolist (line (read-file-lines path '()))
                             (let ((p (split-string line #\Space :keep-empty nil)))
                               (when (and (= (length p) 3) (digits-p (second p)) (digits-p (third p))
                                          (< (- now (parse-integer (third p))) *admin-lock-sec*))
                                 (setf (gethash (first p) fails) (list (parse-integer (second p)) (parse-integer (third p)))))))
                           (setf result (funcall update-fn fails now))
                           (write-file-string path
                                              (with-output-to-string (out)
                                                (maphash (lambda (k v) (format out "~a ~d ~d~%" k (first v) (second v))) fails)))))
                       :create-mode #o600)
    result))

(defun admin-authenticate (pw)
  (let* ((ip (or (client-ip) "unknown"))
         (who (subseq (hmac-sha256-hex (id-key) (utf8 (format nil "adm:~a" (ip-unit (if (string= ip "") "unknown" ip))))) 0 24)))
    (let ((blocked (admin-fail-store (lambda (fails now) (declare (ignore now)) (>= (first (gethash who fails '(0 0))) *admin-max-fails*)))))
      (when (eq blocked :error)
        (admin-page "管理画面" (admin-msg "状態ファイル (admin_fail.mem) を開けないため、受け付けられません。" nil)))
      (when blocked
        (admin-page "管理画面" (admin-msg "失敗が続いたため、しばらく受け付けません。時間をおいてやり直してください。" nil))))
    (let ((delcrypt (load-delcrypt)))
      (when (string= delcrypt "")
        (admin-page "管理画面" (admin-msg "管理用パスワード (delpass.txt) が設定されていません。" nil)))
      (let ((ok (and (plusp (length pw)) (verify-hash pw delcrypt))))
        (admin-fail-store (lambda (fails now)
                            (if ok (remhash who fails)
                                (setf (gethash who fails) (list (1+ (first (gethash who fails '(0 0)))) now)))
                            ok))
        ok))))

;;; ---------- 板・スレッドの読み取り ----------
(defun admin-read-boards ()
  (let ((boards '()))
    (dolist (line (blist-lines) (nreverse boards))
      (let* ((p (split-string line #\,)) (name (first p)))
        (unless (or (string= name "") (starts-with-p "." name) (find #\/ name) (find #\\ name))
          (let* ((title (replace-all (or (third p) "") "#c#" ","))
                 (alt (search "alt=\"" title))
                 (plain (if alt
                            (let ((b (position #\" title :start (+ alt 5)))) (if b (subseq title (+ alt 5) b) ""))
                            (strip-tags title))))
            (push (list name plain) boards)))))))

(defun admin-list-threads (folder)
  "(values 表示中 非表示中) 各要素は (mtime 番号 パス)、新しい順。"
  (let ((active '()) (hidden-list '()))
    (dolist (n (list-dir-names (app-path folder)))
      (let ((x nil) (num nil))
        (cond ((and (> (length n) 6) (starts-with-p "x" n) (ends-with-p ".html" n)
                    (digits-p (subseq n 1 (- (length n) 5))))
               (setf x t num (subseq n 1 (- (length n) 5))))
              ((thread-file-name-p n)
               (setf num (subseq n 0 (- (length n) 5)))))
        (when num
          (let ((mt (file-mtime-of (app-path folder n))))
            (when mt
              (if x
                  (push (list mt num (app-path folder n)) hidden-list)
                  (push (list mt num (app-path folder n)) active)))))))
    (setf active (sort active #'> :key #'first)
          hidden-list (sort hidden-list #'> :key #'first))
    (values active hidden-list)))

(defun thread-title-and-count (path)
  (let ((title "") (count 0))
    (loop for line in (read-file-lines path '()) for i from 0
          do (when (zerop i)
               (let ((b (extract-first-b line))) (when b (setf title (trim-space (html-unescape b))))))
             (when (search "<dt>" line)
               (let ((num (handler-case (parse-integer line :start (+ (search "<dt>" line) 4) :junk-allowed t) (error () nil))))
                 (when num (incf count)))))
    (values title count)))

(defun admin-parse-thread (path)
  "(values 題名 ((番号 名前 日時 ID 本文) ...))"
  (let ((title "") (rows '()))
    (loop for line in (read-file-lines path '()) for i from 0
          do (when (zerop i)
               (let ((b (extract-first-b line))) (when b (setf title (trim-space (html-unescape b))))))
             (let ((dt (search "<dt>" line)))
               (when dt
                 (let ((num (handler-case (parse-integer line :start (+ dt 4) :junk-allowed t) (error () nil))))
                   (when num
                     (let* ((nm (search "投稿者：<font" line))
                            (name (if nm
                                      (let ((bs (search "><b>" line :start2 nm)))
                                        (if bs
                                            (let ((be (search " </b>" line :start2 bs)))
                                              (if be (trim-space (strip-tags (html-unescape (subseq line (+ bs 4) be)))) ""))
                                            ""))
                                      ""))
                            (dm (search "投稿日：" line))
                            (date (if dm
                                      (let ((e (search "</font>" line :start2 dm)))
                                        (if e (trim-space (subseq line (+ dm 4) e)) ""))
                                      ""))
                            (im (search "data-id=\"" line))
                            (post-id (if im
                                         (let ((e (position #\" line :start (+ im 9)))) (if e (subseq line (+ im 9) e) ""))
                                         ""))
                            (bm (search "<dd>" line))
                            (body (if bm
                                      (let ((e (search " </dl>" line :start2 bm)))
                                        (if e (subseq line (+ bm 4) e) ""))
                                      "")))
                       (setf date (let ((p (search " ID:" date))) (if p (trim-space (subseq date 0 p)) date)))
                       (setf body (html-unescape (strip-tags (replace-all body "<br>" " "))))
                       (push (list num name date post-id body) rows)))))))
    (values title (nreverse rows))))

;;; ---------- 画面 ----------
(defun admin-show-boards (pw)
  (let ((rows ""))
    (dolist (b (admin-read-boards))
      (setf rows (format nil "~a<tr><td>~a</td><td>~a</td><td>~a</td></tr>" rows (html-escape (first b)) (html-escape (second b))
                         (admin-btn pw "開く" :act "threads" :folder (first b)))))
    (admin-page "板の一覧"
                (if (plusp (length rows))
                    (format nil "<table><tr><th>板</th><th>名称</th><th></th></tr>~a</table>" rows)
                    "<p>板がありません。</p>"))))

(defun admin-show-threads (pw folder &key (message "") (ok t))
  (multiple-value-bind (active hidden-list) (admin-list-threads folder)
    (let ((rows "") (body (format nil "~a~a" (admin-msg message ok) (admin-nav pw))))
      (loop for (mt res path) in (subseq active 0 (min (length active) *admin-list-limit*))
            for (title count) = (multiple-value-list (thread-title-and-count path))
            do (setf rows (format nil "~a<tr><td>~a</td><td>~d</td><td>~a</td><td>~a</td><td>~a ~a ~a</td></tr>"
                                  rows (html-escape (if (string= title "") "(題名なし)" title)) count (format-admin-time mt)
                                  (if (thread-is-locked folder res) "🔒" "")
                                  (admin-btn pw "レスを見る" :act "replies" :folder folder :res res)
                                  (admin-btn pw "鍵の管理" :act "keys" :folder folder :res res)
                                  (admin-btn pw "非表示" :confirm "このスレッドを非表示にします。よろしいですか?" :act "hide" :folder folder :res res))))
      (if (plusp (length rows))
          (progn (setf body (format nil "~a<table><tr><th>題名</th><th>レス数</th><th>更新</th><th>鍵</th><th></th></tr>~a</table>" body rows))
                 (when (> (length active) *admin-list-limit*)
                   (setf body (format nil "~a<p>新しい順に ~d 件だけ表示しています (全 ~d 件)。</p>" body *admin-list-limit* (length active)))))
          (setf body (format nil "~a<p>表示中のスレッドはありません。</p>" body)))
      (let ((hrows ""))
        (loop for (mt res path) in (subseq hidden-list 0 (min (length hidden-list) *admin-list-limit*))
              for (title count) = (multiple-value-list (thread-title-and-count path))
              do (setf hrows (format nil "~a<tr><td>~a</td><td>~d</td><td>~a</td><td>~a</td></tr>"
                                     hrows (html-escape (if (string= title "") "(題名なし)" title)) count (format-admin-time mt)
                                     (admin-btn pw "復元" :act "restore" :folder folder :res res))))
        (when (plusp (length hrows))
          (setf body (format nil "~a<h3>非表示中のスレッド</h3><table><tr><th>題名</th><th>レス数</th><th>更新</th><th></th></tr>~a</table>" body hrows))))
      (admin-page (format nil "「~a」のスレッド" folder) body))))

(defun admin-show-replies (pw folder res &key (message "") (ok t))
  (let ((path (app-path folder (format nil "~a.html" res))))
    (unless (probe-file path)
      (admin-fatal pw "スレッドがありません。(非表示中の場合は、スレッド一覧から復元してください)"))
    (multiple-value-bind (title rows) (admin-parse-thread path)
      (let ((trs ""))
        (dolist (r rows)
          (let* ((num (first r)) (body (fifth r))
                 (short (format nil "~a~a" (subseq body 0 (min (length body) *admin-body-preview*))
                                (if (> (length body) *admin-body-preview*) "…" "")))
                 (cb (if (= num 1) "—" (format nil "<input type=\"checkbox\" name=\"del\" value=\"~d\">" num))))
            (setf trs (format nil "~a<tr><td>~a</td><td>~d</td><td>~a</td><td>~a</td><td>~a</td><td class=\"body\">~a</td></tr>"
                              trs cb num (html-escape (second r)) (html-escape (third r)) (html-escape (fourth r)) (html-escape short)))))
        (admin-page (format nil "~a (~a/~a)" (if (string= title "") "(題名なし)" title) folder res)
                    (format nil "~a~a<form method=\"post\" action=\"admin.cgi\">~a<table><tr><th>削除</th><th>No</th><th>名前</th><th>日時</th><th>ID</th><th>本文</th></tr>~a</table><p><button type=\"submit\" onclick=\"return confirm('選択したレスを削除します。よろしいですか?')\">選択したレスを削除</button></p></form><p>1番は削除できません。スレッドごと消す場合は「非表示」を使ってください。</p><p>~a</p>"
                            (admin-msg message ok) (admin-nav pw folder)
                            (admin-hidden pw :act "delete" :folder folder :res res) trs
                            (admin-btn pw "このスレッドを非表示にする" :confirm "このスレッドを非表示にします。よろしいですか?" :act "hide" :folder folder :res res)))))))

(defun admin-show-keys (pw folder res &key (message "") (ok t) issued)
  (let ((path (app-path folder (format nil "~a.html" res))))
    (unless (probe-file path) (admin-fatal pw "スレッドがありません。"))
    (let* ((title (thread-title-and-count path))
           (locked (thread-is-locked folder res))
           (body (format nil "~a~a" (admin-msg message ok) (admin-nav pw folder))))
      (when issued
        (setf body (format nil "~a<div class=\"keybox\"><b>キーを発行しました。この画面を閉じると、二度と表示されません。</b><br>いまのうちに控えて、書き込んでよい人に渡してください。<br><br><code>~a</code></div>" body (html-escape issued))))
      (setf body (format nil "~a<p>状態: <b>~a</b></p><p>~a</p><p>※ 鍵つきでも、読むのは誰でもできます。</p>"
                         body (if locked "🔒 鍵つき (認証キーがないと書き込めません)" "鍵なし (誰でも書き込めます)")
                         (if locked
                             (format nil "~a ~a"
                                     (admin-btn pw "鍵を外す" :confirm "このスレッドの鍵を外して、誰でも書き込めるようにします。よろしいですか?" :act "unlock" :folder folder :res res)
                                     (admin-btn pw "書き込みフォームを作り直す" :act "lock" :folder folder :res res))
                             (admin-btn pw "鍵をかける" :confirm "このスレッドに鍵をかけます。キーを持たない人は書き込めなくなります。よろしいですか?" :act "lock" :folder folder :res res))))
      (let ((rows ""))
        (dolist (r (keys-load folder))
          (when (or (string= (key-row-scope r) "*") (string= (key-row-scope r) res))
            (let ((active (string= (key-row-status r) "active")))
              (setf rows (format nil "~a<tr><td>~a</td><td>~a</td><td>~a</td><td>~a</td><td>~a</td><td>~a</td></tr>"
                                 rows (html-escape (key-row-id r)) (html-escape (key-row-label r))
                                 (if (string= (key-row-scope r) "*") "この板の鍵つきスレッドどれでも" "このスレッドだけ")
                                 (format-admin-time (key-row-created r)) (if active "有効" "失効")
                                 (if active
                                     (admin-btn pw "失効" :confirm (if (string= (key-row-scope r) "*")
                                                                       "このキーは、この板の鍵つきスレッド全部で使えなくなります。よろしいですか?"
                                                                       "このキーを失効します。よろしいですか?")
                                                :act "revoke" :id (key-row-id r) :folder folder :res res)
                                     ""))))))
        (setf body (format nil "~a<h3>キー</h3>~a" body
                           (if (plusp (length rows))
                               (format nil "<table><tr><th>ID</th><th>ラベル</th><th>範囲</th><th>発行日時</th><th>状態</th><th></th></tr>~a</table>" rows)
                               "<p>このスレッドで使えるキーはまだありません。</p>")))
        (setf body (format nil "~a<h3>キーを発行する</h3><form method=\"post\" action=\"admin.cgi\">~aラベル (誰に渡すか。40文字まで) <input type=\"text\" name=\"label\" size=\"24\"><br>範囲 <label><input type=\"radio\" name=\"scope\" value=\"thread\" checked> このスレッドだけ</label> <label><input type=\"radio\" name=\"scope\" value=\"board\"> この板の鍵つきスレッドどれでも</label><br><button type=\"submit\">発行</button></form><p>鍵をかける前にキーを発行しても、あとから発行してもかまいません。キーは発行したときに1度だけ表示されます (サーバーにはハッシュしか残りません)。</p>"
                           body (admin-hidden pw :act "issue" :folder folder :res res)))
        (admin-page (format nil "鍵の管理: ~a (~a/~a)" (if (string= title "") "(題名なし)" title) folder res) body)))))

;;; ---------- 操作 ----------
(defun admin-do-set-lock (folder res on)
  (cond ((not (probe-file (app-path folder (format nil "~a.html" res)))) (values nil "スレッドがありません。"))
        ((not (thread-set-lock folder res on)) (values nil "鍵の印のファイルを更新できませんでした。"))
        (on (values t (format nil "スレッド ~a に鍵をかけました。" res)))
        (t (values t (format nil "スレッド ~a の鍵を外しました。" res)))))

(defun admin-parse-date-in-line (line)
  "投稿日文字列 (YYYY年MM月DD日(曜)HH時MM分SS秒) をエポック秒にする。取れなければ NIL。
   Python 版 DATE_RE と同じく、各単位の直前の数字を読む。"
  (labels ((num-before (pos)
             (when pos
               (let ((start pos))
                 (loop while (and (plusp start) (digit-char-p (char line (1- start)))) do (decf start))
                 (when (< start pos) (parse-integer line :start start :end pos))))))
    (let ((year (num-before (search "年" line))) (month (num-before (search "月" line)))
          (day (num-before (search "日" line))) (hour (num-before (search "時" line)))
          (min (num-before (search "分" line))) (sec (num-before (search "秒" line))))
      (when (and year month day hour min sec)
        (jst->epoch year month day hour min sec)))))

(defun admin-do-delete (folder res nums)
  (setf nums (remove 1 nums))
  (when (null nums) (return-from admin-do-delete (values nil "削除するレスが選ばれていません。(1番は削除できません)")))
  (let ((path (app-path folder (format nil "~a.html" res))))
    (unless (probe-file path) (return-from admin-do-delete (values nil "スレッドがありません。")))
    (let ((removed 0) (stamp nil) (orig-mtime (file-mtime-of path)) (keep nil) (err nil))
      (call-with-fd-lock path
                         (lambda (fd)
                           (declare (ignore fd))
                           (handler-case
                               (let ((kept '()))
                                 (dolist (line (read-file-lines path '()))
                                   (let* ((dt (search "<dt>" line))
                                          (num (and dt (handler-case (parse-integer line :start (+ dt 4) :junk-allowed t) (error () nil)))))
                                     (cond ((and num (member num nums)) (incf removed))
                                           (t (let ((st (admin-parse-date-in-line line))) (when st (setf stamp st)))
                                              (push line kept)))))
                                 (setf keep (nreverse kept))
                                 (write-file-string path (join-strings (mapcar (lambda (l) (format nil "~a~%" l)) keep) "")))
                             (error () (setf err t))))
                         :timeout 10)
      (when err (return-from admin-do-delete (values nil "削除中にファイルエラーが発生しました。")))
      (let ((ts (or stamp orig-mtime)))
        (when ts (set-file-mtime path (1+ ts))))
      (values t (format nil "~d件のレスを削除しました。" removed)))))

(defun admin-do-hide (folder res)
  (let ((src (app-path folder (format nil "~a.html" res))) (dst (app-path folder (format nil "x~a.html" res))))
    (cond ((not (probe-file src)) (values nil "スレッドがありません。"))
          ((probe-file dst) (values nil "同じ番号の非表示スレッドが既にあるため、処理できません。"))
          ((rename-path src dst) (chmod-file dst #o600) (values t (format nil "スレッド ~a を非表示にしました。" res)))
          (t (values nil "スレッドの非表示化に失敗しました。")))))

(defun admin-do-restore (folder res)
  (let ((src (app-path folder (format nil "x~a.html" res))) (dst (app-path folder (format nil "~a.html" res))))
    (cond ((not (probe-file src)) (values nil "非表示のスレッドがありません。"))
          ((probe-file dst) (values nil "同じ番号の表示中スレッドが既にあるため、復元できません。"))
          ((rename-path src dst) (chmod-file dst #o644) (values t (format nil "スレッド ~a を復元しました。" res)))
          (t (values nil "スレッドの復元に失敗しました。")))))

(defun admin-regen (folder)
  (multiple-value-bind (name status) (regen-index folder :use-cache nil)
    (declare (ignore name))
    (if (string/= status "done") " (他の処理が再生成中のため、板の一覧の更新は省略されました)" "")))

;;; ---------- メイン ----------
(defun parse-admin-params (octs)
  "parse_qs 相当: キー -> 値のリスト の hash-table と、最初の値を取る関数用の alist。"
  (let ((table (make-hash-table :test #'equal)))
    (when octs
      (let ((s (utf8-decode octs)))
        (dolist (pair (split-string s #\&))
          (multiple-value-bind (k v) (split-once pair #\=)
            (let ((key (url-decode k)) (val (url-decode (or v ""))))
              (setf (gethash key table) (append (gethash key table) (list val))))))))
    table))

(defun handle-admin (req)
  (let ((*request* req))
    (handler-case (admin-main req)
      (bbs-exit (e) (bbs-exit-response e)))))

(defun admin-main (req)
  (let ((method (request-method req)) (params nil))
    (when (string= method "POST")
      (let ((n (length (request-body req))))
        (when (> n *admin-max-body*) (admin-page "エラー" (admin-msg "送信内容が大きすぎます。" nil)))
        (setf params (parse-admin-params (request-body req)))))
    (labels ((get1 (key) (if params (or (first (gethash key params)) "") ""))
             (getall (key) (if params (gethash key params) '())))
      (let ((pw (get1 "adminpass")))
        (when (or (string/= method "POST") (string= pw "")) (admin-login-page))
        (unless (admin-authenticate pw) (admin-login-page "パスワードが違います。"))
        (let ((act (get1 "act")))
          (when (or (string= act "") (string= act "boards")) (admin-show-boards pw))
          (let ((folder (get1 "folder")))
            (when (or (string= folder "") (find #\/ folder) (find #\\ folder) (search ".." folder) (not (is-board folder)))
              (admin-fatal pw "板名が不正です。"))
            (when (string= act "threads") (admin-show-threads pw folder))
            (let ((res (get1 "res")))
              (unless (digits-p res 1 20) (admin-fatal pw "スレッド番号が不正です。"))
              (cond ((string= act "replies") (admin-show-replies pw folder res))
                    ((string= act "keys") (admin-show-keys pw folder res))
                    ((member act '("lock" "unlock") :test #'string=)
                     (multiple-value-bind (ok message) (admin-do-set-lock folder res (string= act "lock"))
                       (when ok (setf message (format nil "~a~a" message (admin-regen folder))))
                       (admin-show-keys pw folder res :message message :ok ok)))
                    ((string= act "issue")
                     (let ((scope (if (string= (get1 "scope") "board") "*" res)))
                       (multiple-value-bind (kid issued) (key-issue folder (get1 "label") scope)
                         (declare (ignore kid))
                         (if (null issued)
                             (admin-show-keys pw folder res :message "キーを保存できませんでした。" :ok nil)
                             (admin-show-keys pw folder res :message (admin-regen folder) :ok t :issued issued)))))
                    ((string= act "revoke")
                     (let* ((key-id (get1 "id"))
                            (ok (and (and (= (length key-id) 4) (every (lambda (c) (find c *key-alphabet*)) key-id))
                                     (key-revoke folder key-id))))
                       (let ((message (if ok (format nil "キー ~a を失効しました。" key-id) "キーを失効できませんでした。")))
                         (when ok (setf message (format nil "~a~a" message (admin-regen folder))))
                         (admin-show-keys pw folder res :message message :ok (and ok t)))))
                    ((string= act "delete")
                     (let ((nums (loop for x in (getall "del") when (digits-p x 1 6) collect (parse-integer x))))
                       (multiple-value-bind (ok message) (admin-do-delete folder res nums)
                         (when ok (setf message (format nil "~a~a" message (admin-regen folder))))
                         (admin-show-replies pw folder res :message message :ok ok))))
                    ((string= act "hide")
                     (multiple-value-bind (ok message) (admin-do-hide folder res)
                       (when ok (setf message (format nil "~a~a" message (admin-regen folder))))
                       (admin-show-threads pw folder :message message :ok ok)))
                    ((string= act "restore")
                     (multiple-value-bind (ok message) (admin-do-restore folder res)
                       (when ok (setf message (format nil "~a~a" message (admin-regen folder))))
                       (admin-show-threads pw folder :message message :ok ok)))
                    (t (admin-fatal pw "不明な操作です。"))))))))))
