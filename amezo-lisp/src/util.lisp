;;;; util.lisp - 文字列・ファイル・時刻・flock などの土台
(in-package :amezo)

;;; ---------- 文字列 ----------
(defun split-string (s delim &key (keep-empty t))
  "DELIM (文字) で分割する。Python の str.split(delim) に近い (空の要素も残す既定)。"
  (let ((out '()) (start 0) (n (length s)))
    (loop for i from 0 below n
          when (char= (char s i) delim)
            do (push (subseq s start i) out) (setf start (1+ i)))
    (push (subseq s start) out)
    (let ((res (nreverse out)))
      (if keep-empty res (remove "" res :test #'string=)))))

(defun split-once (s delim)
  "最初の DELIM で2つに分ける。無ければ (全体 NIL)。"
  (let ((p (position delim s)))
    (if p (values (subseq s 0 p) (subseq s (1+ p))) (values s nil))))

(defun join-strings (list &optional (sep ""))
  (with-output-to-string (out)
    (loop for (x . rest) on list do (princ x out) (when rest (princ sep out)))))

(defun replace-all (s old new)
  (if (or (zerop (length old)) (not (search old s)))
      s
      (with-output-to-string (out)
        (let ((pos 0))
          (loop for p = (search old s :start2 pos)
                while p
                do (write-string s out :start pos :end p)
                   (write-string new out)
                   (setf pos (+ p (length old))))
          (write-string s out :start pos)))))

(defun starts-with-p (prefix s) (and (>= (length s) (length prefix)) (string= prefix s :end2 (length prefix))))
(defun ends-with-p (suffix s) (and (>= (length s) (length suffix)) (string= suffix s :start2 (- (length s) (length suffix)))))

(defun trim-space (s) (string-trim '(#\Space #\Tab #\Newline #\Return #\u3000) s))

(defun digits-p (s &optional (min-len 1) max-len)
  (and (>= (length s) min-len) (or (null max-len) (<= (length s) max-len))
       (every #'digit-char-p s)))

(defun safe-integer (s &optional default)
  (handler-case (parse-integer s :junk-allowed nil) (error () default)))

(defun string-nth-field (s index delim)
  (let ((parts (split-string s delim))) (if (< index (length parts)) (nth index parts) "")))

;;; ---------- HTML ----------
(defun html-escape (s)
  (with-output-to-string (out)
    (loop for c across s
          do (case c
               (#\& (write-string "&amp;" out))
               (#\" (write-string "&quot;" out))
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\' (write-string "&#39;" out))
               (otherwise (write-char c out))))))

(defun html-unescape (s)
  (let ((r s))
    (setf r (replace-all r "&lt;" "<")
          r (replace-all r "&gt;" ">")
          r (replace-all r "&quot;" "\"")
          r (replace-all r "&#39;" "'")
          r (replace-all r "&amp;" "&"))
    r))

(defun strip-tags (s)
  "単純なタグ除去 (admin の題名の平文用)。< から > までを捨てる。"
  (with-output-to-string (out)
    (let ((in-tag nil))
      (loop for c across s
            do (cond ((char= c #\<) (setf in-tag t))
                     ((char= c #\>) (setf in-tag nil))
                     ((not in-tag) (write-char c out)))))))

(defparameter *entities* '("&amp;" "&quot;" "&lt;" "&gt;" "&#39;"))

(defun entity-at (s i)
  "位置 I から HTML エンティティが始まれば、その長さ。無ければ NIL。"
  (dolist (e *entities* nil)
    (when (and (<= (+ i (length e)) (length s)) (string= e s :start2 i :end2 (+ i (length e))))
      (return (length e)))))

(defun html-chars-len (s)
  "Python 版 html_chars_len: エンティティを1文字として数える。"
  (let ((n 0) (i 0) (len (length s)))
    (loop while (< i len)
          for e = (entity-at s i)
          do (if e (incf i e) (incf i)) (incf n))
    n))

(defun ccut (s max-len)
  "Python 版 ccut: エンティティを1文字として MAX-LEN 文字まで。"
  (let ((n 0) (i 0) (len (length s)))
    (loop while (and (< i len) (< n max-len))
          for e = (entity-at s i)
          do (if e (incf i e) (incf i)) (incf n))
    (subseq s 0 i)))

(defun strip-invisible (s)
  "Python 版 _INVISIBLE の文字を取り除く。"
  (with-output-to-string (out)
    (loop for c across s
          for code = (char-code c)
          unless (or (<= #x0080 code #x009F) (= code #x00AD) (= code #x034F) (= code #x061C)
                     (<= #x115F code #x1160) (<= #x17B4 code #x17B5)
                     (<= #x180B code #x180E) (= code #x200B) (= code #x200C)
                     (<= #x200E code #x200F) (<= #x2028 code #x202E)
                     (<= #x2060 code #x206F) (= code #x3164) (= code #xFEFF)
                     (= code #xFFA0) (<= #xFFF9 code #xFFFB))
            do (write-char c out))))

;;; ---------- URL ----------
(defun utf8-decode (octs)
  "octet vector -> 文字列。UTF-8 として解釈し、壊れた部分は置換文字 (U+FFFD) にする。"
  (with-output-to-string (out)
    (let ((n (length octs)) (i 0))
      (loop while (< i n)
            for b = (aref octs i)
            do (cond ((< b #x80) (write-char (code-char b) out) (incf i))
                     ((and (<= #xC2 b #xDF) (< (1+ i) n) (<= #x80 (aref octs (1+ i)) #xBF))
                      (write-char (code-char (logior (ash (logand b #x1F) 6) (logand (aref octs (1+ i)) #x3F))) out)
                      (incf i 2))
                     ((and (<= #xE0 b #xEF) (< (+ i 2) n)
                           (<= #x80 (aref octs (1+ i)) #xBF) (<= #x80 (aref octs (+ i 2)) #xBF)
                           (let ((cp (logior (ash (logand b #x0F) 12) (ash (logand (aref octs (1+ i)) #x3F) 6)
                                             (logand (aref octs (+ i 2)) #x3F))))
                             (and (>= cp (case b (#xE0 #x800) (#xED #xD800) (otherwise #x800)))
                                  (not (<= #xD800 cp #xDFFF)))))
                      (write-char (code-char (logior (ash (logand b #x0F) 12) (ash (logand (aref octs (1+ i)) #x3F) 6)
                                                     (logand (aref octs (+ i 2)) #x3F))) out)
                      (incf i 3))
                     ((and (<= #xF0 b #xF4) (< (+ i 3) n)
                           (<= #x80 (aref octs (1+ i)) #xBF) (<= #x80 (aref octs (+ i 2)) #xBF) (<= #x80 (aref octs (+ i 3)) #xBF)
                           (let ((cp (logior (ash (logand b #x07) 18) (ash (logand (aref octs (1+ i)) #x3F) 12)
                                             (ash (logand (aref octs (+ i 2)) #x3F) 6) (logand (aref octs (+ i 3)) #x3F))))
                             (and (<= (case b (#xF0 #x10000) (#xF4 #x100000) (otherwise #x10000)) cp #x10FFFF))))
                      (write-char (code-char (logior (ash (logand b #x07) 18) (ash (logand (aref octs (1+ i)) #x3F) 12)
                                                     (ash (logand (aref octs (+ i 2)) #x3F) 6) (logand (aref octs (+ i 3)) #x3F))) out)
                      (incf i 4))
                     (t (write-char #\Replacement_Character out) (incf i)))))))

(defun url-decode (x)
  "URL エンコードされた文字列/バイト列を、+ を空白として、UTF-8 で戻す (Python 版 url_decode)。"
  (let* ((bytes (etypecase x
                  (string (sb-ext:string-to-octets x :external-format :iso-8859-1))
                  (vector x)))
         (out (make-array (length bytes) :element-type '(unsigned-byte 8) :fill-pointer 0)))
    (loop for i from 0 below (length bytes)
          for b = (aref bytes i)
          do (cond ((= b (char-code #\+)) (vector-push (char-code #\Space) out))
                   ((and (= b (char-code #\%)) (<= (+ i 2) (1- (length bytes)))
                         (digit-char-p (code-char (aref bytes (1+ i))) 16)
                         (digit-char-p (code-char (aref bytes (+ i 2))) 16))
                    (vector-push (parse-integer (map 'string #'code-char
                                                     (list (aref bytes (1+ i)) (aref bytes (+ i 2))))
                                                :radix 16)
                                 out)
                    (incf i 2))
                   (t (vector-push b out))))
    (utf8-decode (coerce out '(vector (unsigned-byte 8))))))

(defun url-encode (s)
  "Python の urllib.parse.quote(s, safe='') 相当。"
  (with-output-to-string (out)
    (loop for b across (utf8 s)
          for c = (code-char b)
          do (if (or (alphanumericp c) (find c "-._~"))
                 (write-char c out)
                 (format out "%~2,'0X" b)))))

;;; ---------- 時刻 (JST 固定。Python 版と同じく OS の TZ に頼らない) ----------
(defun epoch-now () (nth-value 0 (sb-ext:get-time-of-day)))

(defun civil-from-days (z)
  "Howard Hinnant の civil_from_days。1970-01-01 からの日数 -> (年 月 日)。"
  (let* ((z (+ z 719468))
         (era (floor z 146097))
         (doe (- z (* era 146097)))
         (yoe (floor (+ doe (- (floor doe 1460)) (floor doe 36524) (- (floor doe 146096))) 365))
         (y (+ yoe (* era 400)))
         (doy (- doe (+ (* 365 yoe) (floor yoe 4) (- (floor yoe 100)))))
         (mp (floor (+ (* 5 doy) 2) 153))
         (d (+ (- doy (floor (+ (* 153 mp) 2) 5)) 1))
         (m (+ mp (if (< mp 10) 3 -9))))
    (values (if (<= m 2) (1+ y) y) m d)))

(defun epoch->jst (epoch)
  "エポック秒 -> (values 年 月 日 時 分 秒 曜日) 曜日は月曜=0 (Python の weekday())。JST で計算。"
  (let* ((tt (+ epoch 32400))
         (days (floor tt 86400))
         (secs (- tt (* days 86400))))
    (multiple-value-bind (y m d) (civil-from-days days)
      (values y m d (floor secs 3600) (floor (mod secs 3600) 60) (mod secs 60)
              (mod (+ days 3) 7)))))

(defun jst->epoch (year month day hour min sec)
  "JST の日時 -> エポック秒 (admin の日時戻し用)。範囲外は NIL。"
  (handler-case
      (let* ((y (if (<= month 2) (1- year) year))
             (era (floor y 400))
             (yoe (- y (* era 400)))
             (mp (mod (+ month (if (> month 2) -3 9)) 12))
             (doy (+ (floor (+ (* 153 mp) 2) 5) (1- day)))
             (doe (+ (* yoe 365) (floor yoe 4) (- (floor yoe 100)) doy))
             (days (+ (* era 146097) doe -719468)))
        (- (+ (* days 86400) (* hour 3600) (* min 60) sec) 32400))
    (error () nil)))

(defparameter *wdays* #("月" "火" "水" "木" "金" "土" "日"))

(defun format-jst-date (epoch)
  "Python 版 date_str: 20yy年mm月dd日(曜)HH時MM分SS秒"
  (multiple-value-bind (y m d hh mm ss wd) (epoch->jst epoch)
    (format nil "~d年~2,'0d月~2,'0d日(~a)~2,'0d時~2,'0d分~2,'0d秒"
            y m d (aref *wdays* wd) hh mm ss)))

(defun format-res-number (epoch)
  "スレッド番号: yyMMddHHmmss (JST)"
  (multiple-value-bind (y m d hh mm ss) (epoch->jst epoch)
    (declare (ignore ss))
    (format nil "~2,'0d~2,'0d~2,'0d~2,'0d~2,'0d~2,'0d"
            (mod y 100) m d hh mm (nth-value 5 (epoch->jst epoch)))))

(defun format-admin-time (epoch)
  (multiple-value-bind (y m d hh mm) (epoch->jst epoch)
    (format nil "~d-~2,'0d-~2,'0d ~2,'0d:~2,'0d" y m d hh mm)))

;;; ---------- ファイル ----------
(defun app-path (&rest parts)
  "掲示板フォルダ (*app-dir*) からの相対パスを pathname にする。部品は文字列か pathname。"
  (let ((base (namestring *app-dir*)))
    (unless (ends-with-p "/" base) (setf base (format nil "~a/" base)))
    (pathname
     (with-output-to-string (out)
       (write-string base out)
       (loop for (part . rest) on parts
             do (write-string (if (pathnamep part) (namestring part) part) out)
                (when rest (write-char #\/ out)))))))

(defun path-string (&rest parts) (namestring (apply #'app-path parts)))

(defun file-regular-p (path)
  (handler-case (and (probe-file path) (not (sb-posix:s-isdir (sb-posix:stat-mode (sb-posix:stat (namestring path))))))
    (error () nil)))

(defun dir-exists-p (path) (handler-case (sb-posix:s-isdir (sb-posix:stat-mode (sb-posix:stat (namestring path)))) (error () nil)))

(defun ensure-dir (path)
  "ディレクトリを作る (既にあれば何もしない)。親までは作らない。"
  (handler-case (sb-posix:mkdir (namestring path) #o755) (error () nil))
  (dir-exists-p path))

(defun file-size-of (path) (handler-case (sb-posix:stat-size (sb-posix:stat (namestring path))) (error () nil)))
(defun file-mtime-of (path) (handler-case (sb-posix:stat-mtime (sb-posix:stat (namestring path))) (error () nil)))
(defun file-ctime-of (path) (handler-case (sb-posix:stat-ctime (sb-posix:stat (namestring path))) (error () nil)))
(defun file-nlink-of-fd (fd) (handler-case (sb-posix:stat-nlink (sb-posix:fstat fd)) (error () 1)))

(defun chmod-file (path mode) (handler-case (sb-posix:chmod (namestring path) mode) (error () nil)))

(defun set-file-mtime (path epoch)
  "更新日時 (とアクセス日時) をエポック秒に設定する。GNU touch -d @EPOCH を使う。"
  (handler-case
      (let ((proc (sb-ext:run-program "touch" (list "-d" (format nil "@~d" epoch) (namestring path))
                                      :search t :wait t :output nil :error nil)))
        (and proc (zerop (sb-ext:process-exit-code proc))))
    (error () nil)))

(defun rename-path (from to) (handler-case (progn (sb-posix:rename (namestring from) (namestring to)) t) (error () nil)))
(defun unlink-path (path) (handler-case (progn (delete-file path) t) (error () nil)))

(defun list-dir-names (path)
  "ディレクトリ内の名前 (文字列) の一覧。無ければ NIL。"
  (handler-case
      (let ((names '())
            (dir (let ((s (namestring path))) (if (ends-with-p "/" s) path (pathname (format nil "~a/" s))))))
        (dolist (p (directory (merge-pathnames (make-pathname :name :wild :type :wild) dir) :resolve-symlinks nil))
          (push (if (pathname-name p)
                    (if (pathname-type p) (format nil "~a.~a" (pathname-name p) (pathname-type p)) (pathname-name p))
                    (car (last (pathname-directory p))))
                names))
        names)
    (error () nil)))

(defun read-file-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence v in) v)))

(defun read-file-string (path &optional (default nil))
  "UTF-8 で読む。失敗したら DEFAULT。"
  (handler-case (utf8-decode (read-file-octets path)) (error () default)))

(defun read-file-lines (path &optional (default nil))
  "行の一覧 (改行と末尾の CR を除く)。失敗したら DEFAULT。"
  (let ((s (read-file-string path)))
    (if (null s)
        default
        (let ((lines (split-string s #\Newline)))
          ;; 末尾が改行で終わる場合の空要素を落とす
          (when (and lines (string= "" (car (last lines)))) (setf lines (butlast lines)))
          (mapcar (lambda (l) (string-right-trim '(#\Return) l)) lines)))))

(defun write-file-string (path content &key (mode nil))
  (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create
                            :external-format '(:utf-8 :eol-style :lf))
    (write-string content out))
  (when mode (chmod-file path mode))
  t)

(defun write-file-octets (path octs)
  (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create
                            :element-type '(unsigned-byte 8))
    (write-sequence octs out))
  t)

(defun append-file-string (path content)
  (with-open-file (out path :direction :output :if-exists :append :if-does-not-exist :create
                            :external-format '(:utf-8 :eol-style :lf))
    (write-string content out))
  t)

(defun write-file-atomic (path content &key (mode #o644))
  "一時ファイルに書いて rename する (Python 版の os.replace 相当)。既存ファイルのモードを保つ。"
  (let* ((tmp (format nil "~a.tmp~d" (namestring path) (sb-posix:getpid)))
         (old-mode (handler-case (logand (sb-posix:stat-mode (sb-posix:stat (namestring path))) #o7777) (error () nil))))
    (handler-case
        (progn (write-file-string tmp content)
               (chmod-file tmp (or old-mode mode))
               (sb-posix:rename tmp (namestring path))
               t)
      (error () (ignore-errors (delete-file tmp)) nil))))

;;; ---------- flock (libc) ----------
(sb-alien:define-alien-routine ("flock" c-flock) sb-alien:int (fd sb-alien:int) (operation sb-alien:int))
(defconstant +lock-ex+ 2)
(defconstant +lock-nb+ 4)
(defconstant +lock-un+ 8)

(defun fd-open (path &key (flags (logior sb-posix:o-rdwr sb-posix:o-creat)) (mode #o644))
  (handler-case (sb-posix:open (namestring path) flags mode) (error () nil)))

(defun fd-close (fd) (when fd (ignore-errors (sb-posix:close fd))))

(defun fd-lock (fd &key nonblocking)
  (and fd (zerop (c-flock fd (logior +lock-ex+ (if nonblocking +lock-nb+ 0))))))

(defun fd-unlock (fd) (when fd (c-flock fd +lock-un+)))

(defun call-with-fd-lock (path fn &key (timeout 0) create-mode)
  "PATH を flock して FN(fd) を呼ぶ。TIMEOUT 秒まで NB で再試行する。取れなければ :busy。
   CREATE-MODE があれば、そのモードでファイルを作る (無ければ 0644)。"
  (let ((fd (fd-open path :mode (or create-mode #o644))))
    (if (null fd)
        :busy
        (unwind-protect
             (let ((deadline (+ (epoch-now) timeout)) (got nil))
               (loop do (setf got (fd-lock fd :nonblocking t))
                     until (or got (<= deadline (epoch-now)))
                     do (sleep 0.1))
               (if got (funcall fn fd) :busy))
          (fd-unlock fd) (fd-close fd)))))

(defun call-with-file-lock (path fn &key (timeout 0))
  "PATH 自体ではなく PATH.lock のような専用ロックでも、対象ファイルそのものでも使える一般形。"
  (call-with-fd-lock path fn :timeout timeout))

;;; ---------- IP ----------
(defun ipv4-valid-p (s)
  (let ((parts (split-string s #\.)))
    (and (= (length parts) 4)
         (every (lambda (p)
                  (and (digits-p p 1 3)
                       (or (= (length p) 1) (char/= (char p 0) #\0))
                       (<= (parse-integer p) 255)))
                parts))))

(defun ipv6-groups (s)
  "IPv6 文字列を 8 グループ (16bit 値のリスト) に展開する。壊れていれば NIL。末尾の IPv4 表記にも対応。"
  (handler-case
      (let ((str s))
        ;; 末尾の IPv4 を 2 グループに直す
        (let ((last-colon (position #\: str :from-end t)))
          (when (and last-colon (find #\. str))
            (let ((v4 (subseq str (1+ last-colon))))
              (when (ipv4-valid-p v4)
                (let ((p (mapcar #'parse-integer (split-string v4 #\.))))
                  (setf str (format nil "~a~x:~x" (subseq str 0 (1+ last-colon))
                                    (+ (* (first p) 256) (second p))
                                    (+ (* (third p) 256) (fourth p)))))))))
        (let ((halves (split-string str #\: :keep-empty t)))
          ;; '::' の検出: 空要素
          (cond
            ((search "::" str)
             (let* ((dbl (search "::" str))
                    (left (if (zerop dbl) '() (split-string (subseq str 0 dbl) #\:)))
                    (right-str (subseq str (+ dbl 2)))
                    (right (if (zerop (length right-str)) '() (split-string right-str #\:)))
                    (zeros (make-list (- 8 (length left) (length right)) :initial-element 0)))
               (when (and (<= (+ (length left) (length right)) 7)
                          (every (lambda (g) (and (<= 1 (length g) 4) (every (lambda (c) (digit-char-p c 16)) g)))
                                 (append left right)))
                 (mapcar (lambda (g) (if (integerp g) g (parse-integer g :radix 16))) (append left zeros right)))))
            (t (let ((gs (split-string str #\:)))
                 (when (and (= (length gs) 8)
                            (every (lambda (g) (and (<= 1 (length g) 4) (every (lambda (c) (digit-char-p c 16)) g))) gs))
                   (mapcar (lambda (g) (parse-integer g :radix 16)) gs)))))))
    (error () nil)))

(defun ip-valid-p (s)
  (and s (or (ipv4-valid-p s) (and (find #\: s) (ipv6-groups s) t))))

(defun ip-unit (ip)
  "Python 版 ip_unit: IPv6 は上位64bit の hex、IPv4 はそのまま。"
  (if (and ip (find #\: ip))
      (let ((gs (ipv6-groups ip)))
        (if gs
            (string-downcase (format nil "~{~4,'0x~}" (subseq gs 0 4)))
            ip))
      ip))

;;; ---------- その他 ----------
(defun getenv* (name &optional (default ""))
  (or (sb-posix:getenv name) default))

(defun copy-file-simple (from to)
  (write-file-octets to (read-file-octets from)))
