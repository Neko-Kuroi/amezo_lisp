;;;; unit-test.lisp - 関数レベルのテスト (sbcl --script tests/unit-test.lisp)
(load (merge-pathnames "../load.lisp" (make-pathname :name nil :type nil :defaults (or *load-truename* *default-pathname-defaults*)))
      :verbose nil)
(in-package :amezo)

(defvar *ok* 0)
(defvar *ng* 0)
(defun chk (name cond &optional (extra ""))
  (if cond (progn (incf *ok*) (format t "OK ~a~%" name))
      (progn (incf *ng*) (format t "NG ~a ~a~%" name extra))))
(defun chk= (name got want)
  (chk name (equal got want) (format nil "got=~s want=~s" got want)))

;;; 作業用の一時フォルダを掲示板ルートにする
(defvar *tmp* (sb-posix:mkdtemp "/tmp/amezo-unit-XXXXXX"))
(setf *app-dir* (pathname (format nil "~a/" *tmp*)))
(write-file-string (app-path "blist.txt") "main,#ddeedd,広場~%zatsu,#ffeedd,雑談~%test,#ffffff,テスト~%")
(ensure-dir (app-path "main"))
(load-config)

;;; ---- SHA-256 / HMAC / PBKDF2 (既知のベクタ) ----
(chk= "sha256 abc" (sha256-hex (utf8 "abc")) "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
(chk= "sha256 空" (sha256-hex (utf8 "")) "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
(chk= "sha256 長い" (sha256-hex (utf8 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
(chk= "hmac RFC4231-1"
      (hmac-sha256-hex (make-array 20 :element-type '(unsigned-byte 8) :initial-element #x0b) (utf8 "Hi There"))
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
(chk= "pbkdf2 1回" (hex-encode (pbkdf2-sha256 (utf8 "password") (utf8 "salt") 1 32))
      "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
(chk= "pbkdf2 2回" (hex-encode (pbkdf2-sha256 (utf8 "password") (utf8 "salt") 2 32))
      "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")

;;; ---- base64 / base32 ----
(chk= "base64" (base64-encode (utf8 "hello")) "aGVsbG8=")
(chk= "base64url decode" (utf8-decode (b64url-decode "aHR0cHM6Ly9leGFtcGxlLmNvbS8_YT0xJmI9Mg")) "https://example.com/?a=1&b=2")
(chk "b64url 不正文字は NIL" (null (b64url-decode "a+b/c")))
(chk= "base32 15バイト" (base32-encode (make-array 15 :element-type '(unsigned-byte 8) :initial-element 0))
      "AAAAAAAAAAAAAAAAAAAAAAAA")

;;; ---- パスワードハッシュ (Python 版と相互運用) ----
(chk "verify: Python で作ったハッシュが通る"
     (verify-hash "adminpw" "pbkdf2_sha256$100000$00112233445566778899aabbccddeeff$98f2efc2fb0e7cb91857ece58878bd93a63f06ed7e166fdbdddcf780bfbf96dd"))
(chk "verify: 間違いは通らない"
     (not (verify-hash "wrongpw" "pbkdf2_sha256$100000$00112233445566778899aabbccddeeff$98f2efc2fb0e7cb91857ece58878bd93a63f06ed7e166fdbdddcf780bfbf96dd")))
(chk "make-hash 往復" (verify-hash "ひみつ" (make-hash "ひみつ")))

;;; ---- トリップ / ID (鍵を固定して Python 版の計算と一致するか) ----
(write-file-string (app-path *trip-secret-file*) (format nil "~a~%" (join-strings (make-list 32 :initial-element "aa") "")))
(write-file-string (app-path *id-secret-file*) (format nil "~a~%" (join-strings (make-list 32 :initial-element "aa") "")))
(write-file-string (app-path *jump-secret-file*) (format nil "~a~%" (join-strings (make-list 32 :initial-element "aa") "")))
(write-file-string (app-path *key-secret-file*) (format nil "~a~%" (join-strings (make-list 32 :initial-element "aa") "")))
(chk= "トリップ" (make-trip "testpw") "LzM4cgqcw.")
(chk= "トリップ: 空はなし" (make-trip "") "")
(chk= "ID" (make-id "127.0.0.1" "main" 1793433455) "8KeqkkDP")
(chk= "JST 日時" (format-jst-date 1793433455) "2026年10月31日(土)16時57分35秒")
(chk= "スレッド番号" (format-res-number 1793433455) "261031165735")

;;; ---- 中継リンク ----
(chk= "jump 署名" (jump-sign "https://example.com/?a=1&b=2") "YcP70X8lmTkV4tYoh5YGrM")
(chk "jump 照合" (jump-verify "https://example.com/?a=1&b=2" "YcP70X8lmTkV4tYoh5YGrM"))
(chk "jump 改ざんは通らない" (not (jump-verify "https://example.com/?a=1&b=2" "AAAAAAAAAAAAAAAAAAAAAA")))
(chk= "linkify"
      (linkify-urls "見て https://example.com/?a=1&amp;b=2 ね")
      "見て <a href=\"../jump.cgi?u=aHR0cHM6Ly9leGFtcGxlLmNvbS8_YT0xJmI9Mg&amp;s=YcP70X8lmTkV4tYoh5YGrM\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">https://example.com/?a=1&amp;b=2</a> ね")
(chk "url_is_valid: javascript は不可" (not (url-is-valid "javascript:alert(1)")))

;;; ---- 認証キー ----
(multiple-value-bind (kid disp) (key-issue "main" "テスト" "260101000000")
  (chk "鍵: 発行できる" (and kid disp (= (length disp) 29)))
  (chk "鍵: 照合できる" (key-verify "main" "260101000000" disp))
  (chk "鍵: 範囲外は不可" (not (key-verify "main" "260101000001" disp)))
  (chk "鍵: 失効できる" (key-revoke "main" kid))
  (chk "鍵: 失効後は不可" (not (key-verify "main" "260101000000" disp))))
(chk= "鍵: ハッシュ" (key-hash "ABCD2345EFGH2345IJKL2345")
      "f22f36da875f3f733d0214c3e77019e9e9b61c50b160a6e2c5fba07d554e3670")

;;; ---- config.ini の検査 ----
(chk= "config: 整数" (nth-value 0 (config-check :int "42" 0 100)) t)
(chk "config: 範囲外" (not (nth-value 0 (config-check :int "4200" 0 100))))
(chk "config: 表の既定値は自分の検査を通る"
     (every (lambda (spec) (nth-value 0 (config-check (second spec)
                                                      (if (eq (second spec) :ips) (third spec)
                                                          (if (eq (second spec) :bool) (if (third spec) "true" "false")
                                                              (format nil "~a" (third spec))))
                                                      (fourth spec) (fifth spec))))
            (config-schema)))

;;; ---- ページ送り・文字数 ----
(chk= "html-chars-len" (html-chars-len "a&amp;b&lt;") 4)
(chk= "ccut" (ccut "あ&amp;いう" 2) "あ&amp;")
(chk= "ip-unit IPv6" (ip-unit "2001:db8:85a3::8a2e:370:7334") "20010db885a30000")
(chk= "ip-unit IPv4" (ip-unit "192.168.0.1") "192.168.0.1")
(chk "ip-valid" (and (ip-valid-p "127.0.0.1") (ip-valid-p "::1") (not (ip-valid-p "999.1.1.1")) (not (ip-valid-p "example"))))

(format t "== OK ~d / NG ~d~%" *ok* *ng*)
(sb-ext:exit :code (if (plusp *ng*) 1 0))
