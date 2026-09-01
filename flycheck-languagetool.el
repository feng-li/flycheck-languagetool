;;; flycheck-languagetool.el --- Flycheck support for LanguageTool  -*- lexical-binding: t; -*-

;; Copyright (C) 2021-2026  Shen, Jen-Chieh; Peter Oliver
;; Created date 2021-04-02 23:22:44

;; Author: Shen, Jen-Chieh <jcs090218@gmail.com>
;;         Peter Oliver <git@mavit.org.uk>
;; URL: https://github.com/emacs-languagetool/flycheck-languagetool
;; Version: 0.5.0
;; Package-Requires: ((emacs "27.1") (flycheck "39.0.0.20260813"))
;; Keywords: convenience grammar check

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Flycheck support for LanguageTool.
;;

;;; Code:

(require 'diff-mode)
(require 'flycheck)
(eval-when-compile (require 'subr-x))

(defgroup flycheck-languagetool nil
  "Flycheck support for LanguageTool."
  :prefix "flycheck-languagetool-"
  :group 'flycheck
  :link '(url-link :tag "Github" "https://github.com/emacs-languagetool/flycheck-languagetool"))

(defcustom flycheck-languagetool-active-modes
  '(text-mode latex-mode org-mode markdown-mode markdown-ts-mode message-mode)
  "List of major mode that work with LanguageTool."
  :type 'list
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-ignore-tex-math t
  "Whether to ignore LanguageTool matches inside TeX math environments.

This applies in `latex-mode' and modes derived from AUCTeX's `TeX-mode' when
the `texmathp' library is available.  Math is replaced with whitespace before
it is sent to LanguageTool, preserving source positions, and any returned
matches inside or spanning masked math are also discarded."
  :type 'boolean
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-ignore-tex-preamble t
  "Whether to ignore the preamble of a complete TeX document.

When an uncommented `\\begin{document}' is present, the text through that
command is replaced with whitespace before it is sent to LanguageTool.  Source
positions and newlines are preserved.  Buffers without that command, such as
included chapter files, are left unchanged."
  :type 'boolean
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-ignore-tex-commands t
  "Whether to ignore TeX command tokens such as `\\section' and `\\%'.

Only the command token is replaced with whitespace; arguments remain available
for prose checking.  Source positions and newlines are preserved."
  :type 'boolean
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-check-on-save-only nil
  "Whether to disable idle-change checks in LanguageTool modes.

When non-nil, buffers listed in `flycheck-languagetool-active-modes' run
Flycheck when the mode is enabled and when the buffer is saved.  Because
Flycheck's automatic check schedule is buffer-local rather than checker-local,
this also changes the schedule of other Flycheck checkers in those buffers."
  :type 'boolean
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-url nil
  "The URL for the LanguageTool API we should connect to."
  :type '(choice (const :tag "Auto" nil)
                 (string :tag "URL"))
  :package-version '(flycheck-languagetool . "0.3.0")
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-server-command ()
  "Custom command to start LanguageTool server.
If non-nil, this list of strings replaces the standard java cli command."
  :type '(repeat string)
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-server-jar nil
  "The path of languagetool-server.jar.

The server will be automatically started if specified.  Set to
nil if you’re going to connect to a remote LanguageTool server,
or plan to start a local server some other way."
  :type '(choice (const :tag "Off" nil)
                 (file :tag "Filename" :must-match t))
  :package-version '(flycheck-languagetool . "0.3.0")
  :link '(url-link :tag "LanguageTool embedded HTTP Server"
                   "https://dev.languagetool.org/http-server.html")
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-server-port 8081
  "The port on which an automatically started LanguageTool server should listen."
  :type 'integer
  :package-version '(flycheck-languagetool . "0.3.0")
  :link '(url-link :tag "LanguageTool embedded HTTP Server"
                   "https://dev.languagetool.org/http-server.html")
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-server-args ()
  "Extra arguments to pass when starting the LanguageTool server."
  :type '(repeat string)
  :link '(url-link :tag "LanguageTool embedded HTTP Server"
                   "https://dev.languagetool.org/http-server.html")
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-language "en-US"
  "The language code of the text to check."
  :type '(string :tag "Language")
  :safe #'stringp
  :group 'flycheck-languagetool)
(make-variable-buffer-local 'flycheck-languagetool-language)

(defcustom flycheck-languagetool-check-params ()
  "Extra parameters to pass with LanguageTool check requests."
  :type '(alist :key-type string :value-type string)
  :options '("level"
             "enabledOnly"
             "disabledCategories"
             "enabledCategories"
             "disabledRules"
             "enabledRules"
             "preferredVariants"
             "motherTongue"
             "dicts"
             "apiKey"
             "username")
  :link '(url-link
          :tag "LanguageTool API"
          "https://languagetool.org/http-api/swagger-ui/#!/default/post_check")
  :group 'flycheck-languagetool)

(defvar flycheck-languagetool--started-server nil
  "Have we ever attempted to start the LanguageTool server?")

(defvar flycheck-languagetool--spelling-rules
  '("HUNSPELL_RULE"
    "HUNSPELL_RULE_AR"
    "MORFOLOGIK_RULE_AST"
    "MORFOLOGIK_RULE_BE_BY"
    "MORFOLOGIK_RULE_BR_FR"
    "MORFOLOGIK_RULE_CA_ES"
    "MORFOLOGIK_RULE_DE_DE"
    "MORFOLOGIK_RULE_EL_GR"
    "MORFOLOGIK_RULE_EN"
    "MORFOLOGIK_RULE_EN_AU"
    "MORFOLOGIK_RULE_EN_CA"
    "MORFOLOGIK_RULE_EN_GB"
    "MORFOLOGIK_RULE_EN_NZ"
    "MORFOLOGIK_RULE_EN_US"
    "MORFOLOGIK_RULE_EN_ZA"
    "MORFOLOGIK_RULE_ES"
    "MORFOLOGIK_RULE_GA_IE"
    "MORFOLOGIK_RULE_IT_IT"
    "MORFOLOGIK_RULE_LT_LT"
    "MORFOLOGIK_RULE_ML_IN"
    "MORFOLOGIK_RULE_NL_NL"
    "MORFOLOGIK_RULE_PL_PL"
    "MORFOLOGIK_RULE_RO_RO"
    "MORFOLOGIK_RULE_RU_RU"
    "MORFOLOGIK_RULE_RU_RU_YO"
    "MORFOLOGIK_RULE_SK_SK"
    "MORFOLOGIK_RULE_SL_SI"
    "MORFOLOGIK_RULE_SR_EKAVIAN"
    "MORFOLOGIK_RULE_SR_JEKAVIAN"
    "MORFOLOGIK_RULE_TL"
    "MORFOLOGIK_RULE_UK_UA"
    "SYMSPELL_RULE")
  "LanguageTool rules for checking of spelling.
These rules will be disabled if Emacs’ `flyspell-mode' or
`jinx-mode' is active.")

(defface flycheck-languagetool-suggestion-face
  '((t (:inherit diff-changed)))
  "Flycheck face for LanguageTool suggestions."
  :package-version '(flycheck-languagetool . "0.5.0")
  :group 'flycheck-languagetool)

(defcustom flycheck-languagetool-suggestion-limit 12
  "The maximum number of correction suggestions to show per warning.
Any suggestions beyond this count will be ignored."
  :type '(integer :tag "Count")
  :safe (lambda (n)
          (and (integerp n)
               (< n 256))) ;; This number is somewhat picked out of the
                           ;; air, but large values can hurt
                           ;; performance.
  :package-version '(flycheck-languagetool . "0.5.0")
  :group 'flycheck-languagetool)

;;
;; (@* "External" )
;;

(defvar url-http-end-of-headers)
(defvar url-request-method)
(defvar url-request-extra-headers)
(defvar url-request-data)
(declare-function texmathp "texmathp")

;;
;; (@* "Core" )
;;

(defun flycheck-languagetool--tex-mode-p ()
  "Return non-nil when the current buffer uses a TeX mode."
  (or (eq major-mode 'latex-mode)
      (derived-mode-p 'TeX-mode)))

(defun flycheck-languagetool--configure-automatic-checking ()
  "Configure automatic Flycheck timing for a LanguageTool buffer."
  (when (and flycheck-languagetool-check-on-save-only
             (memq major-mode flycheck-languagetool-active-modes))
    (setq-local flycheck-check-syntax-automatically
                '(save mode-enabled))))

(defun flycheck-languagetool--math-face-p (face)
  "Return non-nil when FACE includes `font-latex-math-face'."
  (or (eq face 'font-latex-math-face)
      (and (listp face)
           (memq 'font-latex-math-face face))))

(defconst flycheck-languagetool--tex-command-regexp
  "\\\\\\(?:[[:alpha:]@]+\\*?\\|[^[:alpha:]@\n]\\)"
  "Regular expression matching a TeX control word or control symbol.")

(defun flycheck-languagetool--tex-preamble-end ()
  "Return the end of the current buffer's TeX preamble, or nil."
  (when (and flycheck-languagetool-ignore-tex-preamble
             (flycheck-languagetool--tex-mode-p))
    (save-excursion
      (goto-char (point-min))
      (let (end)
        (while (and (not end)
                    (re-search-forward "\\\\begin\\s-*{document}" nil t))
          (unless (save-excursion
                    (nth 4 (syntax-ppss (match-beginning 0))))
            (setq end (point))))
        end))))

(defun flycheck-languagetool--buffer-text ()
  "Return buffer text suitable for checking with LanguageTool.

When `flycheck-languagetool-ignore-tex-preamble' is non-nil, replace a complete
document's TeX preamble with spaces.  Buffers without `\\begin{document}' are
not affected.

When `flycheck-languagetool-ignore-tex-commands' is non-nil, replace TeX command
tokens with spaces while retaining their arguments.

When `flycheck-languagetool-ignore-tex-math' is non-nil, replace characters
fontified as TeX math with spaces.  Preserve newlines and string length so
LanguageTool offsets continue to refer to the original buffer positions."
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (let ((preamble-end (flycheck-languagetool--tex-preamble-end)))
      (when preamble-end
        (cl-loop for buffer-pos from (point-min) below preamble-end
                 for string-pos from 0
                 unless (eq (char-after buffer-pos) ?\n)
                 do (aset text string-pos ?\s))))
    (when (and flycheck-languagetool-ignore-tex-commands
               (flycheck-languagetool--tex-mode-p))
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward
                flycheck-languagetool--tex-command-regexp nil t)
          (cl-loop for buffer-pos from (match-beginning 0) below (match-end 0)
                   for string-pos from (- (match-beginning 0) (point-min))
                   unless (eq (char-after buffer-pos) ?\n)
                   do (aset text string-pos ?\s)))))
    (when (and flycheck-languagetool-ignore-tex-math
               (flycheck-languagetool--tex-mode-p))
      (font-lock-ensure (point-min) (point-max))
      (let ((pos (point-min))
            (limit (point-max)))
        (while (< pos limit)
          (let ((next (next-single-property-change pos 'face nil limit)))
            (when (flycheck-languagetool--math-face-p
                   (get-text-property pos 'face))
              (cl-loop for buffer-pos from pos below next
                       for string-pos from (- pos (point-min))
                       unless (eq (char-after buffer-pos) ?\n)
                       do (aset text string-pos ?\s)))
            (setq pos next)))))
    text))

(defun flycheck-languagetool--tex-math-p (pos)
  "Return non-nil when POS is inside a TeX math environment."
  (and flycheck-languagetool-ignore-tex-math
       (flycheck-languagetool--tex-mode-p)
       (or (fboundp 'texmathp)
           (require 'texmathp nil t))
       (save-excursion
         (goto-char pos)
         (texmathp))))

(defun flycheck-languagetool--tex-math-range-p (beg end)
  "Return non-nil when the range from BEG to END contains masked TeX math."
  (when (and flycheck-languagetool-ignore-tex-math
             (flycheck-languagetool--tex-mode-p))
    (let ((pos (max beg (point-min)))
          (limit (min end (point-max)))
          found)
      (when (< pos limit)
        (font-lock-ensure pos limit)
        (while (and (< pos limit) (not found))
          (setq found
                (flycheck-languagetool--math-face-p
                 (get-text-property pos 'face))
                pos (next-single-property-change pos 'face nil limit))))
      found)))

(defun flycheck-languagetool--tex-command-range-p (beg end)
  "Return non-nil when the range from BEG to END overlaps a TeX command."
  (when (and flycheck-languagetool-ignore-tex-commands
             (flycheck-languagetool--tex-mode-p))
    (save-excursion
      (goto-char (max beg (point-min)))
      (goto-char (line-beginning-position))
      (let ((limit (save-excursion
                     (goto-char (min end (point-max)))
                     (line-end-position)))
            found)
        (while (and (not found)
                    (re-search-forward
                     flycheck-languagetool--tex-command-regexp limit t))
          (setq found
                (and (< (match-beginning 0) end)
                     (> (match-end 0) beg))))
        found))))

(defun flycheck-languagetool--check-all (results tick)
  "Map RESULTS from LanguageTool to positions of errors in the buffer.
TICK was the result of `buffer-chars-modified-tick' at the time of the check."
  (let ((matches (cdr (assoc 'matches results)))
        (preamble-end (flycheck-languagetool--tex-preamble-end))
        check-list)
    (dolist (match matches)
      (let* ((pt-beg (+ (point-min) (cdr (assoc 'offset match))))
             (len (cdr (assoc 'length match)))
             (pt-end (+ pt-beg len))
             (type 'warning)
             (id (cdr (assoc 'id (assoc 'rule match))))
             (subid (cdr (assoc 'subId (assoc 'rule match))))
             (replacements (cdr (assoc 'replacements match)))
             (fix (when replacements
                    (flycheck-fix-new
                     :description (cdr (assoc 'shortMessage match))
                     :edits (list
                             (flycheck-fix-edit-new-at-pos
                              pt-beg pt-end
                              (cdr (assoc 'value (car replacements)))))
                     :tick tick)))
             (desc
              (apply #'concat
                     (cdr (assoc 'message match))
                     (when replacements
                       (list
                        " Suggestions: "
                        (mapconcat
                         (lambda (replacement)
                           (let ((suggestion
                                  (copy-sequence
                                   (cdr (assoc 'value replacement)))))
                             (put-text-property
                              0
                              (length suggestion)
                              'face
                              'flycheck-languagetool-suggestion-face
                              suggestion)
                             suggestion))
                         (seq-take replacements
                                   flycheck-languagetool-suggestion-limit)
                         ", ")
                        (if (> (length replacements)
                               flycheck-languagetool-suggestion-limit)
                            "…"
                          "."))))))
        (unless (or (and preamble-end (< pt-beg preamble-end))
                    (flycheck-languagetool--tex-math-p pt-beg)
                    (flycheck-languagetool--tex-math-range-p pt-beg pt-end)
                    (flycheck-languagetool--tex-command-range-p pt-beg pt-end))
          (push (list pt-beg type desc
                      :end-pos pt-end
                      :id (cons id subid)
                      :fix fix)
                check-list))))
    check-list))

(defun flycheck-languagetool--read-results (status source-buffer tick callback)
  "Callback for results from LanguageTool API.

STATUS is passed from `url-retrieve'.
SOURCE-BUFFER is the buffer currently being checked.
TICK was the result of `buffer-chars-modified-tick' at the time of the request.
CALLBACK is passed from Flycheck."
  (let ((err (plist-get status :error)))
    (when err
      (error
       (funcall callback 'errored
                (error-message-string
                 (append err
                         (list (progn
                                 (goto-char (+ 1 url-http-end-of-headers))
                                 (buffer-substring (point) (point-max))))))))))

  (if (buffer-live-p source-buffer)
      (progn
        (set-buffer-multibyte t)
        (goto-char url-http-end-of-headers)
        (let ((results (car (flycheck-parse-json
                             (buffer-substring (point) (point-max))))))
          (kill-buffer)
          (with-current-buffer source-buffer
            (funcall
             callback 'finished
             (mapcar
              (lambda (x)
                (apply #'flycheck-error-new-at-pos `(,@x :checker languagetool)))
              (condition-case err
                  (flycheck-languagetool--check-all results tick)
                (error (funcall callback 'errored (error-message-string err)))))))))
    (kill-buffer)
    (funcall callback 'interrupted nil)))

(defun flycheck-languagetool--start-server ()
  "Start the LanguageTool server if we didn’t already."
  (unless (process-live-p (get-process "languagetool-server"))
    (let* ((cmd (or flycheck-languagetool-server-command
                    (list "java" "-cp" (expand-file-name flycheck-languagetool-server-jar)
                          "org.languagetool.server.HTTPServer"
                          "--port" (format "%s" flycheck-languagetool-server-port))))
           (process
            (apply #'start-process
                   "languagetool-server"
                   " *LanguageTool server*"
                   (append cmd flycheck-languagetool-server-args))))
      (set-process-query-on-exit-flag process nil)
      (while
          (with-current-buffer (process-buffer process)
            (goto-char (point-min))
            (unless (re-search-forward " Server started$" nil t)
              (accept-process-output process 1)
              (process-live-p process)))))))

(defun flycheck-languagetool--start (_checker callback)
  "Flycheck start function for _CHECKER `languagetool', invoking CALLBACK."
  (when (or flycheck-languagetool-server-command
            flycheck-languagetool-server-jar)
    (unless flycheck-languagetool--started-server
      (setq flycheck-languagetool--started-server t)
      (flycheck-languagetool--start-server)))

  (let* ((url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/x-www-form-urlencoded")))
         (disabled-rules
          (flatten-tree (list
                         (cdr (assoc "disabledRules"
                                     flycheck-languagetool-check-params))
                         (when (or (bound-and-true-p flyspell-mode)
                                   (bound-and-true-p jinx-mode))
                           flycheck-languagetool--spelling-rules))))
         (other-params (assoc-delete-all "disabledRules"
                                         (copy-alist flycheck-languagetool-check-params)))
         (url-request-data
          (mapconcat
           (lambda (param)
             (concat (url-hexify-string (car param)) "="
                     (url-hexify-string (cdr param))))
           (append other-params
                   `(("language" . ,flycheck-languagetool-language)
                     ("text" . ,(flycheck-languagetool--buffer-text)))
                   (when disabled-rules
                     (list (cons "disabledRules"
                                 (string-join disabled-rules ",")))))
           "&")))
    (url-retrieve
     (concat (or flycheck-languagetool-url
                 (format "http://localhost:%s"
                         flycheck-languagetool-server-port))
             "/v2/check")
     #'flycheck-languagetool--read-results
     (list (current-buffer) (buffer-chars-modified-tick) callback)
     t)))

(defun flycheck-languagetool--error-explainer (err)
  "Link to a detailed explanation of ERR on the LanguageTool website."
  (let* ((error-id (flycheck-error-id err))
         (id (car error-id))
         (subid (cdr error-id))
         (url (apply #'format
                     "https://community.languagetool.org/rule/show/%s?lang=%s"
                     (mapcar #'url-hexify-string
                             (list id flycheck-languagetool-language)))))
    (when subid
      (setq url (concat url
                        (format "&subId=%s" (url-hexify-string subid)))))
    `(url . ,url)))

(defun flycheck-languagetool--enabled ()
  "Can the Flycheck LanguageTool checker be enabled?"
  (cond (flycheck-languagetool-url
         (not (string= "" flycheck-languagetool-url)))
        (flycheck-languagetool-server-command
         (and (listp flycheck-languagetool-server-command)
              (executable-find (car flycheck-languagetool-server-command))))
        (flycheck-languagetool-server-jar
         (and (not (string= "" flycheck-languagetool-server-jar))
              (file-exists-p flycheck-languagetool-server-jar)
              (executable-find "java")))))

(defun flycheck-languagetool--verify (_checker)
  "Verify proper configuration of Flycheck _CHECKER `languagetool'."
  (list
   (flycheck-verification-result-new
    ;; We could improve this test by also checking that we can
    ;; successfully make requests to the URL.
    :label "LanguageTool API URL"
    :message (if flycheck-languagetool-url
                 (if (not (string= "" flycheck-languagetool-url))
                     flycheck-languagetool-url "Blank")
               "Not configured")
    :face (if flycheck-languagetool-url
              (if (not (string= "" flycheck-languagetool-url))
                  'success '(bold error))
            '(bold warning)))
   (flycheck-verification-result-new
    :label "LanguageTool server command"
    :message
    (if flycheck-languagetool-server-command
        (format (if (and (executable-find
                          (car flycheck-languagetool-server-command)))
                    "Found at %s" "Configured as %s but missing")
                (car flycheck-languagetool-server-command))
      "Not configured")
    :face (if flycheck-languagetool-server-command
              (if (and (listp flycheck-languagetool-server-command)
                       (executable-find
                        (car flycheck-languagetool-server-command)))
                  'success '(bold error))
            '(bold warning)))
   (flycheck-verification-result-new
    :label "LanguageTool server JAR"
    :message
    (if flycheck-languagetool-server-jar
        (format (if (and (not (string= "" flycheck-languagetool-server-jar))
                         (file-exists-p flycheck-languagetool-server-jar))
                    "Found at %s" "Missing from %s")
                flycheck-languagetool-server-jar)
      "Not configured")
    :face (if flycheck-languagetool-server-jar
              (if (and (not (string= "" flycheck-languagetool-server-jar))
                       (file-exists-p flycheck-languagetool-server-jar))
                  'success '(bold error))
            '(bold warning)))
   (flycheck-verification-result-new
    :label "Java executable"
    :message (or (executable-find "java") "Not found")
    :face (if (executable-find "java") 'success '(bold warning)))))

(flycheck-define-generic-checker 'languagetool
  "LanguageTool flycheck definition."
  :start #'flycheck-languagetool--start
  :enabled #'flycheck-languagetool--enabled
  :verify #'flycheck-languagetool--verify
  :error-explainer #'flycheck-languagetool--error-explainer
  :modes flycheck-languagetool-active-modes
  :next-checkers '(proselint))

;;;###autoload
(defun flycheck-languagetool-setup ()
  "Register LanguageTool with Flycheck and install its buffer setup hook."
  (interactive)
  (add-hook 'flycheck-mode-hook
            #'flycheck-languagetool--configure-automatic-checking)
  (add-to-list 'flycheck-checkers 'languagetool))

(provide 'flycheck-languagetool)
;;; flycheck-languagetool.el ends here
