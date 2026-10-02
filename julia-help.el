;;; julia-help.el --- Julia documentation in a buffer of its own -*- lexical-binding: t; -*-

;; Copyright (C) 2026 LauraBMo

;; Author: LauraBMo
;; Maintainer: LauraBMo <laurea987@gmail.com>
;; URL: https://github.com/LauraBMo/julia-help.el
;; Version: 0.1.0
;; Keywords: docs, languages
;; Package-Requires: ((emacs "27.1"))
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The Emacs half of EmacsVterm.jl (https://github.com/wentasah/EmacsVterm.jl).
;;
;; A docstring arrives down a vterm escape as JSON: the HTML `Markdown.html'
;; produced, plus the metadata `REPL.doc' attaches to the `MD' -- the binding,
;; the module, and per method the signature, file and line.  Cross-references
;; become buttons that ask the REPL for the linked symbol's docs, and each
;; Methods row opens the file and line it names.
;;
;; Usage: `julia-repl--show' calls `julia-help-show' when Julia sends
;; `documentation' as `application/json', and `julia-help-mode' is where the
;; documentation arrives.  Requiring this file is enough.

;;; Code:

(require 'button)
(require 'json)
(require 'shr)

(declare-function julia-repl--show "julia-repl" (kind mime data))
(declare-function vterm-send-string "vterm" (string &optional now))

(defvar-local julia-help-follow-function nil
  "Function that fetches the documentation of a cross-reference target.
Called with one argument, the symbol the link points at.  Set by
`julia-help--linkify-refs' and read by `julia-help--follow-ref'; here it is
`julia-help--send'.

Buffer-local: two doc buffers open side by side may have come from different
REPLs.")

;; The rest of the per-buffer state, declared before anything reads it: a
;; `defvar' after its first use byte-compiles with a free-variable warning.

(defvar-local julia-help--payload nil
  "The decoded payload this buffer was last drawn from.")

(defvar-local julia-help--repl-buffer nil
  "The vterm buffer the documentation in this buffer arrived from.
Captured when the payload is displayed: `vterm--eval' runs with the vterm buffer
current, so that is where a cross-reference is sent back to.")

(defvar-local julia-help--back nil
  "Buffer this documentation was reached from, for `julia-help-back'.")

(defvar-local julia-help--forward nil
  "Buffer reached from this documentation, for `julia-help-forward'.")

(defvar julia-help--pending-back nil
  "Buffer a link was followed from; the next doc buffer links back to it.
A link sets this before it sends -- the buffer it is asking for does not exist
yet, since the payload that creates it arrives later through the vterm filter.")

(defun julia-help--ref-target (href text)
  "The Julia symbol an `@ref' link in a rendered docstring points at, else nil.
HREF is the link's `shr-url' property and TEXT the text it covers; nil leaves
shr to handle the link as before.

`Markdown.html' writes two shapes, both measured against `@doc sin' on 1.13:

  [text](@ref)      -> href \"@ref\"       the target is the link text
  [text](@ref sym)  -> href \"@ref sym\"   the target is written out

A signature link like ``[`sin(x)`](@ref)`` needs no special case: `@doc sin(x)'
resolves the method on its own.  The shapes are told apart exactly, not with a
bare `string-prefix-p', which would read \"@referenced\" as a cross-reference and
hand `@doc' the tail of it."
  (let* ((raw (cond ((equal href "@ref") text)
                    ((string-prefix-p "@ref " href) (substring href 5))))
         (target (and raw (string-trim raw))))
    (if (equal target "") nil target)))

(defun julia-help--follow-ref (button)
  "Button action: fetch the documentation of the symbol BUTTON points at.
The target rides on the button, read with `button-get'."
  (let ((target (button-get button 'julia-help-ref)))
    (unless julia-help-follow-function
      (error "No Julia doc sender here -- see `julia-help--linkify-refs'"))
    (setq julia-help--pending-back (current-buffer))
    (funcall julia-help-follow-function target)))

(defun julia-help--linkify-refs (follow)
  "Make every `@ref' link in the current buffer a button calling FOLLOW.
FOLLOW goes into `julia-help-follow-function'.  Call once, after
`shr-render-region'.

`make-text-button' supplies the `action' that shr's own links lack -- `push-button'
on one of those signals `void-function nil'.  And the `keymap' write takes the span
back from `shr-map', which `make-text-button' will not replace: without it the
button answers `push-button' while RET still runs `shr-browse-url' on the literal
\"@ref\".

shr's `face' is left alone, so a cross-reference looks as it did."
  (setq julia-help-follow-function follow)
  (let ((pos (point-min)))
    (while (< pos (point-max))
      (let ((url (get-text-property pos 'shr-url)))
        (if (null url)
            (setq pos (or (next-single-property-change pos 'shr-url)
                          (point-max)))
          (let* ((end (or (next-single-property-change pos 'shr-url)
                          (point-max)))
                 (target (julia-help--ref-target
                          url (buffer-substring-no-properties pos end))))
            (when target
              (make-text-button pos end
                                'julia-help-ref target
                                'action #'julia-help--follow-ref)
              (put-text-property pos end 'keymap button-map))
            (setq pos end)))))))

(defvar julia-help--link-keymap
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map shr-map)
    ;; Both shapes again -- see `julia-help-mode-map'.  shr binds only the
    ;; string form, so a real GUI TAB reaches the mode map through here anyway.
    (define-key map (kbd "TAB")       #'forward-button)
    (define-key map [tab]             #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map [S-tab]           #'backward-button)
    map)
  "Keymap for link text that stays shr's, taking the movement keys back.
`shr-render-region' puts `shr-map' on every link span, and a text-property
keymap outranks the major-mode one; `shr-map' binds TAB to `shr-next-link', so
TAB on such a link never reached `julia-help-mode-map'.  Everything else is
inherited, so RET still browses the URL.")

(defun julia-help--retarget-shr-links ()
  "Give TAB and S-TAB back on the link spans that stay shr's.
Cross-references are `julia-help--linkify-refs'' business, which replaces their
keymap outright; this catches the rest, where shr's keymap has to survive."
  (let ((pos (point-min)))
    (while (< pos (point-max))
      (let ((next (next-single-property-change pos 'keymap nil (point-max))))
        (when (eq (get-text-property pos 'keymap) shr-map)
          (put-text-property pos (or next (point-max))
                             'keymap julia-help--link-keymap))
        (setq pos (or next (point-max)))))))

(defface julia-help-heading
  '((t :inherit bold))
  "Face for the symbol and the section headings in a doc buffer.")

(defun julia-help--nonempty (value)
  "VALUE if it is a non-empty string, else nil.
A docstring fetched with `?help' rather than `@doc' reaches here with no
binding: Julia's help mode displays a different `MD' from the one `Docs.doc'
annotates, so `symbol', `binding', `module' and `typesig' all arrive as \"\".  An
empty string is *true* in elisp, so a guard of the shape (when field ...) would
print an empty heading rather than skipping it."
  (and (stringp value)
       (not (equal value ""))
       value))

(defvar julia-help-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")       #'push-button)
    ;; TAB and S-TAB arrive in two shapes that are not interchangeable: a GUI
    ;; TAB key delivers the vector `[tab]', while `(kbd "TAB")' is the string
    ;; "\t".  Bind both -- with only the string, `key-binding' reports the
    ;; binding while a real keypress runs whatever else claims `[tab]'.
    (define-key map (kbd "TAB")       #'forward-button)
    (define-key map [tab]             #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map [S-tab]           #'backward-button)
    (define-key map (kbd "n")         #'forward-button)
    (define-key map (kbd "p")         #'backward-button)
    (define-key map (kbd "h")         #'julia-help-back)
    (define-key map (kbd "l")         #'julia-help-forward)
    ;; `gr', never `g': under Evil these buffers open in normal state, where
    ;; `g' is a prefix, and a bare `g' here would swallow `gg' along with it.
    ;; A `g' prefix that does not bind `gg' falls through to Evil (measured),
    ;; so this costs nothing.  Without Evil it is an ordinary binding.
    (define-key map (kbd "gr")        #'julia-help-revert)
    map)
  "Keymap for `julia-help-mode', under `special-mode-map' for `q'.")

(define-derived-mode julia-help-mode special-mode "Julia-Help"
  "Major mode for Julia documentation, in the shape of a helpful buffer.

Cross-references are buttons: RET follows one, TAB and `n' / `p' walk them,
TAB being `forward-button' off a link as well as on one.  `h' and `l' return
to the documentation this one was reached from and came back from; `gr'
redraws.

Under Evil, these bindings only fire if the mode map is given precedence over
the normal state, which is where these buffers open:

  (with-eval-after-load \\='evil
    (evil-make-overriding-map julia-help-mode-map \\='normal))"
  ;; The methods table is aligned with `indent-to', and a tab there would make
  ;; the columns depend on `tab-width' rather than on column 44.
  (setq-local indent-tabs-mode nil))

(defun julia-help-revert ()
  "Draw this buffer again from the payload it was built from."
  (interactive)
  (unless julia-help--payload
    (user-error "This buffer has nothing to redraw"))
  (julia-help--render))

(defun julia-help--visit (buffer missing)
  "Show the documentation buffer BUFFER, or complain that there is none.
MISSING is the complaint.  Where the buffer is displayed is the display
policy's business: this asks for a plain `pop-to-buffer'."
  (if (buffer-live-p buffer)
      (pop-to-buffer buffer)
    (user-error "%s" missing)))

(defun julia-help-back ()
  "Go to the documentation this one was reached from."
  (interactive)
  (julia-help--visit julia-help--back "Nothing earlier to go back to"))

(defun julia-help-forward ()
  "Go to the documentation reached from this one."
  (interactive)
  (julia-help--visit julia-help--forward "Nothing later to go on to"))

(defun julia-help--open-source (button)
  "Button action: visit the file and line BUTTON names."
  (let ((file (button-get button 'julia-help-file))
        (line (button-get button 'julia-help-line)))
    (pop-to-buffer (find-file-noselect file))
    (goto-char (point-min))
    (forward-line (1- line))
    (recenter)))

(defun julia-help--insert-heading (text)
  "Insert TEXT as a section heading."
  (insert (propertize text 'face 'julia-help-heading) "\n"))

(defun julia-help--insert-header (payload)
  "Insert the heading block for PAYLOAD: what this documentation is about.
Inserts nothing at all when the payload names nothing (see
`julia-help--nonempty').  The blank separator goes in only when something was
written."
  (let ((binding (julia-help--nonempty (plist-get payload :binding)))
        (symbol (julia-help--nonempty (plist-get payload :symbol)))
        (module (julia-help--nonempty (plist-get payload :module)))
        ;; Union{} is what Julia reports for a binding with no methods -- a
        ;; constant, a macro -- and "Signature: Union{}" would be noise.
        (typesig (julia-help--nonempty (plist-get payload :typesig)))
        (wrote nil))
    (when (equal typesig "Union{}")
      (setq typesig nil))
    (when (or binding symbol)
      (julia-help--insert-heading (or binding symbol))
      (setq wrote t))
    (when module
      (insert (format "Defined in:  %s\n" module))
      (setq wrote t))
    (when typesig
      (insert (format "Signature:   %s\n" typesig))
      (setq wrote t))
    (when wrote
      (insert "\n"))))

(defun julia-help--insert-methods (results)
  "Insert a Methods section, one row per entry in RESULTS.
A row whose file is known becomes a button that visits it; a row without one
stays plain text."
  (when results
    (insert "\n")
    (julia-help--insert-heading (format "Methods (%d)" (length results)))
    (dolist (row results)
      (let ((beg (point))
            (file (plist-get row :file))
            (line (plist-get row :line)))
        (insert "  " (or (plist-get row :sig) "?"))
        (indent-to 44)
        (insert (format "%s:%s" (or (plist-get row :path) "?") (or line "?")))
        ;; The button is made before the newline, so it covers the row and not
        ;; the line break -- clicking anywhere on the row opens the file.
        (when file
          (make-text-button beg (point)
                            'julia-help-file file
                            'julia-help-line line
                            'action #'julia-help--open-source))
        (insert "\n")))))

(defun julia-help--render ()
  "Draw `julia-help--payload' into the current buffer."
  (let ((inhibit-read-only t)
        (payload julia-help--payload))
    (erase-buffer)
    (julia-help--insert-header payload)   ; brings its own separator
    (julia-help--insert-heading "Documentation")
    (let ((beg (point)))
      (insert (or (plist-get payload :html) ""))
      (shr-render-region beg (point))
      ;; Before the cross-references are linkified: this touches the links that
      ;; stay shr's, and `julia-help--linkify-refs' then overwrites the keymap
      ;; of the ones that do not.
      (julia-help--retarget-shr-links))
    (julia-help--insert-methods (plist-get payload :results))
    (julia-help--linkify-refs #'julia-help--send)
    (goto-char (point-min))))

(defun julia-help--buffer-name (payload)
  "The name of the buffer PAYLOAD belongs in.
One buffer per symbol, as helpful does.

Two kinds of payload have no symbol and get the plain name: the HTML-only one
an older EmacsVterm.jl sends, and the one `?help' produces, which arrives with
`symbol' present but empty.  That second case is why this asks
`julia-help--nonempty' rather than `if-let': with an empty string, naming the
buffer after it gives `*julia-help: *'."
  (if-let ((symbol (julia-help--nonempty (plist-get payload :symbol))))
      (format "*julia-help: %s*" symbol)
    "*julia-help*"))

(defun julia-help--send (target)
  "Ask the REPL this documentation came from to show TARGET's docs.
`@doc' takes a call expression as well as a name, so a cross-reference to
``sin(x)'' resolves the method on its own."
  (unless (buffer-live-p julia-help--repl-buffer)
    (user-error "The Julia REPL this documentation came from is gone"))
  (with-current-buffer julia-help--repl-buffer
    (vterm-send-string (concat "@doc " target "\n") t)))

(defun julia-help--display (payload repl-buffer)
  "Show PAYLOAD, the documentation a Julia REPL sent, in its own buffer.
REPL-BUFFER is that REPL, where cross-references are sent back to."
  (let* ((name (julia-help--buffer-name payload))
         (buffer (get-buffer-create name))
         (back julia-help--pending-back))
    (setq julia-help--pending-back nil)
    (with-current-buffer buffer
      (unless (derived-mode-p 'julia-help-mode)
        (julia-help-mode))
      (setq julia-help--payload payload
            julia-help--repl-buffer repl-buffer)
      (julia-help--render))
    ;; Wire the two buffers together, so `h' comes back and `l' goes on, and
    ;; only in the direction just travelled: following a link again from a
    ;; buffer already on the chain must not make it its own ancestor.
    (when (and (buffer-live-p back) (not (eq back buffer)))
      (with-current-buffer buffer (setq julia-help--back back))
      (with-current-buffer back (setq julia-help--forward buffer)))
    (pop-to-buffer buffer)
    buffer))

(defun julia-help-show (kind mime data)
  "Show documentation sent from Julia.
KIND is the sort of thing being sent, MIME how DATA is encoded, DATA a base64
string.  Called from `julia-repl--show' for `documentation' sent as
`application/json'."
  (cond
   ((and (equal kind "documentation") (equal mime "application/json"))
    (julia-help--display
     (json-parse-string (julia-help--decode data)
                        :object-type 'plist :array-type 'list)
     (current-buffer)))
   ((and (equal kind "documentation") (equal mime "text/html"))
    (julia-help--display
     (list :html (julia-help--decode data))
     (current-buffer)))
   ;; Anything else -- an image, say -- is left to julia-repl.
   ((fboundp 'julia-repl--show) (julia-repl--show kind mime data))
   (t (error "Unsupported data kind `%s' or MIME type `%s'" kind mime))))

(defun julia-help--decode (base64)
  "Decode BASE64, as UTF-8 text.
The payload is base64 all the way from Julia because `vterm--eval' splits the
escape sequence's arguments with `split-string-and-unquote', which would eat
the backslashes in raw JSON."
  (decode-coding-string (base64-decode-string base64) 'utf-8))

(provide 'julia-help)
;;; julia-help.el ends here
