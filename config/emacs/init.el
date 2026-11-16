;; -*- lexical-binding: t; -*-
;; Package management
(require 'package)

(add-to-list 'package-archives
             '("melpa" . "https://melpa.org/packages/") t)

(package-initialize)

;; Custom file
(setq custom-file "~/.config/emacs/custom.el")


;; Helper configurations
(load "~/.config/emacs/.emacs.rc/rc.el")
(load "~/.config/emacs/.emacs.rc/misc-rc.el")


;; Theme
(add-to-list 'custom-theme-load-path
             "~/.config/emacs/themes/")

(rc/require-theme 'gruber-darker)


;; Backup files
(setq backup-directory-alist `(("." . "~/.saves")))
(setq delete-old-versions t
      kept-new-versions 2
      kept-old-versions 2)


;; Appearance
(tool-bar-mode 0)
(menu-bar-mode 0)
(scroll-bar-mode 0)

(global-display-line-numbers-mode 1)
(setq display-line-numbers-type 'relative)

(show-paren-mode 1)
(electric-pair-mode 1)

(setq auto-save-default t)

(setq vc-follow-symlinks t)


;; Scrolling
(pixel-scroll-precision-mode 1)
(setq mouse-wheel-progressive-speed nil
      scroll-conservatively 101
      scroll-margin 0
      make-cursor-line-fully-visible nil)


;; Startup
(setq inhibit-startup-screen t)
(set-face-attribute 'default nil :height 160)


;; Zoom
(global-set-key (kbd "C-}") 'text-scale-increase)
(global-set-key (kbd "C-{") 'text-scale-decrease)


;; Whitespaces

;;; Display white spaces
(setq whitespace-style '(face tabs spaces space-mark tab-mark))
(setq whitespace-display-mappings
      '((space-mark 32 [183] [46])  ; 183 is a mid-dot (·), 46 is a fallback (.)
        (tab-mark 9 [187 9] [92 9])))  ; 187 (») for tabs

(global-whitespace-mode 1)

;;; Delete trailing white spaces
(add-hook 'before-save-hook 'delete-trailing-whitespace)


;; Marking
;; C-g with an active region: go back to where the cursor was when the region started
(defvar-local my/region-origin nil
  "Marker at the position the cursor had when the region was activated.")
(defvar-local my/pre-command-point nil)

(defun my/record-pre-command-point ()
  (unless (region-active-p)
    (setq my/pre-command-point (point))))
(add-hook 'pre-command-hook #'my/record-pre-command-point)

(defun my/save-region-origin ()
  (setq my/region-origin (copy-marker (or my/pre-command-point (point)))))
(add-hook 'activate-mark-hook #'my/save-region-origin)

(defun my/return-to-region-origin (&rest _)
  (when (and (region-active-p)
             (markerp my/region-origin)
             (eq (marker-buffer my/region-origin) (current-buffer)))
    (goto-char my/region-origin)))
(advice-add 'keyboard-quit :before #'my/return-to-region-origin)


;; Pasting/copying

;;; Paste over current selected text
(delete-selection-mode 1)

;;; Copy the current line
(defun copy-current-line ()
  (interactive)
  (let ((current-line (thing-at-point 'line t)))
    (kill-new current-line)
    (message "Line copied: %s" current-line)))

(global-set-key (kbd "C-c l") 'copy-current-line)

;;; Deletion without affecting clipboard
(defun my/delete-backward-word ()
  "Delete the previous word without adding it to the kill ring."
  (interactive)
  (delete-region
   (point)
   (progn
     (backward-word)
     (point))))

(defun my/delete-forward-word ()
  "Delete the next word without adding it to the kill ring."
  (interactive)
  (delete-region
   (point)
   (progn
     (forward-word)
     (point))))

(defun my/delete-forward-char ()
  "Delete the next character without adding it to the kill ring."
  (interactive)
  (delete-char 1))


(global-set-key (kbd "C-<backspace>") #'my/delete-backward-word)
(global-set-key (kbd "C-d") #'my/delete-forward-char)
(global-set-key (kbd "M-<backspace>") #'my/delete-backward-word)
(global-set-key (kbd "M-d") #'my/delete-forward-word)

(defun my/kill-ring-save-keep-region (beg end)
  "Copy the region but keep it active."
  (interactive "r")
  (let ((deactivate-mark nil))
    (kill-ring-save beg end))
  (setq deactivate-mark nil)
  (setq mark-active t))

(global-set-key (kbd "M-w") #'my/kill-ring-save-keep-region)


;; Indentation
(setq-default indent-tabs-mode nil)
(setq-default tab-width 4)

;;; Ensure all programming modes use spaces
(add-hook 'prog-mode-hook
          (lambda ()
            (setq indent-tabs-mode nil)))

;;; Keep electric-indent-mode enabled for auto-indentation
(electric-indent-mode 1)
(setq electric-pair-open-newline-between-pairs t)


;; Dired
(setq delete-by-moving-to-trash t)

;;; Open pdf in browser
(defun my/dired-open-file ()
  "Open PDFs externally, otherwise use the normal Dired behavior."
  (interactive)
  (let* ((file (dired-get-file-for-visit))
         (extension (file-name-extension file)))
    (if (and extension
             (string-equal (downcase extension) "pdf"))
        (start-process "pdf-browser" nil "xdg-open" file)
      (dired-find-file))))

(setq dired-dwim-target t)

(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "RET") #'my/dired-open-file))


;; Ido
(ido-mode 1)
(ido-everywhere 1)


;;; Company
(rc/require 'company)
(require 'company)

(global-company-mode)


;; C/C++-mode
(setq c-basic-offset 4)

(add-hook 'c-mode-hook #'eglot-ensure)
(add-hook 'c++-mode-hook #'eglot-ensure)


;; Pyenv
(rc/require 'pyvenv)
(pyvenv-mode t)

;; Set correct Python
(setq pyvenv-post-activate-hooks
      (list (lambda ()
              (setq python-shell-interpreter (concat pyvenv-virtual-env "bin/python3")))))
(setq pyvenv-post-deactivate-hooks
      (list (lambda ()
              (setq python-shell-interpreter "python3"))))


;; Haskell
(rc/require 'haskell-mode)

(add-hook 'haskell-mode-hook #'eglot-ensure)

(defun my/haskell-run ()
  "Run the current Haskell file with runghc."
  (interactive)
  (compile
   (format "runghc %s"
           (shell-quote-argument buffer-file-name))))

;;(add-hook 'haskell-mode-hook
;;          (lambda ()
;;            (local-set-key (kbd "C-c C-r") #'my/haskell-run)))
(add-hook 'haskell-mode-hook
          (lambda ()
            (local-set-key (kbd "C-c C-r")
                           #'haskell-process-load-file)))


;; Move text
(rc/require 'move-text)
(global-set-key (kbd "M-p") 'move-text-up)
(global-set-key (kbd "M-n") 'move-text-down)


;; Magit
(rc/require 'magit)
(setq magit-auto-revert-mode nil)

(global-set-key (kbd "C-c m s") 'magit-status)
(global-set-key (kbd "C-c m l") 'magit-log)


;; Multiple cursors
(rc/require 'multiple-cursors)

(global-set-key (kbd "C-S-c C-S-c") 'mc/edit-lines)
(global-set-key (kbd "C->")         'mc/mark-next-like-this)
(global-set-key (kbd "C-<")         'mc/mark-previous-like-this)
(global-set-key (kbd "C-c C-<")     'mc/mark-all-like-this)
(global-set-key (kbd "C-\"")        'mc/skip-to-next-like-this)
(global-set-key (kbd "C-:")         'mc/skip-to-previous-like-this)


;; Compilation
(global-set-key (kbd "C-c C-c") 'compile)

;;; Override "C-c C-c" in c-mode
(with-eval-after-load 'cc-mode
  (define-key c-mode-base-map (kbd "C-c C-c") 'compile))

(setq compile-command "")

(add-to-list 'display-buffer-alist
             '("\\*compilation\\*"
               (display-buffer-reuse-window display-buffer-below-selected)
               (window-height . 0.4)))

(setq compilation-scroll-output 'first-error)

;;; Focus on compilation buffer is compilation threw errors (warnings are ignored)
(defun my-switch-to-compilation-buffer-on-failure (buffer string)
  (when (and (string-match ".*exited abnormally.*" string)
             (not (string-match ".*-warnings.*" string)))
    (switch-to-buffer-other-window buffer)))

(add-hook 'compilation-finish-functions 'my-switch-to-compilation-buffer-on-failure)


;; Markdown
(rc/require 'markdown-mode)
(rc/require 'markdown-preview-mode)


;; Rascal
(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))
(require 'rascal)
(let ((java11 "/usr/lib/jvm/java-11-temurin/bin/java"))
  (when (file-executable-p java11)
    (setq rascal-java-program java11)))
(setq rascal-jar-directory "~/.local/share/rascal/")


;; eat terminal
(rc/require 'eat)

(load-file custom-file)
