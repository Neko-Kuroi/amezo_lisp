;;;; package.lisp - あめぞう風掲示板 (Common Lisp / SBCL 版)
(require :sb-posix)
(require :sb-bsd-sockets)

(defpackage :amezo
  (:use :cl)
  (:export :main :archive-main :make-hash :verify-hash))
(in-package :amezo)

(defvar *root-dir* nil "このプロジェクトのルート (amezo.lisp のあるフォルダ)。ローダが設定する。")

;;; 前方宣言: 読み込み順 (util -> crypto -> config) より後で定義されるものを先に宣言し、
;;; 初回コンパイル時の「undefined variable / function」警告を出さないためのもの。
(defvar *app-dir* nil "掲示板のルートディレクトリ (pathname)。起動時に決める。")
(defvar *hash-iterations*)  ; 値は config.lisp の defparameter で入る
(declaim (ftype (function (t) t) utf8))  ; 実体は crypto.lisp (文字列 -> octet vector)
