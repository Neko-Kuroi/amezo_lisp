;;;; crypto.lisp - SHA-256 / HMAC / PBKDF2 / base64 / base32 (自前実装、外部依存なし)
;;;; Python 版 (hashlib / hmac / base64) と結果が一致するように作ってある。
(in-package :amezo)

;;; ---------- 汎用 ----------
(defun u32 (x) (ldb (byte 32 0) x))
(defun rotr32 (x n) (u32 (logior (ash x (- n)) (ash x (- 32 n)))))

(defun octets (&rest bytes) (make-array (length bytes) :element-type '(unsigned-byte 8) :initial-contents bytes))

(defun utf8 (s) (sb-ext:string-to-octets s :external-format :utf-8))

(defun hex-encode (octs)
  (let ((digits "0123456789abcdef"))
    (with-output-to-string (out)
      (loop for b across octs
            do (write-char (char digits (ash b -4)) out)
               (write-char (char digits (logand b 15)) out)))))

(defun hex-decode (s)
  "16進文字列 -> octet vector。壊れていれば NIL。"
  (when (and (evenp (length s))
             (every (lambda (c) (digit-char-p c 16)) s))
    (let ((v (make-array (/ (length s) 2) :element-type '(unsigned-byte 8))))
      (loop for i from 0 below (length s) by 2
            for j from 0
            do (setf (aref v j) (parse-integer s :start i :end (+ i 2) :radix 16)))
      v)))

(defun random-octets (n)
  (let ((v (make-array n :element-type '(unsigned-byte 8))))
    (with-open-file (in "/dev/urandom" :element-type '(unsigned-byte 8))
      (read-sequence v in))
    v))

(defun constant-time-equal (a b)
  (if (/= (length a) (length b))
      nil
      (let ((d 0))
        (loop for x across a for y across b do (setf d (logior d (logxor x y))))
        (zerop d))))

(defun constant-time-string-equal (a b)
  (constant-time-equal (utf8 (or a "")) (utf8 (or b ""))))

;;; ---------- SHA-256 ----------
(defvar *sha256-k*
  #(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1 #x923f82a4 #xab1c5ed5
    #xd807aa98 #x12835b01 #x243185be #x550c7dc3 #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174
    #xe49b69c1 #xefbe4786 #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
    #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147 #x06ca6351 #x14292967
    #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13 #x650a7354 #x766a0abb #x81c2c92e #x92722c85
    #xa2bfe8a1 #xa81a664b #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
    #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a #x5b9cca4f #x682e6ff3
    #x748f82ee #x78a5636f #x84c87814 #x8cc70208 #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

(defstruct (sha256 (:constructor %make-sha256))
  (h (make-array 8 :element-type '(unsigned-byte 32)
                   :initial-contents '(#x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
                                       #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19)))
  (buf (make-array 64 :element-type '(unsigned-byte 8) :initial-element 0))
  (buf-len 0 :type fixnum)
  (total 0 :type fixnum))

(defun sha256-compress (state block offset)
  (declare (type (simple-array (unsigned-byte 32) (8)) state)
           (type (simple-array (unsigned-byte 8) (*)) block)
           (type fixnum offset)
           (optimize (speed 3) (safety 1)))
  (let ((w (make-array 64 :element-type '(unsigned-byte 32))))
    (declare (type (simple-array (unsigned-byte 32) (64)) w))
    (loop for i from 0 below 16
          for j = (+ offset (* i 4))
          do (setf (aref w i)
                   (logior (ash (aref block j) 24) (ash (aref block (+ j 1)) 16)
                           (ash (aref block (+ j 2)) 8) (aref block (+ j 3)))))
    (loop for i from 16 below 64
          for s0 = (logxor (rotr32 (aref w (- i 15)) 7) (rotr32 (aref w (- i 15)) 18)
                           (ash (aref w (- i 15)) -3))
          for s1 = (logxor (rotr32 (aref w (- i 2)) 17) (rotr32 (aref w (- i 2)) 19)
                           (ash (aref w (- i 2)) -10))
          do (setf (aref w i) (u32 (+ (aref w (- i 16)) s0 (aref w (- i 7)) s1))))
    (let ((a (aref state 0)) (b (aref state 1)) (c (aref state 2)) (d (aref state 3))
          (e (aref state 4)) (f (aref state 5)) (g (aref state 6)) (h (aref state 7)))
      (declare (type (unsigned-byte 32) a b c d e f g h))
      (loop for i from 0 below 64
            for s1 = (logxor (rotr32 e 6) (rotr32 e 11) (rotr32 e 25))
            for ch = (logxor (logand e f) (logand (lognot e) g))
            for t1 = (u32 (+ h s1 ch (aref *sha256-k* i) (aref w i)))
            for s0 = (logxor (rotr32 a 2) (rotr32 a 13) (rotr32 a 22))
            for maj = (logxor (logand a b) (logand a c) (logand b c))
            for t2 = (u32 (+ s0 maj))
            do (setf h g g f f e e (u32 (+ d t1)) d c c b b a a (u32 (+ t1 t2))))
      (setf (aref state 0) (u32 (+ (aref state 0) a))
            (aref state 1) (u32 (+ (aref state 1) b))
            (aref state 2) (u32 (+ (aref state 2) c))
            (aref state 3) (u32 (+ (aref state 3) d))
            (aref state 4) (u32 (+ (aref state 4) e))
            (aref state 5) (u32 (+ (aref state 5) f))
            (aref state 6) (u32 (+ (aref state 6) g))
            (aref state 7) (u32 (+ (aref state 7) h)))))
  state)

(defun sha256-update (ctx octs &optional (start 0) (end (length octs)))
  (let* ((len (- end start))
         (buf (sha256-buf ctx))
         (bl (sha256-buf-len ctx)))
    (incf (sha256-total ctx) len)
    (let ((i start))
      ;; 既存の端数と合わせて 64 バイトになれば圧縮
      (when (and (plusp bl) (< bl 64))
        (let ((take (min (- 64 bl) len)))
          (replace buf octs :start1 bl :start2 i :end2 (+ i take))
          (incf i take) (incf bl take)
          (when (= bl 64)
            (sha256-compress (sha256-h ctx) buf 0)
            (setf bl 0))))
      ;; 本体を直接圧縮
      (loop while (<= (+ i 64) end)
            do (sha256-compress (sha256-h ctx) octs i)
               (incf i 64))
      ;; 端数
      (let ((rem (- end i)))
        (when (plusp rem)
          (replace buf octs :start1 0 :start2 i :end2 end)
          (setf bl rem)))
      (setf (sha256-buf-len ctx) bl)))
  ctx)

(defun sha256-final (ctx)
  (let ((bitlen (* (sha256-total ctx) 8))
        (buf (sha256-buf ctx))
        (bl (sha256-buf-len ctx)))
    ;; パディング: 0x80, 0..., 長さ(64bit BE)。total は変わってしまうので先に取ってある
    (let ((pad (make-array 72 :element-type '(unsigned-byte 8) :initial-element 0)))
      (setf (aref pad 0) #x80)
      (let ((padlen (if (< bl 56) (- 56 bl) (- 120 bl))))
        ;; padlen バイト (0x80 を含む) + 8 バイト長
        (loop for i from (- 8 1) downto 0
              for j from 0
              do (setf (aref pad (+ padlen j)) (ldb (byte 8 (* i 8)) bitlen)))
        ;; sha256-update は total を増やすが、ここではもう使わない
        (sha256-update ctx pad 0 (+ padlen 8))))
    (let ((out (make-array 32 :element-type '(unsigned-byte 8))))
      (loop for i from 0 below 8
            for v = (aref (sha256-h ctx) i)
            do (loop for j from 0 below 4
                     do (setf (aref out (+ (* i 4) j)) (ldb (byte 8 (* (- 3 j) 8)) v))))
      out)))

(defun sha256-octets (octs)
  (let ((ctx (%make-sha256)))
    (sha256-update ctx octs)
    (sha256-final ctx)))

(defun sha256-hex (octs) (hex-encode (sha256-octets octs)))

(defun sha256-file (path)
  "ファイルの SHA-256 を [hex 長さ] で返す。読めなければ NIL (archive 用)。"
  (handler-case
      (let ((ctx (%make-sha256)) (n 0)
            (buf (make-array 65536 :element-type '(unsigned-byte 8))))
        (with-open-file (in path :element-type '(unsigned-byte 8))
          (loop for c = (read-sequence buf in)
                while (plusp c)
                do (sha256-update ctx buf 0 c) (incf n c)))
        (values (hex-encode (sha256-final ctx)) n))
    (error () (values nil nil))))

;;; ---------- HMAC-SHA256 ----------
(defun hmac-sha256 (key msg)
  (let ((k (if (> (length key) 64) (sha256-octets key) key)))
    (let ((kp (make-array 64 :element-type '(unsigned-byte 8) :initial-element 0)))
      (replace kp k)
      (let ((inner (make-array (+ 64 (length msg)) :element-type '(unsigned-byte 8)))
            (outer (make-array (+ 64 32) :element-type '(unsigned-byte 8))))
        (loop for i from 0 below 64 do (setf (aref inner i) (logxor (aref kp i) #x36)))
        (replace inner msg :start1 64)
        (let ((ih (sha256-octets inner)))
          (loop for i from 0 below 64 do (setf (aref outer i) (logxor (aref kp i) #x5c)))
          (replace outer ih :start1 64)
          (sha256-octets outer))))))

(defun hmac-sha256-hex (key msg) (hex-encode (hmac-sha256 key msg)))

;;; ---------- PBKDF2-HMAC-SHA256 (Python の hashlib.pbkdf2_hmac と同じ) ----------
(defun pbkdf2-sha256 (password salt iterations dklen)
  (let ((out (make-array dklen :element-type '(unsigned-byte 8)))
        (pos 0)
        (block-index 1))
    (loop while (< pos dklen)
          do (let* ((msg (make-array (+ (length salt) 4) :element-type '(unsigned-byte 8))))
               (replace msg salt)
               (loop for j from 0 below 4
                     do (setf (aref msg (+ (length salt) j))
                              (ldb (byte 8 (* (- 3 j) 8)) block-index)))
               (let* ((u (hmac-sha256 password msg))
                      (acc (copy-seq u)))
                 (loop repeat (1- iterations)
                       do (setf u (hmac-sha256 password u))
                          (loop for i from 0 below 32
                                do (setf (aref acc i) (logxor (aref acc i) (aref u i)))))
                 (let ((take (min 32 (- dklen pos))))
                   (replace out acc :start1 pos :end2 take)
                   (incf pos take)
                   (incf block-index)))))
    out))

;;; ---------- パスワードハッシュ (pbkdf2_sha256$回数$salt.hex$hash.hex) ----------
(defparameter *hash-scheme* "pbkdf2_sha256")

(defun make-hash (password &key (iterations *hash-iterations*) salt)
  (let* ((salt (or salt (random-octets 16)))
         (dk (pbkdf2-sha256 (utf8 password) salt iterations 32)))
    (format nil "~a$~d$~a$~a" *hash-scheme* iterations (hex-encode salt) (hex-encode dk))))

(defun verify-hash (password stored)
  (handler-case
      (let* ((parts (split-string (string-trim '(#\Space #\Tab #\Newline #\Return) (or stored "")) #\$))
             )
        (when (and (= (length parts) 4) (string= (first parts) *hash-scheme*))
          (let ((iters (parse-integer (second parts) :junk-allowed t))
                (salt (hex-decode (third parts)))
                (expected (hex-decode (fourth parts))))
            (when (and iters (<= 1 iters 5000000) salt expected)
              (constant-time-equal (pbkdf2-sha256 (utf8 password) salt iters 32) expected)))))
    (error () nil)))

;;; ---------- base64 / base64url / base32 ----------
(defparameter *b64-alphabet* "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
(defparameter *b64url-alphabet* "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
(defparameter *b32-alphabet* "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

(defun base64-encode (octs &key (alphabet *b64-alphabet*) (padding t))
  (with-output-to-string (out)
    (let ((n (length octs)) (i 0))
      (loop while (< i n)
            for b0 = (aref octs i)
            for b1 = (if (< (+ i 1) n) (aref octs (+ i 1)) 0)
            for b2 = (if (< (+ i 2) n) (aref octs (+ i 2)) 0)
            for v = (logior (ash b0 16) (ash b1 8) b2)
            do (write-char (char alphabet (ldb (byte 6 18) v)) out)
               (write-char (char alphabet (ldb (byte 6 12) v)) out)
               (if (< (+ i 1) n)
                   (write-char (char alphabet (ldb (byte 6 6) v)) out)
                   (when padding (write-char #\= out)))
               (if (< (+ i 2) n)
                   (write-char (char alphabet (ldb (byte 6 0) v)) out)
                   (when padding (write-char #\= out)))
               (incf i 3)))))

(defun b64url-encode (octs) (base64-encode octs :alphabet *b64url-alphabet* :padding nil))

(defun b64url-decode (s)
  "base64url 文字列 -> octet vector。文字種が違う・形が壊れていれば NIL (Python 版と同じ)。"
  (when (and s (plusp (length s))
             (every (lambda (c) (or (alphanumericp c) (char= c #\-) (char= c #\_))) s))
    (handler-case
        (let* ((pad (mod (- (length s)) 4))
               (full (concatenate 'string s (make-string pad :initial-element #\=)))
               (out (make-array (* 3 (/ (length full) 4)) :element-type '(unsigned-byte 8)))
               (pos 0))
          (loop for i from 0 below (length full) by 4
                for vals = (loop for j from 0 below 4
                                 for c = (char full (+ i j))
                                 collect (if (char= c #\=) 0
                                             (position c *b64url-alphabet*)))
                for v = (reduce (lambda (a b) (+ (* a 64) b)) vals)
                do (setf (aref out pos) (ldb (byte 8 16) v)) (incf pos)
                   (unless (char= (char full (+ i 2)) #\=)
                     (setf (aref out pos) (ldb (byte 8 8) v)) (incf pos))
                   (unless (char= (char full (+ i 3)) #\=)
                     (setf (aref out pos) (ldb (byte 8 0) v)) (incf pos)))
          (subseq out 0 pos))
      (error () nil))))

(defun base32-encode (octs)
  "パディングなしの base32 (Python の base64.b32encode から '=' を除いたもの)。"
  (with-output-to-string (out)
    (let ((n (length octs)) (i 0))
      (loop while (< i n)
            for take = (min 5 (- n i))
            for v = (let ((x 0))
                      (loop for j from 0 below 5
                            do (setf x (+ (* x 256)
                                          (if (< j take) (aref octs (+ i j)) 0))))
                      x)
            for chars = (ceiling (* take 8) 5)
            do (loop for j from 0 below chars
                     for shift = (* (- 7 j) 5)
                     do (write-char (char *b32-alphabet* (ldb (byte 5 shift) v)) out))
               (incf i 5)))))
