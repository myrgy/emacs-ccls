;;; -*- lexical-binding: t; -*-

;; Copyright (C) 2017 Tobias Pisani
;; Copyright (C) 2018 Fangrui Song

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and-or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Code:

(require 'cc-mode)
(require 'lsp-mode)
(require 'cl-lib)
(require 'subr-x)
(require 'dash)

;; ---------------------------------------------------------------------
;;   Customization
;; ---------------------------------------------------------------------

(defgroup ccls nil
  "Customization options for the ccls client"
  :group 'tools)

;; ---------------------------------------------------------------------
;;   Utility
;; ---------------------------------------------------------------------

(defun ccls--read-range (range)
  (cons (lsp--position-to-point (gethash "start" range))
        (lsp--position-to-point (gethash "end" range))))

(defsubst ccls--root-from-file (file)
  (-when-let (match (locate-dominating-file default-directory file))
    (expand-file-name match)))

(defsubst ccls--root-from-func (func)
  (and (fboundp func) (ignore-errors (funcall func))))

(cl-defun ccls--get-root ()
  "Return the root directory of a ccls project."
  (cl-loop for matcher in ccls-project-root-matchers do
           (-when-let (root (cl-typecase matcher
                              (string (ccls--root-from-file matcher))
                              (function  (ccls--root-from-func matcher))))
             (cl-return-from ccls--get-root root)))
  (user-error "Could not find ccls project root"))

(defun ccls--is-ccls-buffer (&optional buffer)
  "Return non-nil if current buffer is using the ccls client"
  (with-current-buffer (or buffer (current-buffer))
    (and lsp--cur-workspace
         (eq (lsp--client-get-root (lsp--workspace-client lsp--cur-workspace)) 'ccls--get-root))))

(define-inline ccls--ccls-buffer-check ()
  (inline-quote (cl-assert (ccls--is-ccls-buffer) nil
                           "ccls is not enabled in this buffer.")))

(defun ccls--get-renderer ()
  (thread-last lsp--cur-workspace
    lsp--workspace-client
    lsp--client-string-renderers
    (assoc-string (thread-first lsp--cur-workspace
                    lsp--workspace-client
                    lsp--client-language-id
                    (funcall (current-buffer))))
    cdr))

(defun ccls--render-string (str)
  (funcall (ccls--get-renderer) str))

(defun ccls--render-type (str)
  "Render a string as a type"
  (string-remove-suffix " a;" (ccls--render-string (format "%s a;" str))))

;; ---------------------------------------------------------------------
;;   Notification handlers
;; ---------------------------------------------------------------------

(defvar ccls--handlers
  '(("$ccls/progress" . (lambda (_w _p))))
  "List of cons-cells of (METHOD . HANDLER) pairs, where METHOD is the lsp method to handle,
and handler is a function invoked as (handler WORKSPACE PARAMS), where WORKSPACE is the current
lsp-workspace, and PARAMS is a hashmap of the params recieved with the notification.")

;; ---------------------------------------------------------------------
;;   Commands
;; ---------------------------------------------------------------------

(defun ccls--execute-command (command &optional arguments)
  "Execute a ccls command."
  (let* ((uri (car arguments))
         (data (cdr arguments)))
    (save-current-buffer
      (find-file (lsp--uri-to-path uri))
      (pcase command
        ;; Code actions
        ('"ccls._applyFixIt"
         (dolist (edit data)
           (ccls--apply-textedit (car edit))))
        ('"ccls._autoImplement"
         (dolist (edit data)
           (ccls--apply-textedit (car edit)))
         (goto-char (lsp--position-to-point
                     (gethash "start" (gethash "range" (caar data))))))
        ('"ccls._insertInclude"
         (ccls--select-textedit data "Include: "))
        ('"ccls.showReferences" ;; Used by code lenses
         (xref--show-xrefs (lsp--locations-to-xref-items (cadr data)) nil))
        (_
         (message "unknown command: %s" command))))))

(defun ccls--select-textedit (edit-list prompt)
  "Show a list of possible textedits, and apply the selected.
  Used by ccls._insertInclude"
  (let ((name-func (lambda (edit)
                     (concat (lsp--position-to-point
                              (gethash "start" (gethash "range" edit)))
                             ": "
                             (gethash "newText" edit)))))
    (ivy-read prompt
              (mapcar (lambda (edit)
                        (funcall name-func edit))
                      edit-list)
              :require-match t
              :action (lambda (str)
                        (cl-loop
                         for edit in edit-list
                         do (when (equal (funcall name-func edit) str)
                              (ccls--apply-textedit edit)))))))

(defun ccls--apply-textedit (edit)
  (let* ((range (gethash "range" edit))
         (start (lsp--position-to-point (gethash "start" range)))
         (end (lsp--position-to-point (gethash "end" range)))
         (newText (gethash "newText" edit)))
    (delete-region start end)
    (goto-char start)
    (insert newText)))

(defun ccls--execute-command-locally-advice (orig-func command args)
  "ccls currently doesn't support `workspace/executeCommand', so execute those locally."
  (if (ccls--is-ccls-buffer)
      (ccls--execute-command command args)
    (funcall orig-func args)))

(advice-add 'lsp--send-execute-command :around #'ccls--execute-command-locally-advice)

(provide 'ccls-common)
