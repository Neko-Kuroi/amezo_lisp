;;;; jump.lisp - 署名つき中継ページ (Python 版 jump.py)
(in-package :amezo)

(defparameter *jump-style*
  ":root{color-scheme:light dark}body{font-family:sans-serif;max-width:40em;margin:1.5em auto;padding:0 1em;line-height:1.6}.url{word-break:break-all;border:1px solid #888;padding:.6em .8em;margin:.8em 0;font-family:monospace}.host{font-size:1.4em;font-weight:bold;word-break:break-all}.btns{margin:1.2em 0}.go,.back{display:inline-block;padding:.5em 1.6em;margin-right:.8em;border:1px solid #888;border-radius:6px;font-size:1em;text-decoration:none;cursor:pointer;background:transparent;color:inherit}.go{font-weight:bold}.note{font-size:.9em;opacity:.85}.warn{border:1px solid #c60;padding:.4em .7em;margin:.6em 0}.ad{margin:1.5em 0}.ad small{display:block;opacity:.7}.ad iframe{width:100%;height:260px;border:1px solid #888}")

(defun jump-page (title body nonce &key (with-back t))
  (bail (make-response
         :status 200
         :headers (list (cons "Content-Type" "text/html; charset=UTF-8")
                        (cons "Cache-Control" "no-store")
                        (cons "X-Robots-Tag" "noindex, nofollow")
                        (cons "Referrer-Policy" "no-referrer")
                        (cons "X-Content-Type-Options" "nosniff")
                        (cons "Content-Security-Policy"
                              (format nil "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-~a'; frame-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" nonce)))
         :body (format nil "<!DOCTYPE html><html lang=\"ja\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"robots\" content=\"noindex, nofollow\"><meta name=\"referrer\" content=\"no-referrer\"><title>~a</title><style>~a</style></head><body><h2>~a</h2>~a~a</body></html>"
                       (html-escape title) *jump-style* (html-escape title) body
                       (if with-back
                           (format nil "<script nonce=\"~a\">document.getElementById(\"back\").addEventListener(\"click\",function(){if(history.length>1){history.back();}else{window.close();}});</script>" nonce)
                           "")))))

(defun parse-host (url)
  (let ((p (search "://" url)))
    (when p
      (let* ((rest (subseq url (+ p 3)))
             (auth-end (or (position-if (lambda (c) (find c "/?#")) rest) (length rest)))
             (auth (subseq rest 0 auth-end))
             (at (position #\@ auth :from-end t)))
        (setf auth (if at (subseq auth (1+ at)) auth))
        (let ((host (if (starts-with-p "[" auth)
                        (let ((e (position #\] auth))) (if e (subseq auth 0 (1+ e)) auth))
                        (let ((c (position #\: auth))) (if c (subseq auth 0 c) auth)))))
          (if (plusp (length host)) host nil))))))

(defun handle-jump (req)
  (let ((*request* req))
    (handler-case (jump-main req)
      (bbs-exit (e) (bbs-exit-response e)))))

(defun jump-main (req)
  (let* ((nonce (hex-encode (random-octets 12)))
         (params (parse-params (request-query-string req)))
         (get-string (lambda (k)
                       (let ((v (cdr (assoc k params :test #'string=))))
                         ;; u[]=... のような配列形式は文字列ではない (None) として扱う: parse-params は
                         ;; キーに [ を含むものを別キーにするので、通常キーはそのまま使える
                         (or v ""))))
         (u (funcall get-string "u"))
         (s (funcall get-string "s"))
         (raw (and (<= (length u) 3000) (b64url-decode u)))
         (url (and raw (handler-case (sb-ext:octets-to-string raw :external-format :utf-8) (error () nil)))))
    (when (or (null url) (not (jump-verify url s)))
      (let ((body "<p>このリンクは、署名が合わないため、自動では開きません。<br>掲示板に投稿された URL ではないか、投稿のあとに署名の鍵が変わった可能性があります。</p>"))
        (when (and url (url-is-valid url))
          (setf body (format nil "~a<p class=\"note\">URL (リンクにはしていません。確かめてから、自分で開いてください):</p><div class=\"url\">~a</div>"
                             body (html-escape url))))
        (setf body (format nil "~a<div class=\"btns\"><button type=\"button\" class=\"back\" id=\"back\">戻る</button></div>" body))
        (jump-page "このリンクは使えません" body nonce)))
    (let ((host (or (parse-host url) "(ホスト名を読み取れません)")))
      (let ((body (format nil "<p>この掲示板に投稿された、外部サイトへのリンクです。移動先を確かめてから、「進む」を押してください。</p><p class=\"note\">移動先のサイト</p><div class=\"host\">~a</div><p class=\"note\">URL 全体</p><div class=\"url\">~a</div>"
                          (html-escape host) (html-escape url))))
        (when (search "xn--" (string-downcase host))
          (setf body (format nil "~a<div class=\"warn\">ドメイン名に <code>xn--</code> が含まれています。見た目が似た別のサイトのことがあるので、特に注意してください。</div>" body)))
        (setf body (format nil "~a<div class=\"btns\"><a class=\"go\" href=\"~a\" rel=\"noopener noreferrer nofollow\" referrerpolicy=\"no-referrer\">進む</a><button type=\"button\" class=\"back\" id=\"back\">戻る</button></div><p class=\"note\">このページは自動では転送しません。リンク先の内容について、掲示板は責任を負いません。</p>"
                           body (html-escape url)))
        (when (file-regular-p (app-path "ad.html"))
          (setf body (format nil "~a<div class=\"ad\"><small>広告</small><iframe src=\"ad.html\" sandbox=\"allow-scripts allow-popups\" referrerpolicy=\"no-referrer\" loading=\"lazy\" title=\"広告\"></iframe></div>" body)))
        (jump-page "外部サイトへ移動します" body nonce)))))
