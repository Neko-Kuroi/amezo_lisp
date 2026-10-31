;;;; server.lisp - 簡易 Web サーバー (Python 版 setup_expose.py のルーティング部分)
;;;; 許可リスト方式の静的配信、不正パスの 400、過去ログ gz 配信、CGI の内部ディスパッチ。
(in-package :amezo)

(require :sb-bsd-sockets)
(require :sb-concurrency)

(defvar *verbose* nil)
(defparameter *allowed-cgi* '("amezo" "dai" "admin" "jump"))
(defparameter *static-root-files* '("/" "/index.html" "/style.css" "/hide.js" "/ad.html"))
(defvar *server-thread* nil)
(defvar *server-socket* nil)

;;; ---------- 起動時準備 ----------
(defun check-flock-works ()
  (let ((path (app-path ".flock_test")) (fd1 nil) (fd2 nil) (effective nil))
    (unwind-protect
         (progn (setf fd1 (fd-open path :mode #o600) fd2 (and fd1 (fd-open path)))
                (when (and fd1 fd2)
                  (fd-lock fd1)
                  (setf effective (not (fd-lock fd2 :nonblocking t)))))
      (fd-close fd1) (fd-close fd2) (ignore-errors (delete-file path)))
    (unless effective
      (format t "  ⚠️ このディレクトリでは flock が効いていないか、確認できませんでした。~%     同時に投稿されるとファイルが壊れるおそれがあります。ローカルディスクに置いてください。~%"))))

(defun setup-bbs-directories ()
  (format t "📂 BBS用のディレクトリとパーミッションを設定しています...~%")
  (dolist (needed '("index.html" "style.css" "hide.js" "header.html" "blist.txt"))
    (unless (file-regular-p (app-path needed)) (format t "  ⚠️ ~a が見つかりません~%" needed)))
  (unless (file-regular-p (app-path "delpass.txt"))
    (format t "  ℹ️ delpass.txt がありません。管理画面を使うなら: ./run.sh --make-hash 合言葉~%"))
  (check-flock-works)
  (dolist (board (board-folders))
    (let ((dir (app-path board)))
      (ensure-dir dir)
      (let ((index (app-path board "index.html")))
        (when (or (not (file-regular-p index)) (< (or (file-size-of index) 0) 100))
          (write-file-string index (format nil "<html><head><meta http-equiv=\"refresh\" content=\"0;url=../amezo.cgi?folder=~a\"></head><body>Redirecting to BBS...</body></html>~%" board))
          (set-file-mtime index (- (epoch-now) 3600))
          (format t "  - 初期リダイレクト用ファイルを配置: ~a/index.html~%" board))))))

;;; ---------- パスの検査 (Python 版 is_malformed_path) ----------
(defun dot-segment-p (path)
  (let ((parts (split-string path #\/ :keep-empty t)))
    (member "." parts :test #'string=)))

(defun malformed-path-p (raw-path)
  (or (string= raw-path "") (not (starts-with-p "/" raw-path))
      (search "//" raw-path) (find #\% raw-path) (find #\\ raw-path)
      (find (code-char 0) raw-path) (search ".." raw-path)
      (dot-segment-p raw-path)))

(defun accepts-gzip-p (header)
  (dolist (tok (split-string (or header "") #\,) nil)
    (let* ((parts (mapcar #'trim-space (split-string tok #\;)))
           (name (string-downcase (first parts))))
      (when (or (string= name "gzip") (string= name "x-gzip"))
        (let ((q 1.0))
          (dolist (p (rest parts))
            (when (and (> (length p) 2) (string-equal (subseq p 0 2) "q="))
              (setf q (handler-case (float (parse-integer (subseq p 2) :junk-allowed t) 1.0) (error () 1.0))
                    q (handler-case (read-from-string (subseq p 2)) (error () 1.0)))))
          (return (plusp q)))))))

;;; ---------- HTTP の読み書き ----------
(defun read-ascii-line (stream)
  "CRLF / LF 終端の1行を、バイト列そのままの文字列で返す。EOF なら NIL。"
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (any nil))
    (loop for b = (read-byte stream nil nil)
          while b
          do (setf any t)
             (if (= b (char-code #\Newline)) (return) (vector-push-extend b out)))
    (when any
      (let ((n (length out)))
        (when (and (plusp n) (= (aref out (1- n)) (char-code #\Return))) (setf out (subseq out 0 (1- n))))
        (map 'string #'code-char out)))))

(defun write-response (stream status headers body-octets &key head-only)
  (let ((reason (case status
                  (200 "OK") (303 "See Other") (400 "Bad Request") (404 "Not Found")
                  (413 "Payload Too Large") (500 "Internal Server Error") (501 "Not Implemented")
                  (504 "Gateway Timeout") (otherwise ""))))
    (let ((head (with-output-to-string (out)
                  (format out "HTTP/1.1 ~d ~a~a" status reason (format nil "~a~a" #\Return #\Newline))
                  (dolist (h headers) (format out "~a: ~a~a" (car h) (cdr h) (format nil "~a~a" #\Return #\Newline)))
                  (unless (assoc "Content-Length" headers :test #'string-equal)
                    (format out "Content-Length: ~d~a" (length body-octets) (format nil "~a~a" #\Return #\Newline)))
                  (format out "Connection: close~a" (format nil "~a~a" #\Return #\Newline))
                  (format out "~a" (format nil "~a~a" #\Return #\Newline)))))
      (write-sequence (utf8 head) stream))
    (unless head-only (write-sequence body-octets stream))
    (finish-output stream)))

(defun respond (stream status headers body &key head-only)
  (write-response stream status headers (if (stringp body) (utf8 body) body) :head-only head-only))

(defun respond-error (stream status message)
  (respond stream status (list (cons "Content-Type" "text/plain; charset=UTF-8")) message))

;;; ---------- ルーティング ----------
(defun board-file-allowed-p (name)
  ;; (?:index\d*|kako|o?\d+)\.html
  (and (ends-with-p ".html" name)
       (let ((base (subseq name 0 (- (length name) 5))))
         (or (string= base "kako")
             (and (starts-with-p "index" base) (or (= (length base) 5) (digits-p (subseq base 5))))
             (and (plusp (length base)) (digits-p base))
             (and (> (length base) 1) (char= (char base 0) #\o) (digits-p (subseq base 1)))))))

(defun static-allowed-p (path)
  (cond ((member path *static-root-files* :test #'string=) t)
        (t (let ((rest (and (> (length path) 1) (subseq path 1))))
             (when rest
               (multiple-value-bind (board tail) (split-once rest #\/)
                 (and (is-board board)
                      (or (null tail) (string= tail "") (board-file-allowed-p tail)))))))))

(defun static-file-path (path)
  (cond ((or (string= path "/") (string= path "/index.html")) (app-path "index.html"))
        ((member path *static-root-files* :test #'string=) (app-path (subseq path 1)))
        (t (multiple-value-bind (board tail) (split-once (subseq path 1) #\/)
             (if (or (null tail) (string= tail ""))
                 (app-path board "index.html")
                 (app-path board tail))))))

(defun cgi-name (path)
  " /xxx.cgi / /xxx.py なら xxx (許可されたものだけ)。それ以外は NIL。"
  (let ((rest (and (> (length path) 1) (subseq path 1))))
    (when (and rest (not (find #\/ rest)))
      (multiple-value-bind (base ext) (split-once rest #\.)
        (when (and (member ext '("cgi" "py") :test #'string=) (member base *allowed-cgi* :test #'string=))
          base)))))

(defun archived-gz-path (raw-path)
  (let ((parts (split-string raw-path #\/ :keep-empty nil)))
    (when (and (= (length parts) 2) (is-board (first parts)))
      (let ((name (second parts)))
        (when (and (> (length name) 6) (char= (char name 0) #\o) (ends-with-p ".html" name)
                   (digits-p (subseq name 1 (- (length name) 5))))
          (let ((plain (app-path (first parts) name)) (gz (app-path (first parts) (format nil "~a.gz" name))))
            (when (file-regular-p gz)
              (when (or (not (file-regular-p plain))
                        (= (truncate (file-mtime-of plain)) (truncate (file-mtime-of gz))))
                gz))))))))

(defun serve-archived (stream gz headers-in &key head-only)
  (let ((accept (cdr (assoc "Accept-Encoding" headers-in :test #'string-equal))))
    (if (accepts-gzip-p accept)
        (write-response stream 200
                        (list (cons "Content-Type" "text/html; charset=UTF-8")
                              (cons "Vary" "Accept-Encoding")
                              (cons "X-Content-Type-Options" "nosniff")
                              (cons "Cache-Control" "public, max-age=3600")
                              (cons "Content-Encoding" "gzip"))
                        (read-file-octets gz) :head-only head-only)
        (let ((plain (gunzip-to-string gz)))
          (if plain
              (write-response stream 200
                              (list (cons "Content-Type" "text/html; charset=UTF-8")
                                    (cons "Vary" "Accept-Encoding")
                                    (cons "X-Content-Type-Options" "nosniff")
                                    (cons "Cache-Control" "public, max-age=3600"))
                              (utf8 plain) :head-only head-only)
              (respond-error stream 404 "Not Found"))))))

(defun dispatch-cgi (name req stream &key head-only)
  (let ((resp (handler-case
                  (case (intern (string-upcase name) :keyword)
                    (:AMEZO (handle-amezo req))
                    (:DAI (handle-dai req))
                    (:ADMIN (handle-admin req))
                    (:JUMP (handle-jump req)))
                (error (e)
                  (format *error-output* "amezo: ~a の処理でエラー: ~a~%" name e)
                  (make-response :status 500 :headers (list (cons "Content-Type" "text/plain; charset=UTF-8"))
                                 :body "Internal Server Error")))))
    (when resp
      (write-response stream (response-status resp) (response-headers resp)
                      (utf8 (response-body resp)) :head-only head-only))))

(defparameter *max-post-bytes-server* 65536)

(defun handle-connection (socket)
  (let ((stream nil))
    (unwind-protect
         (handler-case
             (progn
               (setf stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                               :element-type '(unsigned-byte 8) :buffering :none))
               (let ((request-line (read-ascii-line stream)))
                 (when request-line
                   (let* ((parts (split-string request-line #\Space :keep-empty nil))
                          (method (first parts)) (target (second parts))
                          (headers '()) (content-length 0))
                     ;; ヘッダー
                     (loop for line = (read-ascii-line stream)
                           while (and line (plusp (length line)))
                           do (multiple-value-bind (k v) (split-once line #\:)
                                (when v
                                  (push (cons (trim-space k) (trim-space v)) headers)
                                  (when (string-equal (trim-space k) "Content-Length")
                                    (setf content-length (or (safe-integer (trim-space v)) 0))))))
                     (setf headers (nreverse headers))
                     (when (< content-length 0) (setf content-length 0))
                     (cond ((> content-length *max-post-bytes-server*)
                            ;; 本体を読まずに拒否 (Python 版と同じ)
                            (respond-error stream 413 "Payload Too Large"))
                           (t
                            (let ((body (make-array content-length :element-type '(unsigned-byte 8))))
                              (when (plusp content-length) (read-sequence body stream))
                              (route-request stream method target headers body socket))))))))
           (error (e) (format *error-output* "amezo: 接続処理でエラー: ~a~%" e)))
      (when stream (ignore-errors (close stream)))
      (ignore-errors (sb-bsd-sockets:socket-close socket)))))

(defun route-request (stream method target headers body socket)
  (let* ((qpos (position #\? target))
         (raw-path (if qpos (subseq target 0 qpos) target))
         (query (if qpos (subseq target (1+ qpos)) ""))
         (head-only (string= method "HEAD")))
    (when *verbose* (format t "  ~a ~a~%" method target))
    (when (malformed-path-p raw-path)
      (respond-error stream 400 "Bad Request")
      (return-from route-request nil))
    ;; 過去ログ gz
    (when (member method '("GET" "HEAD") :test #'string=)
      (let ((gz (archived-gz-path raw-path)))
        (when gz (serve-archived stream gz headers :head-only head-only) (return-from route-request nil))))
    (let ((name (cgi-name raw-path)))
      (cond (name
             (when (member method '("GET" "POST" "HEAD") :test #'string=)
               (let* ((peer (ignore-errors (sb-bsd-sockets:socket-peername socket)))
                      (remote (if (and peer (vectorp peer) (= (length peer) 4))
                                  (format nil "~{~d~^.~}" (coerce peer 'list))
                                  "127.0.0.1"))
                      (req (make-request :method (if head-only "GET" method) :query-string query :body body
                                         :headers headers :remote-addr remote :script-name raw-path)))
                 (dispatch-cgi name req stream :head-only head-only))))
            ((member method '("GET" "HEAD") :test #'string=)
             (if (not (static-allowed-p raw-path))
                 (respond-error stream 404 "Not Found")
                 (let ((path (static-file-path raw-path)))
                   (if (file-regular-p path)
                       (let ((type (cond ((ends-with-p ".css" (namestring path)) "text/css")
                                         ((ends-with-p ".js" (namestring path)) "text/javascript")
                                         (t "text/html"))))
                         (write-response stream 200 (list (cons "Content-Type" type))
                                         (read-file-octets path) :head-only head-only))
                       (respond-error stream 404 "Not Found")))))
            ((string= method "POST") (respond-error stream 501 "Can only POST to CGI scripts"))
            (t (respond-error stream 501 "Not Implemented"))))))

;;; ---------- サーバ本体 ----------
(defun start-server (port)
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (sb-bsd-sockets:socket-bind socket #(127 0 0 1) port)
    (sb-bsd-sockets:socket-listen socket 50)
    (setf *server-socket* socket)
    (format t "🚀 Webサーバーを起動しています (ポート ~d)...~%" port)
    (setf *server-thread*
          (sb-thread:make-thread
           (lambda ()
             (loop for client = (ignore-errors (sb-bsd-sockets:socket-accept socket))
                   while client
                   do (sb-thread:make-thread (let ((c client)) (lambda () (handle-connection c)))
                                             :name "amezo-conn")))
           :name "amezo-server"))
    socket))

(defun http-status (port path)
  "自己チェック用の単純な GET。ステータスコードを返す (失敗は 0)。"
  (handler-case
      (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
        (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
        (let ((stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                         :element-type '(unsigned-byte 8) :buffering :none)))
          (write-sequence (utf8 (format nil "GET ~a HTTP/1.1~aHost: 127.0.0.1~aConnection: close~a~a"
                                        path (format nil "~a~a" #\Return #\Newline) (format nil "~a~a" #\Return #\Newline)
                                        (format nil "~a~a" #\Return #\Newline) (format nil "~a~a" #\Return #\Newline)))
                          stream)
          (finish-output stream)
          (let ((line (read-ascii-line stream)))
            (prog1 (if line (or (safe-integer (second (split-string line #\Space :keep-empty nil))) 0) 0)
              (ignore-errors (close stream)) (ignore-errors (sb-bsd-sockets:socket-close socket))))))
    (error () 0)))

(defun self-check (port)
  (format t "🔎 起動チェック:~%")
  (let ((good t))
    (dolist (check '(("/dai.cgi" 200) ("/jump.cgi" 200) ("/style.css" 200) ("/hide.js" 200)
                     ("//amezo.py" 400) ("/setup_expose.py" 404) ("/amezo.lisp" 404)
                     ("/trip_secret.txt" 404) ("/id_secret.txt" 404) ("/delpass.txt" 404)
                     ("/cap.txt" 404) ("/blist.txt" 404) ("/config.ini" 404)
                     ("/key_secret.txt" 404) ("/jump_secret.txt" 404) ("/ng.txt" 404)
                     ("/src/core.lisp" 404) ("//archive.py" 400)))
      (let ((got (http-status port (first check))))
        (unless (= got (second check)) (setf good nil))
        (format t "  ~a ~a -> ~d~a~%" (if (= got (second check)) "✅" "❌") (first check) got
                (if (= got (second check)) "" (format nil " (期待: ~d)" (second check))))))
    (unless good (format t "  ⚠️ 期待と違う結果があります。公開する前に server.lisp の配信判定を確認してください。~%"))
    good))

(defun serve (port &key tunnel)
  (setup-bbs-directories)
  (start-server port)
  ;; 起動待ち
  (loop repeat 50 do (when (= (http-status port "/style.css") 200) (return)) (sleep 0.2))
  (format t "✅ Webサーバーがポート ~d で正常に応答しました。~%" port)
  (self-check port)
  (when tunnel
    (let ((bin (or (ignore-errors (sb-ext:process-output
                                   (sb-ext:run-program "which" '("cloudflared") :output :stream :wait t)))
                   nil)))
      (declare (ignore bin))
      (if (ignore-errors (sb-ext:run-program "cloudflared" (list "tunnel" "--url" (format nil "http://127.0.0.1:~d" port))
                                             :output nil :error nil :wait nil :search t))
          (format t "☁️ Cloudflare Tunnel を起動しました (URL は cloudflared の出力を見てください)。~%")
          (format t "⚠️ cloudflared が見つからないため、トンネルは張れませんでした。~%"))))
  (format t "~%🏠 ローカルで起動しました: http://127.0.0.1:~d/~%~%⏳ サーバー稼働中... 停止するには Ctrl+C を押してください。~%" port)
  (handler-case (loop (sleep 3600))
    (sb-sys:interactive-interrupt () (format t "~%🛑 終了します。~%")))
  (ignore-errors (sb-bsd-sockets:socket-close *server-socket*))
  0)
