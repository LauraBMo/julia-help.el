;;; julia-help-test.el --- tests for julia-help.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 LauraBMo

;; Author: LauraBMo
;; Version: 0.1.0
;; Keywords: docs, languages
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT suite for julia-help.el.  Run it with:
;;
;;   emacs -Q --batch -L . -l julia-help-test.el
;;
;; Exit code is the verdict.  The file runs the suite itself when loaded in
;; batch, so a load that tested nothing cannot be read as a pass.

;; WHAT IT CHECKS
;;
;;   1. `julia-help--ref-target' -- which links are cross-references, and which
;;      symbol each one names;
;;   2. the click path.  This is the case that matters, because the honest
;;      mistake here is a link that computes the right target and still sends
;;      nothing: `make-text-button' without replacing shr's keymap leaves RET
;;      and mouse-2 on `shr-browse-url'.  So these cases click -- `push-button',
;;      the way RET does -- and check what came out, rather than inspecting the
;;      text properties the fix happens to install;
;;   3. `julia-help-show' on a real payload, which is the whole road the vterm
;;      escape takes: base64 in, JSON decoded, header and methods drawn, the
;;      REPL the payload arrived from remembered;
;;   4. `julia-help--send' -- that following a cross-reference really asks the
;;      REPL for that symbol, in the buffer the docs came from.
;;
;; Nothing here talks to Julia.  The payload is a fixture and `vterm-send-string'
;; is replaced, so no REPL is needed and none is disturbed.
;;
;; The doc buffer is found by name, which is why `julia-help-test--reset' kills
;; those buffers between tests: a leftover one would be found by
;; `display-buffer-reuse-window' and quietly change where the next test lands.
;;
;; What is *not* here: anything about where a buffer lands on screen.  That is
;; the display policy's business, not this package's -- see `julia-help--visit'.

;;; Code:

;; `eval-and-compile', not a bare `add-to-list': byte-compiling this file
;; evaluates the top-level `require' below at COMPILE time but does not evaluate
;; a bare `add-to-list', so the compile cannot find julia-help.el and fails with
;; "Cannot open load file".
;;
;; The three names are all needed, and which one is bound was measured rather
;; than guessed: loading sets `load-file-name', `eval-buffer' leaves
;; `buffer-file-name', and under `batch-byte-compile' BOTH are nil while
;; `byte-compile-current-file' holds the absolute path.  Hence the `when': if
;; none of them is set, this adds nothing instead of signalling on a nil.
(eval-and-compile
  (let ((file (or load-file-name
                  buffer-file-name
                  (bound-and-true-p byte-compile-current-file))))
    (when file
      (add-to-list 'load-path (file-name-directory file)))))

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'shr)
(require 'button)
(require 'julia-help)

;;; Fixtures

(defconst julia-help-test--html
  (concat "<p>Throw a <a href=\"@ref\"><code>DomainError</code></a>, "
          "see <a href=\"@ref sin\">the sine</a> and "
          "<a href=\"https://example.com\">docs</a>.</p>")
  "A docstring fragment with each shape of link in it.")

(defconst julia-help-test--payload
  (concat
   "{\"symbol\":\"sin\",\"binding\":\"Base.sin\",\"module\":\"Base\","
   "\"typesig\":null,"
   "\"html\":\"<p>Compute sine of <code>x</code>, see "
   "<a href=\\\"@ref\\\"><code>sind</code></a>.</p>\","
   "\"results\":["
   "{\"sig\":\"sin(::Number)\",\"typesig\":\"Tuple{Number}\","
   "\"module\":\"Base.Math\",\"path\":\"math.jl\",\"file\":\"/tmp/math.jl\",\"line\":425},"
   "{\"sig\":\"sin(::Real)\",\"typesig\":\"Tuple{Real}\","
   "\"module\":\"Base.Math\",\"path\":\"math.jl\",\"file\":null,\"line\":440}]}")
  "What EmacsVterm.jl sends, with one method that has a file and one that does
not -- the second must not become a button that opens nothing.")

(defconst julia-help-test--tab-payload
  (concat "{\"symbol\":\"tabprobe\",\"binding\":\"tabprobe\","
          "\"html\":\"<p>Prose, a <a href=\\\"@ref\\\"><code>sind</code></a>, "
          "and <a href=\\\"https://example.com\\\">docs</a>.</p>\","
          "\"results\":[]}")
  "A payload with one cross-reference and one ordinary URL link.
The two take different roads: `julia-help--linkify-refs' replaces the keymap on
the first, while shr keeps its own on the second.")

;; Julia's help mode displays an `MD' of its own making -- it goes through
;; `REPL.helpmode', not `Docs.doc' -- so `symbol', `binding', `module' and
;; `typesig' carry nothing and there are no `results'.  This rendered badly
;; once: an empty string is *true* in elisp, so the guards of the shape
;; (when field ...) all passed and the buffer opened on a blank heading line
;; followed by "Defined in:  " and "Signature:   " with nothing after them,
;; named `*julia-help: *' after the empty symbol.
;;
;; Julia now sends null for those fields, but only once its half is updated; a
;; Julia that still sends "" must render identically, so both are checked.
(defconst julia-help-test--no-annotation
  (concat "{\"symbol\":%s,\"binding\":%s,\"module\":%s,\"typesig\":%s,"
          "\"html\":\"<p>Compute sine of <code>x</code>.</p>\","
          "\"results\":[]}")
  "A payload with nothing attached; %s stands in for the four absent fields.")

;;; State the fixtures record into

(defvar julia-help-test--clicked nil
  "Symbols whose documentation was asked for, most recent first.")

(defvar julia-help-test--sent nil
  "Strings `vterm-send-string' was called with, most recent first.")

;;; Helpers

(defun julia-help-test--reset ()
  "Remove anything a previous test left behind.
The doc buffers are all named `*julia-help...', the fixture and the stand-in
REPL included, so one prefix covers them."
  (dolist (b (buffer-list))
    (when (string-prefix-p "*julia-help" (buffer-name b))
      (kill-buffer b))))

(defun julia-help-test--button-with (prop)
  "The first button in the current buffer carrying PROP, or nil."
  (let ((pos (point-min))
        found)
    (while (and (not found) (< pos (point-max)))
      (let ((b (next-button pos)))
        (cond ((null b) (setq pos (point-max)))
              ((button-get b prop) (setq found b))
              (t (setq pos (1+ (button-end b)))))))
    found))

(defun julia-help-test--ref-targets ()
  "The `julia-help-ref' of every cross-reference button, in buffer order."
  (let ((pos (point-min)) found)
    (while (< pos (point-max))
      (let ((b (next-button pos)))
        (if (null b)
            (setq pos (point-max))
          (when (button-get b 'julia-help-ref)
            (push (button-get b 'julia-help-ref) found))
          (setq pos (1+ (button-end b))))))
    (nreverse found)))

(defun julia-help-test--span-start (href)
  "Start of the first run of text in the current buffer whose `shr-url' is HREF.
An untouched shr link is not a button, so `next-button' never sees it and the
span has to be found by property.  (`text-property-any' is no good here: it
compares with `eq', and the href is a fresh string, not the literal.)"
  (let ((pos (point-min))
        found)
    (while (and (not found) (< pos (point-max)))
      (if (equal (get-text-property pos 'shr-url) href)
          (setq found pos)
        (setq pos (or (next-single-property-change pos 'shr-url) (point-max)))))
    found))

(defun julia-help-test--record (target)
  "Stand-in follow function: remember TARGET."
  (push target julia-help-test--clicked))

(defun julia-help-test--click-cross-references ()
  "Click every cross-reference button in the current buffer, in order.
Clicking rather than reading properties is the point: a link whose keymap is
still shr's looks identical on the page, and only the click tells them apart.

Only buttons carrying `julia-help-ref' are clicked.  A link left to shr is a
button too (`next-button' finds it) but has no `action', so clicking it signals
`void-function nil' -- correct for shr to leave alone, and not what this is
about."
  (let ((pos (point-min)))
    (while (< pos (point-max))
      (let ((b (next-button pos)))
        (if (null b)
            (setq pos (point-max))
          (setq pos (1+ (button-end b)))
          (when (button-get b 'julia-help-ref)
            (push-button (button-start b))))))))

(defun julia-help-test--render-fixture ()
  "Render the HTML fixture the way a doc buffer does, and linkify it.
Returns the buffer.  The mode matters: without it TAB resolved through
`button-map' on the string form and found nothing on the vector form, which is
what let a binding useless to a real keypress look correct."
  (let ((buffer (get-buffer-create "*julia-help-test-fixture*")))
    (with-current-buffer buffer
      ;; Mode first, then content, inside `inhibit-read-only' -- the order
      ;; `julia-help--display' uses.  Reversed, `julia-help-mode' runs
      ;; `kill-all-local-variables' and wipes what linkify just set.
      (julia-help-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert julia-help-test--html)
        (shr-render-region (point-min) (point-max))
        (setq julia-help-test--clicked nil)
        (julia-help--linkify-refs #'julia-help-test--record)))
    buffer))

(defun julia-help-test--rendered-p (phrase)
  "Non-nil when PHRASE appears in the current buffer's rendered text.
`shr-render-region' reflows: under `--batch' it puts a newline after every
word, so `search-forward' for a phrase of two words or more never matches.
Comparing against the text with its newlines flattened is what the eye sees."
  (string-match-p (regexp-quote phrase)
                  (replace-regexp-in-string
                   "\n" " " (buffer-substring-no-properties (point-min) (point-max)))))

(defun julia-help-test--tab-runs-p (command)
  "Non-nil when TAB runs COMMAND at point, in both the shapes TAB arrives in.
`(kbd \"TAB\")' is the string a terminal sends; a GUI TAB key sends the vector
`[tab]'.  A binding on one says nothing about the other, and a test checking
only the string passed while the real key ran something else."
  (and (eq command (key-binding (kbd "TAB")))
       (eq command (key-binding [tab]))))

(defun julia-help-test--finds-p (string)
  "Non-nil when STRING appears in the current buffer, point undisturbed."
  (save-excursion
    (goto-char (point-min))
    (search-forward string nil t)))

(defun julia-help-test--show (payload from-buffer)
  "Send PAYLOAD through the entry point, as the vterm filter would."
  (with-current-buffer from-buffer
    (julia-help-show "documentation" "application/json"
                     (base64-encode-string (encode-coding-string payload 'utf-8) t))))

(defun julia-help-test--bare-facts (absent)
  "Render the no-annotation payload with ABSENT in each absent field, and
report what the buffer holds."
  (julia-help-test--reset)
  (julia-help-test--show (format julia-help-test--no-annotation absent absent absent absent)
                         (get-buffer-create "*julia-help-test-repl*"))
  (let ((buffer (get-buffer "*julia-help*")))
    (list :name (and buffer (buffer-name buffer))
          :first-line (and buffer
                           (with-current-buffer buffer
                             (goto-char (point-min))
                             (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position))))
          ;; Any line that is a heading with nothing after it.
          :empty-headers (and buffer
                              (with-current-buffer buffer
                                (seq-some (lambda (line)
                                            (string-match-p
                                             "\\`\\(Defined in:\\|Signature:\\|Methods\\)[ \t]*\\'"
                                             line))
                                          (split-string
                                           (buffer-substring-no-properties
                                            (point-min) (point-max))
                                           "\n"))))
          :has-doc (and buffer
                        (with-current-buffer buffer
                          (and (julia-help-test--rendered-p "Compute sine of") t))))))

;;; 1. Which links are cross-references

;; Julia's Markdown.html writes them two ways; both are measured, not guessed.
(ert-deftest julia-help-test-ref-target ()
  "Both shapes of cross-reference, and everything that is not one."
  ;; The two shapes.
  (should (equal "DomainError" (julia-help--ref-target "@ref" "DomainError")))
  (should (equal "sin(x)" (julia-help--ref-target "@ref" "sin(x)")))
  (should (equal "Base.sin" (julia-help--ref-target "@ref" "Base.sin")))
  (should (equal "sin" (julia-help--ref-target "@ref sin" "the sine")))
  (should (equal "f(::Int)" (julia-help--ref-target "@ref f(::Int)" "f")))
  ;; Everything that is not a cross-reference must be left to shr.
  (should-not (julia-help--ref-target "https://example.com" "docs"))
  (should-not (julia-help--ref-target "#section" "there"))
  ;; The near-misses: a loose `string-prefix-p' would take both of these and
  ;; hand `@doc' the tail of the href.
  (should-not (julia-help--ref-target "@referenced" "x"))
  (should-not (julia-help--ref-target "@ref" "   "))
  (should-not (julia-help--ref-target "@ref " "")))

;;; 2. The click path, on HTML shr has rendered

(ert-deftest julia-help-test-click-path ()
  "RET must reach the button, and clicking must reach the sender."
  (julia-help-test--reset)
  (with-current-buffer (julia-help-test--render-fixture)
    (goto-char (point-min))

    ;; The two links that point at Julia symbols, in buffer order.
    (should (equal '("DomainError" "sin") (julia-help-test--ref-targets)))

    ;; RET and TAB on a cross-reference must reach the button, not shr -- this
    ;; is the assertion the half-fixed version fails.
    (goto-char (button-start (julia-help-test--button-with 'julia-help-ref)))
    (should (eq 'push-button (key-binding (kbd "RET"))))
    (should (julia-help-test--tab-runs-p 'forward-button))

    ;; And on the shr link that was left alone, RET is still shr's.
    (goto-char (julia-help-test--span-start "https://example.com"))
    (should (eq 'shr-browse-url (key-binding (kbd "RET"))))

    ;; Clicking them -- through `push-button', which is what RET runs -- must
    ;; actually call the follow function, with the right symbols.
    (goto-char (point-min))
    (julia-help-test--click-cross-references)
    (should (equal '("DomainError" "sin") (nreverse julia-help-test--clicked)))))

;;; 3. A payload, end to end through `julia-help-show'

(ert-deftest julia-help-test-payload ()
  "The whole road the vterm escape takes, from base64 in to a drawn buffer."
  (julia-help-test--reset)
  (julia-help-test--show julia-help-test--payload
                         (get-buffer-create "*julia-help-test-repl*"))
  (let ((buffer (get-buffer "*julia-help: sin*")))
    (should buffer)
    (should (eq 'julia-help-mode (buffer-local-value 'major-mode buffer)))
    (should (equal "*julia-help-test-repl*"
                   (buffer-name (buffer-local-value 'julia-help--repl-buffer buffer))))
    ;; `q' is not ours: it comes from `special-mode-map'.
    (should (eq 'quit-window
                (lookup-key (buffer-local-value 'julia-help-mode-map buffer) (kbd "q"))))
    (with-current-buffer buffer
      (should (julia-help-test--finds-p "Base.sin"))
      (should (julia-help-test--finds-p "Defined in:  Base"))
      ;; A bare `?sin' has no queried signature, and the payload says so with
      ;; null rather than by rendering `Union{}' for Emacs to recognise.
      (should-not (julia-help-test--finds-p "Signature"))
      (should (julia-help-test--finds-p "Documentation"))
      (should (julia-help-test--rendered-p "Compute sine of"))
      (should (julia-help-test--finds-p "Methods (2)"))
      ;; Only the method whose file is known carries the button properties.
      (let ((with-file (julia-help-test--button-with 'julia-help-file)))
        (should with-file)
        (should (equal '("/tmp/math.jl" 425)
                       (list (button-get with-file 'julia-help-file)
                             (button-get with-file 'julia-help-line)))))
      ;; A cross-reference inside the docstring is linkified in the payload
      ;; case too, not only in the bare-HTML one.
      (should (julia-help-test--button-with 'julia-help-ref)))))

(ert-deftest julia-help-test-signature-line ()
  "A payload carrying a real signature must render a Signature: line.
The payload fixture's `typesig' is null, and a bare `?sin' has no queried
signature, so nothing else in the suite would notice that line going missing."
  (julia-help-test--reset)
  (julia-help-test--show
   (concat "{\"symbol\":\"sin\",\"binding\":\"Base.sin\",\"module\":\"Base\","
           "\"typesig\":\"Tuple{typeof(sin), Float64}\","
           "\"html\":\"<p>Compute sine of <code>x</code>.</p>\","
           "\"results\":[]}")
   (get-buffer-create "*julia-help-test-repl*"))
  (with-current-buffer (get-buffer "*julia-help: sin*")
    (should (julia-help-test--finds-p
             "Signature:   Tuple{typeof(sin), Float64}"))))

;;; 3n. What `?help' sends: nothing attached at all

(ert-deftest julia-help-test-no-annotation-null ()
  "An up-to-date Julia sends null for the four absent fields."
  (let ((facts (julia-help-test--bare-facts "null")))
    (should (equal "*julia-help*" (plist-get facts :name)))
    (should (equal "Documentation" (plist-get facts :first-line)))
    (should-not (plist-get facts :empty-headers))
    (should (plist-get facts :has-doc))))

(ert-deftest julia-help-test-no-annotation-empty-string ()
  "A Julia that still sends \"\" must render identically."
  (let ((facts (julia-help-test--bare-facts "\"\"")))
    (should (equal "*julia-help*" (plist-get facts :name)))
    (should (equal "Documentation" (plist-get facts :first-line)))
    (should-not (plist-get facts :empty-headers))
    (should (plist-get facts :has-doc))))

;;; 3p. The rule that decides both the name and the header

(ert-deftest julia-help-test-buffer-name-and-nonempty ()
  (should (equal "*julia-help: sin*" (julia-help--buffer-name '(:symbol "sin"))))
  (should (equal "*julia-help*" (julia-help--buffer-name '(:symbol ""))))
  (should (equal "*julia-help*" (julia-help--buffer-name '(:html "<p>x</p>"))))
  (should (equal "sin" (julia-help--nonempty "sin")))
  (should-not (julia-help--nonempty ""))
  (should-not (julia-help--nonempty nil)))

;;; 3q. The mode's own keys

(ert-deftest julia-help-test-mode-keys ()
  "The mode map's contents, which are what fires -- not a shadowed intent."
  (should (eq 'push-button (lookup-key julia-help-mode-map (kbd "RET"))))
  (should (eq 'forward-button (lookup-key julia-help-mode-map (kbd "TAB"))))
  (should (eq 'backward-button (lookup-key julia-help-mode-map (kbd "<backtab>"))))
  (should (eq 'forward-button (lookup-key julia-help-mode-map (kbd "n"))))
  (should (eq 'backward-button (lookup-key julia-help-mode-map (kbd "p"))))
  (should (eq 'julia-help-back (lookup-key julia-help-mode-map (kbd "h"))))
  (should (eq 'julia-help-forward (lookup-key julia-help-mode-map (kbd "l"))))
  (should (eq 'julia-help-revert (lookup-key julia-help-mode-map (kbd "gr"))))
  ;; `g' must stay a PREFIX: under Evil it is one, and a complete binding here
  ;; would take `gg' with it.  So the property is not "unbound" -- `gr' lives
  ;; under it -- but "`gg' falls through".
  (should (keymapp (lookup-key julia-help-mode-map (kbd "g"))))
  (should-not (lookup-key julia-help-mode-map (kbd "gg")))
  ;; And `r' is deliberately left to Evil.
  (should-not (lookup-key julia-help-mode-map (kbd "r"))))

;;; 3r. TAB must reach the buttons everywhere, not just where shr is absent

(ert-deftest julia-help-test-tab-walks-buttons-everywhere ()
  "TAB is `forward-button' at every position in a doc buffer, in both shapes.
`shr-render-region' puts `shr-map' on link spans only, and a text-property
keymap outranks the major-mode map -- while `shr-map' binds TAB to
`shr-next-link'.  So TAB worked in prose and on a cross-reference, but on any
other link it ran shr's link walker: it depended on where point was."
  (julia-help-test--reset)
  (julia-help-test--show julia-help-test--tab-payload
                         (get-buffer-create "*julia-help-test-repl*"))
  (with-current-buffer (get-buffer "*julia-help: tabprobe*")
    ;; The header, which we write ourselves -- shr never touches it.
    (goto-char (point-min))
    (should (julia-help-test--tab-runs-p 'forward-button))
    ;; Prose inside the rendered docstring: no keymap of shr's.
    (goto-char (point-min))
    (search-forward "Prose")
    (should (julia-help-test--tab-runs-p 'forward-button))
    ;; A cross-reference, where we replace shr's keymap ourselves.
    (goto-char (point-min))
    (goto-char (button-start (julia-help-test--button-with 'julia-help-ref)))
    (should (julia-help-test--tab-runs-p 'forward-button))
    ;; THE CASE THAT FAILED: an ordinary URL link, which keeps shr's keymap.
    ;; Checked INSIDE the link text, at both ends -- not just past it.  A
    ;; position one char beyond the link is outside shr's keymap span and
    ;; reaches the mode map either way, so reading there let a fix that does
    ;; nothing pass.  (It did: the mutation check caught exactly that.)
    (let* ((start (julia-help-test--span-start "https://example.com"))
           (end (next-single-property-change start 'shr-url)))
      (should start)
      (goto-char start)
      (should (julia-help-test--tab-runs-p 'forward-button))
      (goto-char (1- end))
      (should (julia-help-test--tab-runs-p 'forward-button))
      ;; And RET on that same link must STILL be shr's -- taking TAB back must
      ;; not take the link's own key away.
      (should (eq 'shr-browse-url (key-binding (kbd "RET")))))))

(ert-deftest julia-help-test-follow-sends-to-the-repl ()
  (julia-help-test--reset)
  (julia-help-test--show julia-help-test--payload
                         (get-buffer-create "*julia-help-test-repl*"))
  (with-current-buffer (get-buffer "*julia-help: sin*")
    (goto-char (point-min))
    (let ((button (julia-help-test--button-with 'julia-help-ref)))
      (should button)
      (setq julia-help-test--sent nil)
      (cl-letf (((symbol-function 'vterm-send-string)
                 (lambda (string &optional paste)
                   (push (list string paste) julia-help-test--sent))))
        (push-button (button-start button)))
      (should (equal '(("@doc sind\n" t)) (nreverse julia-help-test--sent)))
      (should (equal (buffer-name (current-buffer))
                     (buffer-name julia-help--pending-back))))))

(ert-deftest julia-help-test-dead-repl-is-reported ()
  "A doc buffer with no live REPL must say so, not fail obscurely."
  (julia-help-test--reset)
  (julia-help-test--show julia-help-test--payload
                         (get-buffer-create "*julia-help-test-repl*"))
  (with-current-buffer (get-buffer "*julia-help: sin*")
    (setq julia-help--repl-buffer nil)
    (should (equal '(user-error "The Julia REPL this documentation came from is gone")
                   (condition-case e (julia-help--send "sin") (error e))))))

(provide 'julia-help-test)

;; Run the suite when this file is loaded in batch, so the documented command
;; cannot report success without having tested anything.  Guarded against
;; `batch-byte-compile', which also sets `noninteractive'.
(when (and noninteractive (not (bound-and-true-p byte-compile-current-file)))
  (ert-run-tests-batch-and-exit))

;;; julia-help-test.el ends here
