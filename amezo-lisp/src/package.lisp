;;;; package.lisp - あめぞう風掲示板 (Common Lisp / SBCL 版)
(require :sb-posix)
(require :sb-bsd-sockets)

(defpackage :amezo
  (:use :cl)
  (:export :main :archive-main :make-hash :verify-hash))
(in-package :amezo)

(defvar *root-dir* nil "このプロジェクトのルート (amezo.lisp のあるフォルダ)。ローダが設定する。")
