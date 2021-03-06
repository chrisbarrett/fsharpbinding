;;; fsharp-mode-completion.el --- Autocompletion support for F#

;; Copyright (C) 2012-2013 Robin Neatherway

;; Author: Robin Neatherway <robin.neatherway@gmail.com>
;; Maintainer: Robin Neatherway <robin.neatherway@gmail.com>
;; Keywords: languages

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

(require 's)
(require 'dash)
(require 'fsharp-mode-indent)
(require 'auto-complete)

(autoload 'pos-tip-fill-string "pos-tip")
(autoload 'pos-tip-show "pos-tip")
(autoload 'popup-tip "popup")
(autoload 'json-array-type "json")
(autoload 'json-read-from-string "json")

;;; User-configurable variables

(defvar fsharp-ac-executable "fsautocomplete.exe")

(defvar fsharp-ac-complete-command
  (let ((exe (or (executable-find fsharp-ac-executable)
                 (concat (file-name-directory (or load-file-name buffer-file-name))
                         "bin/" fsharp-ac-executable))))
    (case system-type
      (windows-nt exe)
      (otherwise (list "mono" exe)))))

(defvar fsharp-ac-use-popup t
  "Display tooltips using a popup at point. If set to nil,
display in a help buffer instead.")

(defvar fsharp-ac-intellisense-enabled t
  "Whether autocompletion is automatically triggered on '.'")

(defface fsharp-error-face
  '((t :inherit error))
  "Face used for marking an error in F#"
  :group 'fsharp)

(defface fsharp-warning-face
  '((t :inherit warning))
  "Face used for marking a warning in F#"
  :group 'fsharp)

;;; Both in seconds. Note that background process uses ms.
(defvar fsharp-ac-blocking-timeout 0.4)
(defvar fsharp-ac-idle-timeout 1)

;;; ----------------------------------------------------------------------------

(defvar fsharp-ac-debug nil)
(defvar fsharp-ac-status 'idle)
(defvar fsharp-ac-completion-process nil)
(defvar fsharp-ac-partial-data "")
(defvar fsharp-ac-project-files nil)
(defvar fsharp-ac-idle-timer nil)
(defvar fsharp-ac-verbose nil)
(defvar fsharp-ac-current-candidate)
(defvar fsharp-ac-current-candidate-help)


(defun log-to-proc-buf (proc str)
  (when (processp proc)
    (let ((buf (process-buffer proc))
          (atend (with-current-buffer (process-buffer proc)
                   (eq (marker-position (process-mark proc)) (point)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (goto-char (process-mark proc))
          (insert-before-markers str))
        (if atend
            (with-current-buffer buf
              (goto-char (process-mark proc))))))))

(defun log-psendstr (proc str)
  (when fsharp-ac-debug
    (log-to-proc-buf proc str))
  (process-send-string proc str))

(defun fsharp-ac-parse-current-buffer ()
  (save-restriction
    (let ((file (expand-file-name (buffer-file-name))))
      (widen)
      (log-to-proc-buf fsharp-ac-completion-process
                       (format "Parsing \"%s\"\n" file))
      (process-send-string
       fsharp-ac-completion-process
       (format "parse \"%s\" full\n%s\n<<EOF>>\n"
               file
               (buffer-substring-no-properties (point-min) (point-max)))))))

(defun fsharp-ac-parse-file (file)
  (with-current-buffer (find-file-noselect file)
    (fsharp-ac-parse-current-buffer)))

;;; ----------------------------------------------------------------------------
;;; File Parsing and loading

(defun fsharp-ac/load-project (file)
  "Load the specified F# file as a project"
  (interactive
  ;; Prompt user for an fsproj, searching for a default.
   (list (read-file-name
          "Path to project: "
          (fsharp-mode/find-fsproj buffer-file-name)
          (fsharp-mode/find-fsproj buffer-file-name))))

  (when (fsharp-ac--valid-project-p file)
    (fsharp-ac--reset)
    (when (not (fsharp-ac--process-live-p))
      (fsharp-ac/start-process))
    ;; Load given project.
    (when (fsharp-ac--process-live-p)
      (log-psendstr fsharp-ac-completion-process "outputmode json\n")
      (log-psendstr fsharp-ac-completion-process
                    (format "project \"%s\"\n" (expand-file-name file))))
    file))

(defun fsharp-ac/load-file (file)
  "Start the compiler binding for an individual F# script."
  (when (fsharp-ac--script-file-p file)
    (if (file-exists-p file)
        (when (not (fsharp-ac--process-live-p))
          (fsharp-ac/start-process))
      (add-hook 'after-save-hook 'fsharp-ac--load-after-save nil 'local))))

(defun fsharp-ac--load-after-save ()
  (remove-hook 'fsharp-ac--load-after-save 'local)
  (fsharp-ac/load-file (buffer-file-name)))

(defun fsharp-ac--valid-project-p (file)
  (and file
       (file-exists-p file)
       (string-match-p (rx "." "fsproj" eol) file)))

(defun fsharp-ac--script-file-p (file)
  (and file
       (string-match-p (rx (or "fsx" "fsscript"))
                       (file-name-extension file))))

(defun fsharp-ac--reset ()
  (setq fsharp-ac-partial-data nil
        fsharp-ac-project-files nil
        fsharp-ac-status 'idle
        fsharp-ac-current-candidate nil
        fsharp-ac-current-candidate-help nil)
  (fsharp-ac-clear-errors))

;;; ----------------------------------------------------------------------------
;;; Display Requests

(defun fsharp-ac-send-pos-request (cmd file line col)
  (log-psendstr fsharp-ac-completion-process
                (format "%s \"%s\" %d %d %d\n" cmd file line col
                        (* 1000 fsharp-ac-blocking-timeout))))

(defun fsharp-ac--process-live-p ()
  "Check whether the background process is live"
  (and fsharp-ac-completion-process
       (process-live-p fsharp-ac-completion-process)))

(defun fsharp-ac/stop-process ()
  (interactive)
  (fsharp-ac-message-safely "Quitting fsharp completion process")
  (when (fsharp-ac--process-live-p)
    (log-psendstr fsharp-ac-completion-process "quit\n")
    (sleep-for 1)
    (when (process-live-p fsharp-ac-completion-process)
      (kill-process fsharp-ac-completion-process)))
  (when fsharp-ac-idle-timer
    (cancel-timer fsharp-ac-idle-timer))
  (setq fsharp-ac-status 'idle
        fsharp-ac-completion-process nil
        fsharp-ac-partial-data ""
        fsharp-ac-project-files nil
        fsharp-ac-idle-timer nil
        fsharp-ac-verbose nil)
  (fsharp-ac-clear-errors))

(defun fsharp-ac/start-process ()
  "Launch the F# completion process in the background"
  (interactive)

  (when (fsharp-ac--process-live-p)
    (kill-process fsharp-ac-completion-process))

  (setq fsharp-ac-completion-process (fsharp-ac--configure-proc))
  (fsharp-ac--reset-timer))

(defun fsharp-ac--configure-proc ()
  (let ((proc (let (process-connection-type)
                (apply 'start-process "fsharp-complete" "*fsharp-complete*"
                       fsharp-ac-complete-command))))
    (sleep-for 0.1)
    (if (process-live-p proc)
        (progn
          (set-process-filter proc 'fsharp-ac-filter-output)
          (set-process-query-on-exit-flag proc nil)
          (setq fsharp-ac-status 'idle
                fsharp-ac-partial-data ""
                fsharp-ac-project-files nil)
          (add-to-list 'ac-modes 'fsharp-mode)
          proc)
      (fsharp-ac-message-safely "Failed to launch: '%s'"
                                (s-join " " fsharp-ac-complete-command))
      nil)))

(defun fsharp-ac--reset-timer ()
  (when fsharp-ac-idle-timer
    (cancel-timer fsharp-ac-idle-timer))
  (setq fsharp-ac-idle-timer
        (run-with-idle-timer fsharp-ac-idle-timeout
                             t
                             'fsharp-ac-request-errors)))


(defvar fsharp-ac-source
  '((candidates . fsharp-ac-candidate)
    (prefix . fsharp-ac-prefix)
    (requires . 0)
    (document . fsharp-ac-document)
    ;(action . fsharp-ac-action)
    (cache) ; this prevents multiple re-calls, critical
    ))

(defun fsharp-ac-document (item)
  (pos-tip-fill-string
   (cdr (assq 'Help
              (-first (lambda (e) (string= item (cdr (assq 'Name e))))
                      fsharp-ac-current-candidate-help)))
   80))

(defun fsharp-ac-candidate ()
  (interactive)
  (case fsharp-ac-status
    (idle
     (setq fsharp-ac-status 'wait)
     (setq fsharp-ac-current-candidate nil)
     (setq fsharp-ac-current-candidate-help nil)

     (fsharp-ac-parse-current-buffer)
     (fsharp-ac-send-pos-request
      "completion"
      (expand-file-name (buffer-file-name (current-buffer)))
      (- (line-number-at-pos) 1)
      (current-column)))

    (wait
     fsharp-ac-current-candidate)

    (acknowledged
     (setq fsharp-ac-status 'idle)
     fsharp-ac-current-candidate)

    (preempted
     nil)))

(defun fsharp-ac-prefix ()
  (or (ac-prefix-symbol)
      (let ((c (char-before)))
        (when (eq ?\. c)
          (point)))))


(defun fsharp-ac-can-make-request ()
  (and (fsharp-ac--process-live-p)
       (or
        (member (expand-file-name (buffer-file-name)) fsharp-ac-project-files)
        (string-match-p (rx (or "fsx" "fsscript"))
                        (file-name-extension (buffer-file-name))))))

(defvar fsharp-ac-awaiting-tooltip nil)

(defun fsharp-ac/show-tooltip-at-point ()
  "Display a tooltip for the F# symbol at POINT."
  (interactive)
  (setq fsharp-ac-awaiting-tooltip t)
  (fsharp-ac/show-typesig-at-point))

(defun fsharp-ac/show-typesig-at-point ()
  "Display the type signature for the F# symbol at POINT."
  (interactive)
  (when (fsharp-ac-can-make-request)
    (fsharp-ac-parse-current-buffer)
    (fsharp-ac-send-pos-request "tooltip"
                                (expand-file-name (buffer-file-name))
                                (- (line-number-at-pos) 1)
                                (current-column))))

(defun fsharp-ac/gotodefn-at-point ()
  "Find the point of declaration of the symbol at point and goto it"
  (interactive)
  (when (fsharp-ac-can-make-request)
    (fsharp-ac-parse-current-buffer)
    (fsharp-ac-send-pos-request "finddecl"
                                (expand-file-name (buffer-file-name))
                                (- (line-number-at-pos) 1)
                                (current-column))))

(defun fsharp-ac--ac-start (&rest ac-start-args)
  "Start completion, using only the F# completion source for intellisense."
  (interactive)
  (let ((ac-sources '(fsharp-ac-source))
        (ac-auto-show-menu t))
    (apply 'ac-start ac-start-args)))

(defun fsharp-ac/electric-key ()
  (interactive)
  (self-insert-command 1)
  (fsharp-ac/complete-at-point))

(defun fsharp-ac/complete-at-point ()
  (interactive)
  (if (and (fsharp-ac-can-make-request)
           (eq fsharp-ac-status 'idle)
           fsharp-ac-intellisense-enabled)
      (fsharp-ac--ac-start)
    (setq fsharp-ac-status 'preempted)))

;;; ----------------------------------------------------------------------------
;;; Errors and Overlays

(defstruct fsharp-error start end face text)

(defvar fsharp-ac-errors)
(make-local-variable 'fsharp-ac-errors)

(defconst fsharp-ac-error-regexp
     "\\[\\([0-9]+\\):\\([0-9]+\\)-\\([0-9]+\\):\\([0-9]+\\)\\] \\(ERROR\\|WARNING\\) \\(.*\\(?:\n[^[].*\\)*\\)"
     "Regexp to match errors that come from fsautocomplete. Each
starts with a character range for position and is followed by
possibly many lines of description.")

(defun fsharp-ac-request-errors ()
  (when (fsharp-ac-can-make-request)
    (fsharp-ac-parse-current-buffer)
    (log-psendstr fsharp-ac-completion-process "errors\n")))

(defun fsharp-ac-line-column-to-pos (line col)
  (save-excursion
    (goto-char (point-min))
    (forward-line (- line 1))
    (if (< (point-max) (+ (point) col))
        (point-max)
      (forward-char col)
      (point))))

(defun fsharp-ac-parse-errors (str)
  "Extract the errors from the given process response. Returns a list of fsharp-error."
  (save-match-data
    (let (parsed)
      (while (string-match fsharp-ac-error-regexp str)
        (let ((beg (fsharp-ac-line-column-to-pos (+ (string-to-number (match-string 1 str)) 1)
                      (string-to-number (match-string 2 str))))
              (end (fsharp-ac-line-column-to-pos (+ (string-to-number (match-string 3 str)) 1)
                      (string-to-number (match-string 4 str))))
              (face (if (string= "ERROR" (match-string 5 str))
                        'fsharp-error-face
                      'fsharp-warning-face))
              (msg (match-string 6 str))
              )
          (setq str (substring str (match-end 0)))
          (add-to-list 'parsed (make-fsharp-error :start beg
                                                  :end   end
                                                  :face  face
                                                  :text  msg))))
      parsed)))

(defun fsharp-ac/show-error-overlay (err)
  "Draw overlays in the current buffer to represent fsharp-error ERR."
  ;; Three cases
  ;; 1. No overlays here yet: make it
  ;; 2. new warning, exists error: do nothing
  ;; 3. new error exists warning: rm warning and make it
  (let* ((beg  (fsharp-error-start err))
         (end  (fsharp-error-end err))
         (face (fsharp-error-face err))
         (txt  (fsharp-error-text err))
         (ofaces (mapcar (lambda (o) (overlay-get o 'face))
                         (overlays-in beg end)))
         )
    (unless (and (eq face 'fsharp-warning-face)
                 (memq 'fsharp-error-face ofaces))

      (when (and (eq face 'fsharp-error-face)
                 (memq 'fsharp-warning-face ofaces))
        (remove-overlays beg end 'face 'fsharp-warning-face))

      (let ((ov (make-overlay beg end)))
        (overlay-put ov 'face face)
        (overlay-put ov 'help-echo txt)))))

(defun fsharp-ac-clear-errors ()
  (interactive)
  (remove-overlays nil nil 'face 'fsharp-error-face)
  (remove-overlays nil nil 'face 'fsharp-warning-face)
  (setq fsharp-ac-errors nil))

;;; ----------------------------------------------------------------------------
;;; Error navigation
;;;
;;; These functions hook into Emacs' error navigation API and should not
;;; be called directly by users.

(defun fsharp-ac-message-safely (format-string &rest args)
  "Calls MESSAGE only if it is desirable to do so."
  (when (equal major-mode 'fsharp-mode)
    (unless (or (active-minibuffer-window) cursor-in-echo-area)
      (apply 'message format-string args))))

(defun fsharp-ac-error-position (n-steps errs)
  "Calculate the position of the next error to move to."
  (let* ((xs (->> (sort (-map 'fsharp-error-start errs) '<)
               (--remove (= (point) it))
               (--split-with (>= (point) it))))
         (before (nreverse (car xs)))
         (after  (cadr xs))
         (errs   (if (< n-steps 0) before after))
         (step   (- (abs n-steps) 1))
         )
    (nth step errs)))

(defun fsharp-ac/next-error (n-steps reset)
  "Move forward N-STEPS number of errors, possibly wrapping
around to the start of the buffer."
  (when reset
    (goto-char (point-min)))

  (let ((pos (fsharp-ac-error-position n-steps fsharp-ac-errors)))
    (if pos
        (goto-char pos)
      (error "No more F# errors"))))

(defun fsharp-ac-fsharp-overlay-p (ov)
  (let ((face (overlay-get ov 'face)))
    (or (equal 'fsharp-warning-face face)
        (equal 'fsharp-error-face face))))

(defun fsharp-ac/overlay-at (pos)
  (car-safe (-filter 'fsharp-ac-fsharp-overlay-p
                     (overlays-at pos))))

;;; HACK: show-error-at point checks last position of point to prevent
;;; corner-case interaction issues, e.g. when running `describe-key`
(defvar fsharp-ac-last-point nil)

(defun fsharp-ac/show-error-at-point ()
  (let ((ov (fsharp-ac/overlay-at (point)))
        (changed-pos (not (equal (point) fsharp-ac-last-point))))
    (setq fsharp-ac-last-point (point))

    (when (and ov changed-pos)
      (fsharp-ac-message-safely (overlay-get ov 'help-echo)))))

;;; ----------------------------------------------------------------------------
;;; Process handling
;;;
;;; Handle output from the completion process.

(defconst fsharp-ac-eom "\n<<EOF>>\n")

(defun fsharp-ac-filter-output (proc str)
  "Filter output from the completion process and handle appropriately."
  (log-to-proc-buf proc str)
  (setq fsharp-ac-partial-data (concat fsharp-ac-partial-data str))

  (let ((eofloc (string-match-p fsharp-ac-eom fsharp-ac-partial-data)))
    (while eofloc
      (let ((msg  (substring fsharp-ac-partial-data 0 eofloc))
            (part (substring fsharp-ac-partial-data (+ eofloc (length fsharp-ac-eom)))))
        (cond
         ((s-starts-with? "DATA: completion" msg) (fsharp-ac-handle-completion msg))
         ((s-starts-with? "DATA: finddecl" msg)   (fsharp-ac-visit-definition msg))
         ((s-starts-with? "DATA: tooltip" msg)    (fsharp-ac-handle-tooltip msg))
         ((s-starts-with? "DATA: errors" msg)     (fsharp-ac-handle-errors msg))
         ((s-starts-with? "DATA: project" msg)    (fsharp-ac-handle-project msg))
         ((s-starts-with? "ERROR: " msg)          (fsharp-ac-handle-process-error msg))
         ((s-starts-with? "INFO: " msg) (when fsharp-ac-verbose (fsharp-ac-message-safely msg)))
         (t
          (fsharp-ac-message-safely "Error: unrecognised message: '%s'" msg)))

        (setq fsharp-ac-partial-data part))
      (setq eofloc (string-match-p fsharp-ac-eom fsharp-ac-partial-data)))))

(defun fsharp-ac-handle-completion (str)
  (setq str
        (s-replace "DATA: completion" "" str))
  (let* ((json-array-type 'list)
         (cs (json-read-from-string str))
         (names (-map (lambda (e) (cdr (assq 'Name e))) cs)))

    (case fsharp-ac-status
      (preempted
       (setq fsharp-ac-status 'idle)
       (fsharp-ac--ac-start)
       (ac-update))

      (otherwise
       (setq fsharp-ac-current-candidate names
             fsharp-ac-current-candidate-help cs
             fsharp-ac-status 'acknowledged)
       (fsharp-ac--ac-start :force-init t)
       (ac-update)
       (setq fsharp-ac-status 'idle)))))

(defun fsharp-ac-visit-definition (str)
  (if (string-match "\n\\(.*\\):\\([0-9]+\\):\\([0-9]+\\)" str)
      (let ((file (match-string 1 str))
            (line (+ 1 (string-to-number (match-string 2 str))))
            (col (string-to-number (match-string 3 str))))
        (find-file (match-string 1 str))
        (goto-char (fsharp-ac-line-column-to-pos line col)))
    (fsharp-ac-message-safely "Unable to find definition.")))

(defun fsharp-ac-handle-errors (str)
  "Display error overlays and set buffer-local error variables for error navigation."
  (fsharp-ac-clear-errors)
  (let ((errs (fsharp-ac-parse-errors
                 (concat (replace-regexp-in-string "DATA: errors\n" "" str) "\n")))
        )
    (setq fsharp-ac-errors errs)
    (mapc 'fsharp-ac/show-error-overlay errs)))

(defun fsharp-ac-handle-tooltip (str)
  "Display information from the background process. If the user
has requested a popup tooltip, display a popup. Otherwise,
display a short summary in the minibuffer."
  ;; Do not display if the current buffer is not an fsharp buffer.
  (when (equal major-mode 'fsharp-mode)
    (unless (or (active-minibuffer-window) cursor-in-echo-area)
      (let ((cleaned (replace-regexp-in-string "DATA: tooltip\n" "" str)))
        (if fsharp-ac-awaiting-tooltip
            (progn
              (setq fsharp-ac-awaiting-tooltip nil)
              (if fsharp-ac-use-popup
                  (fsharp-ac/show-popup cleaned)
                (fsharp-ac/show-info-window cleaned)))
          (fsharp-ac-message-safely (fsharp-doc/format-for-minibuffer cleaned)))))))

(defun fsharp-ac/show-popup (str)
  (if (display-graphic-p)
      (pos-tip-show str nil nil nil 300)
    ;; Use unoptimized calculation for popup, making it less likely to
    ;; wrap lines.
    (let ((popup-use-optimized-column-computation nil) )
      (popup-tip str))))

(defconst fsharp-ac-info-buffer-name "*fsharp info*")

(defun fsharp-ac/show-info-window (str)
  (save-excursion
    (let ((help-window-select t))
      (with-help-window fsharp-ac-info-buffer-name
        (princ str)))))

(defun fsharp-ac-handle-project (str)
  (setq fsharp-ac-project-files (cdr (split-string str "\n")))
  (fsharp-ac-parse-file (car (last fsharp-ac-project-files))))

(defun fsharp-ac-handle-process-error (str)
  (unless (s-matches? "Could not get type information" str)
    (fsharp-ac-message-safely str))
  (when (not (eq fsharp-ac-status 'idle))
    (setq fsharp-ac-status 'idle
          fsharp-ac-current-candidate nil
          fsharp-ac-current-candidate-help nil)))

(provide 'fsharp-mode-completion)

;;; fsharp-mode-completion.el ends here
