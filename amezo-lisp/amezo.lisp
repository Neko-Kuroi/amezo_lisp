;;;; amezo.lisp - 起動スクリプト (sbcl --script amezo.lisp ...)
(load (merge-pathnames "load.lisp" (make-pathname :name nil :type nil :defaults (or *load-truename* *default-pathname-defaults*)))
      :verbose nil)

(handler-case
    (amezo:main sb-ext:*posix-argv*)
  (error (e)
    (format *error-output* "amezo: ~a~%" e)
    (sb-ext:exit :code 1)))
