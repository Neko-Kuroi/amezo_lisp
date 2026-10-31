;;;; core.lisp - amezo.py の共通部分: 秘密鍵、トリップ/ID/キャップ、認証キー、
;;;; 中継リンク、板の再生成 (regen_index)、過去ログ一覧
(in-package :amezo)

;;; ---------- リクエスト/レスポンスの抽象 (CGI の exit の代わり) ----------
(defstruct request
  (method "GET") (query-string "") (body nil) ; body は octet vector
  (headers '())                              ; alist: 大文字の名前 -> 値
  (remote-addr "") (script-name ""))

(defstruct response
  (status 200) (headers '()) (body ""))      ; body は文字列 (サーバで UTF-8 化)

(defun request-header (req name)
  (or (cdr (assoc name (request-headers req) :test #'string-equal)) ""))

(defvar *request* nil "処理中のリクエスト (client-ip などが参照する)")

(define-condition bbs-exit (error)
  ((response :initarg :response :reader bbs-exit-response))
  (:documentation "Python 版の error()/redirect() の sys.exit 相当。レスポンスを持って抜ける。"))

(defun bail (resp) (error 'bbs-exit :response resp))

(defun html-header-response (body &key (status 200) extra-headers)
  (make-response :status status
                 :headers (append (list (cons "Content-Type" "text/html; charset=UTF-8")) extra-headers)
                 :body body))

(defun page-error (msg)
  "Python 版 amezo.error(): 200 でエラー文を出して終わる。"
  (bail (html-header-response
         (format nil "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"></head><body><h2>~a</h2></body></html>"
                 (html-escape msg)))))

(defun redirect-response (folder index-name)
  (let ((target (html-escape (format nil "~a/~a" folder index-name))))
    (bail (make-response
           :status 303
           :headers (list (cons "Location" (format nil "../~a" target))
                          (cons "Content-Type" "text/html; charset=UTF-8"))
           :body (format nil "<html><head><meta http-equiv=\"refresh\" content=\"0;url=../~a\"></head><body>Redirecting to <a href=\"../~a\">~a</a>...</body></html>"
                         target target target)))))

;;; ---------- 秘密鍵ファイル ----------
(defun read-secret-key (path)
  (let ((s (read-file-string path)))
    (when s
      (let ((txt (trim-space s)))
        (when (and (= (length txt) 64) (every (lambda (c) (digit-char-p c 16)) txt))
          (hex-decode txt))))))

(defun load-secret (path)
  "秘密鍵 (32バイト) を読む。無ければ作る (Python 版 load_secret)。保存できなければ NIL。"
  (let ((key (read-secret-key path)))
    (when key (return-from load-secret key))
    (setf key (random-octets 32))
    (let* ((data (format nil "~a~%" (hex-encode key)))
           (tmp (format nil "~a.tmp~d" (namestring path) (sb-posix:getpid))))
      ;; 一時ファイル (0600) に書いて os.link で置く。同時に作られても最初の鍵が全員に使われる
      (let ((fd (fd-open tmp :flags (logior sb-posix:o-wronly sb-posix:o-creat sb-posix:o-excl) :mode #o600)))
        (when fd
          (unwind-protect
               (let ((octs (utf8 data)))
                 (sb-posix:write fd (sb-sys:vector-sap octs) (length octs)))
            (fd-close fd))))
      (ignore-errors (sb-posix:link tmp (namestring path)))
      (ignore-errors (delete-file tmp))
      (let ((placed (read-secret-key path)))
        (when placed (return-from load-secret placed)))
      ;; ハードリンクが使えない環境: 最終ファイルを直接 (既にあれば失敗する形で) 作る
      (let ((fd (fd-open path :flags (logior sb-posix:o-wronly sb-posix:o-creat sb-posix:o-excl) :mode #o600)))
        (if fd
            (unwind-protect
                 (let ((octs (utf8 data)))
                   (sb-posix:write fd (sb-sys:vector-sap octs) (length octs)))
              (fd-close fd))
            ;; 他プロセスが書いている途中かもしれないので少し待つ
            (loop repeat 20 do (sleep 0.05) (when (read-secret-key path) (return-from load-secret (read-secret-key path))))))
      (unless (read-secret-key path)
        ;; 壊れた鍵ファイルは置き換える
        (ignore-errors (write-file-string path data) (chmod-file path #o600)))
      (read-secret-key path))))

;;; ---------- クライアント IP ----------
(defun client-ip ()
  (let ((addr (if *request* (request-remote-addr *request*) "")))
    (if (not (member addr *trusted-proxies* :test #'string=))
        addr
        (let ((cf (request-header *request* "CF-Connecting-IP")))
          (cond ((and (plusp (length cf)) (ip-valid-p cf)) cf)
                (t (let* ((parts (split-string (request-header *request* "X-Forwarded-For") #\,))
                          (last (and parts (trim-space (car (last parts))))))
                     (if (and last (ip-valid-p last)) last addr))))))))

;;; ---------- トリップ / ID / キャップ ----------
(defun trip-key ()
  (or (load-secret (app-path *trip-secret-file*)) (page-error "トリップ用の鍵を保存できません.")))

(defun id-key ()
  (or (load-secret (app-path *id-secret-file*)) (page-error "ID用の鍵を保存できません.")))

(defun key-secret-key ()
  (or (load-secret (app-path *key-secret-file*)) (page-error "認証キー用の鍵を保存できません.")))

(defun jump-secret-key ()
  (or (load-secret (app-path *jump-secret-file*)) (page-error "中継用の鍵を保存できません.")))

(defun clean-trip-password (password)
  (let ((pw (remove-if (lambda (c) (or (char= c #\Space) (char= c #\u3000))) password)))
    (setf pw (map 'string (lambda (c)
                            (if (<= #xFF01 (char-code c) #xFF5E)
                                (code-char (- (char-code c) #xFEE0))
                                c))
                  pw))
    (subseq pw 0 (min (length pw) *trip-pass-max*))))

(defun trip-transform (b64)
  (map 'string (lambda (c) (case c (#\+ #\.) (#\/ #\_) (otherwise c))) b64))

(defun make-trip (password)
  (let ((pw (clean-trip-password password)))
    (if (zerop (length pw))
        ""
        (let ((digest (hmac-sha256 (trip-key) (utf8 pw))))
          (trip-transform (subseq (base64-encode digest) 0 10))))))

(defun make-id (ip board epoch)
  (multiple-value-bind (y m d) (epoch->jst epoch)
    (let* ((msg (format nil "~a~a|~4,'0d~2,'0d~2,'0d|~a" *id-ctx* (ip-unit ip) y m d board))
           (digest (hmac-sha256 (id-key) (utf8 msg))))
      (trip-transform (subseq (base64-encode digest) 0 *id-len*)))))

(defun remove-name-spaces (s)
  (remove-if (lambda (c) (or (char= c #\Space) (char= c #\u3000) (char= c #\u200D))) s))

(defun is-cap (name-escaped password)
  (when (plusp (length password))
    (let ((lines (read-file-lines (app-path *cap-file*))))
      (dolist (line lines nil)
        (unless (or (string= line "") (starts-with-p "#" line) (not (find #\, line)))
          (let* ((pos (position #\, line :from-end t))
                 (cap-name (subseq line 0 pos))
                 (stored (subseq line (1+ pos))))
            (when (and (string= (html-escape (remove-name-spaces cap-name)) name-escaped)
                       (verify-hash password stored))
              (return t))))))))

(defun load-delcrypt ()
  (let ((s (read-file-string (app-path *delcrypt-file*))))
    (if s (trim-space s) "")))

;;; ---------- 板 ----------
(defun blist-lines ()
  (read-file-lines (app-path "blist.txt") '()))

(defun is-board (folder)
  (dolist (line (blist-lines) nil)
    (when (and (plusp (length line)) (string= (string-nth-field line 0 #\,) folder))
      (return t))))

(defun board-info (folder)
  "blist.txt から (values 背景色 タイトル)。無ければ (\"\" \"\")。"
  (dolist (line (blist-lines) (values "" ""))
    (when (plusp (length line))
      (let ((parts (split-string line #\,)))
        (when (string= (first parts) folder)
          (return (values (if (second parts) (second parts) "")
                          (if (third parts) (third parts) ""))))))))

(defun board-folders ()
  (let ((out '()))
    (dolist (line (blist-lines) (nreverse out))
      (let ((name (string-nth-field line 0 #\,)))
        (when (plusp (length name)) (push name out))))))

;;; ---------- 投稿制限 ----------
(defun post-interval-left (folder)
  (if (<= *post-interval* 0)
      0
      (let* ((s (read-file-string (app-path folder "lasttime.txt")))
             (last (and s (digits-p (trim-space s)) (parse-integer (trim-space s))))
             (left (and last (- *post-interval* (- (epoch-now) last)))))
        (if (and left (plusp left)) left 0))))

(defun touch-lasttime (folder)
  (when (plusp *post-interval*)
    (ignore-errors (write-file-string (app-path folder "lasttime.txt") (format nil "~d" (epoch-now))))))

(defun check-global-ip (ip)
  "同じ接続元の新規スレッドを GLOBAL_WINDOW 秒止める (Python 版 check_global_ip)。"
  (let* ((who (subseq (hmac-sha256-hex (id-key) (utf8 (format nil "~a~a" *rl-ctx* (ip-unit ip)))) 0 24))
         (path (app-path "global.mem")))
    (call-with-fd-lock path
                       (lambda (fd)
                         (declare (ignore fd))
                         (let ((now (epoch-now)) (table '()))
                           (dolist (line (read-file-lines path '()))
                             (let ((parts (split-string line #\Space :keep-empty nil)))
                               (when (and (= (length parts) 2) (digits-p (second parts))
                                          (< (- now (parse-integer (second parts))) *global-window*))
                                 (push (cons (first parts) (parse-integer (second parts))) table))))
                           (let ((hit (assoc who table :test #'string=)))
                             (when hit
                               (page-error (format nil "あと ~d 秒たってから投稿してください"
                                                   (- *global-window* (- now (cdr hit)))))))
                           (push (cons who now) table)
                           (write-file-string path
                                              (join-strings (mapcar (lambda (kv) (format nil "~a ~d~%" (car kv) (cdr kv)))
                                                                    (nreverse table))))))
                       :create-mode #o600)))

;;; ---------- 過去ログ ----------
(defun archived-path (folder name)
  "o数字.html の実体パス (平文優先、無ければ .gz)。無ければ NIL。"
  (let ((p (app-path folder name)))
    (cond ((file-regular-p p) p)
          ((file-regular-p (app-path folder (format nil "~a.gz" name))) (app-path folder (format nil "~a.gz" name)))
          (t nil))))

(defun archived-exists (folder res)
  (and (digits-p res) (archived-path folder (format nil "o~a.html" res)) t))

(defun thread-missing (folder res verb)
  (if (archived-exists folder res)
      (page-error (format nil "このスレッドは過去ログになったため~aできません." verb))
      (page-error "スレッドがありません.")))

;;; ---------- 中継リンク ----------
(defun url-is-valid (url)
  (and url
       (plusp (length url))
       (<= (length (utf8 url)) *url-max-len*)
       (let ((scheme-len (cond ((starts-with-p "http://" url) 7)
                               ((starts-with-p "https://" url) 8)
                               (t 0))))
         (and (plusp scheme-len)
              (< scheme-len (length url))
              (let ((c0 (char url scheme-len)))
                (or (alphanumericp c0) (char= c0 #\[)))
              (loop for c across url
                    always (or (alphanumericp c) (find c "-._~:/?#[]@!$*+,;=%()'&")))))))

(defun jump-sign (url)
  (subseq (b64url-encode (hmac-sha256 (jump-secret-key) (utf8 (format nil "~a~a" *jump-ctx* url))))
          0 *jump-sig-len*))

(defun jump-verify (url sig)
  (and (url-is-valid url) (constant-time-string-equal (jump-sign url) sig)))

(defun jump-href (url)
  (format nil "../jump.cgi?u=~a&amp;s=~a" (b64url-encode (utf8 url)) (jump-sign url)))

(defparameter *linkify-chars* "-._~:/?#[]@!$*+,;=%()")

(defun linkify-urls (escaped &optional (jump *jump-enabled*))
  "エスケープ済み本文の URL をリンクにする (Python 版 linkify_urls)。"
  (with-output-to-string (out)
    (let ((pos 0) (n (length escaped)))
      (loop
        (let ((start nil) (scheme-len 0))
          (loop for i from pos below n
                do (cond ((and (starts-with-p "https://" (subseq escaped i (min n (+ i 8))))
                               (setf start i scheme-len 8)) (return))
                         ((and (starts-with-p "http://" (subseq escaped i (min n (+ i 7))))
                               (setf start i scheme-len 7)) (return))))
          (unless start (write-string escaped out :start pos) (return))
          (write-string escaped out :start pos :end start)
          ;; URL 本体を貪欲に取る (&amp; / &#39; も1単位)
          (let ((end start))
            (loop while (< end n)
                  do (cond ((and (<= (+ end 5) n) (string= "&amp;" escaped :start2 end :end2 (+ end 5))) (incf end 5))
                           ((and (<= (+ end 5) n) (string= "&#39;" escaped :start2 end :end2 (+ end 5))) (incf end 5))
                           ((or (alphanumericp (char escaped end)) (find (char escaped end) *linkify-chars*))
                            (incf end))
                           (t (return))))
            (let* ((match (subseq escaped start end))
                   (dsp match) (tail ""))
              ;; 末尾の不要文字を tail へ
              (loop while (plusp (length dsp))
                    do (cond ((or (ends-with-p "&amp;" dsp) (ends-with-p "&#39;" dsp))
                              (setf tail (concatenate 'string (subseq dsp (- (length dsp) 5)) tail)
                                    dsp (subseq dsp 0 (- (length dsp) 5))))
                             ((find (char dsp (1- (length dsp))) ".,;:!?(")
                              (setf tail (concatenate 'string (subseq dsp (1- (length dsp))) tail)
                                    dsp (subseq dsp 0 (1- (length dsp)))))
                             ((and (char= (char dsp (1- (length dsp))) #\))
                                   (> (count #\) dsp) (count #\( dsp)))
                              (setf tail (concatenate 'string ")" tail) dsp (subseq dsp 0 (1- (length dsp)))))
                             ((and (char= (char dsp (1- (length dsp))) #\])
                                   (> (count #\] dsp) (count #\[ dsp)))
                              (setf tail (concatenate 'string "]" tail) dsp (subseq dsp 0 (1- (length dsp)))))
                             (t (return))))
              (let ((url (replace-all (replace-all dsp "&amp;" "&") "&#39;" "'")))
                (if (not (url-is-valid url))
                    (write-string match out)
                    (format out "<a href=\"~a\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">~a</a>~a"
                            (if jump (jump-href url) (html-escape url)) dsp tail)))
              (setf pos end))))))))

;;; ---------- 返信フォーム ----------
(defun reply-form (res &key (links "") locked)
  (format nil "<form method=post action=\"../amezo.cgi\" class=\"post\"><input type=hidden name=\"res\" value=\"~a\"><div class=\"row\">投稿者 <input type=text name=\"name\" size=20> メール <input type=text name=\"mail\" size=20 maxlength=50></div>~a<textarea name=\"comm\" rows=4 cols=70 maxlength=400></textarea><div class=\"row\"><input type=submit value=\"↑へのレスカキコ\"></div>~a</form>"
          res
          (if locked
              "<div class=\"row\">🔒 認証キー <input type=password name=\"key\" size=32 autocomplete=off required> このスレッドは認証キーがないと書き込めません</div>"
              "")
          links))

;;; ---------- 認証キー ----------
(defun thread-is-locked (folder res)
  (file-regular-p (app-path folder (format nil "~a.lock" res))))

(defstruct key-row id label hash scope created status)

(defun key-normalize (s)
  (let ((c (map 'string (lambda (ch) (char-upcase ch))
                (remove-if-not (lambda (ch) (or (alpha-char-p ch) (find ch "234567"))) (or s "")))))
    (if (= (length c) 24) c nil)))

(defun key-display (canon)
  (join-strings (loop for i from 0 below (length canon) by 4 collect (subseq canon i (+ i 4))) "-"))

(defun key-hash (canon)
  (hmac-sha256-hex (key-secret-key) (utf8 (format nil "~a~a" *key-ctx* canon))))

(defun parse-key-row (line)
  (let ((p (split-string line #\Tab)))
    (when (= (length p) 6)
      (make-key-row :id (nth 0 p) :label (nth 1 p) :hash (nth 2 p) :scope (nth 3 p)
                    :created (let ((s (nth 4 p)))
                               (handler-case
                                   (let ((end (position-if-not (lambda (c) (or (digit-char-p c) (char= c #\-))) s)))
                                     (if (and end (zerop end)) 0 (parse-integer s :junk-allowed t :end end)))
                                 (error () 0)))
                    :status (nth 5 p)))))

(defun keys-load (folder)
  (let ((rows '()))
    (dolist (line (read-file-lines (app-path folder *keys-file*) '()) (nreverse rows))
      (let ((r (parse-key-row line))) (when r (push r rows))))))

(defun key-find-row (folder kid)
  (dolist (line (read-file-lines (app-path folder *keys-file*) '()) nil)
    (when (starts-with-p (format nil "~a~a" kid #\Tab) line)
      (return (parse-key-row line)))))

(defun key-verify (folder res input-key)
  (let ((canon (key-normalize input-key)))
    (when canon
      (let ((row (key-find-row folder (subseq canon 0 4))))
        (and row
             (string= (key-row-status row) "active")
             (constant-time-string-equal (key-row-hash row) (key-hash canon))
             (or (string= (key-row-scope row) "*") (string= (key-row-scope row) res)))))))

(defun keys-update (folder fn)
  "keys.txt をロックして FN(全行) の結果で書き直す。失敗したら NIL。"
  (let ((lockpath (app-path folder "keys.lock")) (ok nil))
    (call-with-fd-lock lockpath
                       (lambda (fd)
                         (declare (ignore fd))
                         (let* ((rows (funcall fn (keys-load folder)))
                                (path (app-path folder *keys-file*))
                                (tmp (format nil "~a.tmp~d" (namestring path) (sb-posix:getpid))))
                           (handler-case
                               (progn (write-file-string tmp
                                                         (join-strings
                                                          (mapcar (lambda (r)
                                                                    (format nil "~a~a~a~a~a~a~a~a~a~a~a~%"
                                                                            (key-row-id r) #\Tab (key-row-label r) #\Tab
                                                                            (key-row-hash r) #\Tab (key-row-scope r) #\Tab
                                                                            (key-row-created r) #\Tab (key-row-status r)))
                                                                  rows)
                                                          ""))
                                      (chmod-file tmp #o600)
                                      (sb-posix:rename tmp (namestring path))
                                      (setf ok t))
                             (error () (ignore-errors (delete-file tmp))))))
                       :timeout 10)
    ok))

(defun key-issue (folder label scope)
  "戻り値: (values ID 表示用キー) または NIL。"
  (let ((label (trim-space (map 'string (lambda (c) (if (or (<= (char-code c) #x1f) (= (char-code c) #x7f)) #\Space c)) (or label "")))))
    (setf label (subseq label 0 (min (length label) 40)))
    (when (string= label "") (setf label "(無題)"))
    (when (and (string/= scope "*") (not (digits-p scope 1 20))) (return-from key-issue nil))
    (let ((result nil))
      (if (keys-update folder
                       (lambda (rows)
                         (let ((used (mapcar #'key-row-id rows)) (canon nil))
                           (loop do (setf canon (base32-encode (random-octets 15)))
                                 while (member (subseq canon 0 4) used :test #'string=))
                           (setf result (list (subseq canon 0 4) (key-display canon)))
                           (append rows (list (make-key-row :id (subseq canon 0 4) :label label
                                                            :hash (key-hash canon) :scope scope
                                                            :created (epoch-now) :status "active"))))))
          (values-list result)
          nil))))

(defun key-revoke (folder kid)
  (let ((hit nil))
    (let ((ok (keys-update folder
                           (lambda (rows)
                             (dolist (r rows rows)
                               (when (and (string= (key-row-id r) kid) (string= (key-row-status r) "active"))
                                 (setf (key-row-status r) "revoked" hit t)))))))
      (and ok hit))))

(defun thread-set-lock (folder res lock)
  (let ((path (app-path folder (format nil "~a.html" res))))
    (unless (file-regular-p path) (return-from thread-set-lock nil))
    (let ((result nil))
      (call-with-fd-lock path
                         (lambda (fd)
                           (declare (ignore fd))
                           (handler-case
                               (let* ((data (read-file-string path))
                                      (idx (and data (search (format nil "~%<form") data :from-end t)))
                                      (footer (if idx (1+ idx) (length data)))
                                      (new (format nil "~a</body></html>~%" (reply-form res :locked lock))))
                                 (write-file-string path (concatenate 'string (subseq data 0 footer) new))
                                 (let ((lockfile (app-path folder (format nil "~a.lock" res))))
                                   (if lock
                                       (write-file-string lockfile "")
                                       (when (probe-file lockfile) (delete-file lockfile)))
                                   (setf result t)))
                             (error () nil)))
                         :timeout 10)
      result)))

;;; ---------- スレッドの読み取り ----------
(defun read-thread-title (path)
  "スレッドファイル (または .gz) の1行目から <b>題名</b> を取る。読めなければ \"\"。"
  (handler-case
      (let ((first (if (ends-with-p ".gz" (namestring path))
                       (let ((tmp (gunzip-to-string path))) (and tmp (first-line tmp)))
                       (let ((s (read-file-string path)))
                         (and s (first-line s))))))
        (and first (extract-tag-content first "b") ""))
    (error () "")))

(defun first-line (s)
  (let ((p (position #\Newline s))) (if p (subseq s 0 p) s)))

(defun extract-tag-content (s tag)
  "最初の <tag>...</tag> の中身。無ければ NIL。"
  (let* ((open (format nil "<~a>" tag))
         (close (format nil "</~a>" tag))
         (a (search open s)))
    (when a
      (let ((b (search close s :start2 (+ a (length open)))))
        (when b (subseq s (+ a (length open)) b))))))

(defun extract-first-b (s)
  "正規表現 <b>([^<]*)</b> 相当: 最初の <b> から < まで。"
  (let ((a (search "<b>" s)))
    (when a
      (let ((b (search "<" s :start2 (+ a 3))))
        (when b (subseq s (+ a 3) b))))))

(defun gunzip-to-string (path)
  "外部 gzip で展開して文字列にする。失敗したら NIL。"
  (handler-case
      (let ((proc (sb-ext:run-program "gzip" (list "-dc" (namestring path))
                                      :output :stream :error nil :search t :wait nil)))
        (when proc
          (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
                (buf (make-array 65536 :element-type '(unsigned-byte 8)))
                (stream (sb-ext:process-output proc)))
            (loop for n = (read-sequence buf stream)
                  while (plusp n)
                  do (loop for i from 0 below n do (vector-push-extend (aref buf i) out)))
            (sb-ext:process-wait proc)
            (when (zerop (sb-ext:process-exit-code proc))
              (utf8-decode (coerce out '(vector (unsigned-byte 8))))))))
    (error () nil)))

(defun count-newlines-in-file (path)
  (handler-case
      (let ((n 0) (buf (make-array 65536 :element-type '(unsigned-byte 8))))
        (with-open-file (in path :element-type '(unsigned-byte 8))
          (loop for c = (read-sequence buf in)
                while (plusp c)
                do (incf n (count (char-code #\Newline) buf :end c))))
        n)
    (error () 0)))
