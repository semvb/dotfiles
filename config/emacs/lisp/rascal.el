;;; rascal.el --- Rascal support for Emacs via the official Rascal language server  -*- lexical-binding: t; -*-

;; Gives Emacs roughly what the VS Code "rascalmpl" extension gives:
;;   - `rascal-mode' for .rsc files (basic highlighting even without the server)
;;   - Eglot hooked up to the Rascal LSP server: live parse errors and
;;     type-checker errors/warnings (Flymake), hover, go-to-definition,
;;     rename, outline (imenu), formatting, code lenses / code actions
;;   - `rascal-repl' to open a Rascal terminal in the current project, and
;;     `rascal-repl-import-module' to import the module you are editing.
;;
;; SETUP
;;   1. Java 11 or newer on your PATH (`java -version`).
;;   2. Get the two jars the VS Code extension ships with:
;;        rascal-lsp.jar  and  rascal.jar
;;      They live in the extension's  extension/assets/jars/  folder.
;;      A .vsix is just a zip: download it from the VS Code Marketplace
;;      ("Download Extension") or open-vsx.org, then
;;        unzip usethesource.rascalmpl-*.vsix 'extension/assets/jars/*' -d /tmp/rascal
;;        mkdir -p ~/.local/share/rascal && cp /tmp/rascal/extension/assets/jars/*.jar ~/.local/share/rascal/
;;      (If VS Code with the extension is installed, they are already in
;;       ~/.vscode/extensions/usethesource.rascalmpl-<version>/assets/jars/ .)
;;   3. Put this file somewhere on your load-path and add to init.el:
;;        (require 'rascal)
;;        (setq rascal-jar-directory "~/.local/share/rascal/")
;;
;; A Rascal project root is the folder containing META-INF/RASCAL.MF.
;; This file teaches project.el to recognise it, so Eglot (workspace
;; folder) and the REPL (working directory) both use that folder; no git
;; repo or other marker file is needed.

;;; Code:

(require 'eglot)
(require 'project)
(require 'term)
(declare-function eat-make "eat")
(declare-function eat-semi-char-mode "eat")
(declare-function eat-term-send-string "eat")
(defvar eat-terminal)

(defgroup rascal nil
  "Rascal meta-programming language support."
  :group 'languages
  :prefix "rascal-")

(defcustom rascal-jar-directory "~/.local/share/rascal/"
  "Directory holding rascal-lsp.jar and rascal.jar."
  :type 'directory)

(defcustom rascal-java-program "java"
  "Java executable used for the language server and the REPL."
  :type 'string)

(defcustom rascal-lsp-max-heap "2500M"
  "Maximum JVM heap (-Xmx) for the language server."
  :type 'string)

(defcustom rascal-repl-max-heap "2500M"
  "Maximum JVM heap (-Xmx) for the Rascal REPL."
  :type 'string)

(defcustom rascal-lsp-log-level "INFO"
  "Log level of the language server (shown in the Eglot events buffer)."
  :type '(choice (const "ERROR") (const "WARN") (const "INFO") (const "DEBUG")))

(defcustom rascal-indent-offset 4
  "Indentation step for `rascal-mode'."
  :type 'integer)

;;;; Jars

(defun rascal--jar (name)
  "Absolute path of jar NAME in `rascal-jar-directory', or signal an error."
  (let ((file (expand-file-name name rascal-jar-directory)))
    (unless (file-exists-p file)
      (user-error "Rascal: %s not found; set `rascal-jar-directory' (see setup in rascal.el)" file))
    file))

(defun rascal--classpath ()
  (mapconcat #'identity
             (list (rascal--jar "rascal-lsp.jar") (rascal--jar "rascal.jar"))
             path-separator))

;;;; Major mode

(defconst rascal--keywords
  '("module" "import" "extend" "syntax" "lexical" "layout" "keyword" "start"
    "data" "alias" "anno" "public" "private" "default" "java" "test" "tag"
    "if" "else" "for" "while" "do" "switch" "case" "return" "fail" "break"
    "continue" "throw" "throws" "try" "catch" "finally" "insert" "append"
    "visit" "top-down" "bottom-up" "top-down-break" "bottom-up-break"
    "innermost" "outermost" "solve" "assert" "in" "notin" "is" "has" "mod"
    "it" "any" "all" "one" "filter" "dynamic" "bracket" "non-assoc" "assoc"
    "left" "right" "when" "o" "new" "renaming" "variable" "function"))

(defconst rascal--types
  '("bool" "int" "real" "rat" "num" "str" "loc" "datetime" "list" "set" "map"
    "rel" "lrel" "tuple" "node" "value" "void" "type" "bag" "Tree" "Symbol"))

(defconst rascal-font-lock-keywords
  `((,(concat "\\_<" (regexp-opt rascal--keywords) "\\_>") . font-lock-keyword-face)
    (,(concat "\\_<" (regexp-opt rascal--types) "\\_>") . font-lock-type-face)
    ("\\_<\\(true\\|false\\)\\_>" . font-lock-constant-face)
    ("^\\s-*\\(?:module\\|import\\|extend\\)\\s-+\\([[:alnum:]_:]+\\)" 1 font-lock-constant-face)
    ("\\_<\\(?:syntax\\|lexical\\|layout\\|keyword\\|data\\|alias\\)\\s-+\\([[:alnum:]_]+\\)"
     1 font-lock-type-face)
    ("\\_<\\([[:alpha:]_][[:alnum:]_]*\\)\\s-*(" 1 font-lock-function-name-face)
    ("@[[:alnum:]_]+" . font-lock-preprocessor-face)
    ("|[^|\n]*|" . font-lock-string-face))
  "Fallback highlighting; the language server adds semantic highlighting on top.")

(defvar rascal-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?/ ". 124b" st)
    (modify-syntax-entry ?* ". 23" st)
    (modify-syntax-entry ?\n "> b" st)
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?\\ "\\" st)
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?' "." st)
    (modify-syntax-entry ?< "." st)
    (modify-syntax-entry ?> "." st)
    st)
  "Syntax table for `rascal-mode'.")

(defun rascal-indent-line ()
  "Indent current line by brace/paren depth."
  (interactive)
  (let* ((depth (save-excursion
                  (beginning-of-line)
                  (car (syntax-ppss))))
         (closing (save-excursion
                    (back-to-indentation)
                    (looking-at-p "[]})]")))
         (target (* rascal-indent-offset (max 0 (if closing (1- depth) depth))))
         (offset (- (current-column) (current-indentation))))
    (indent-line-to target)
    (when (> offset 0) (forward-char offset))))

(defvar rascal-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'rascal-repl)
    (define-key map (kbd "C-c C-l") #'rascal-repl-import-module)
    map)
  "Keymap for `rascal-mode'.")

;;;###autoload
(define-derived-mode rascal-mode prog-mode "Rascal"
  "Major mode for the Rascal meta-programming language."
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "//+\\s-*")
  (setq-local font-lock-defaults '(rascal-font-lock-keywords))
  (setq-local indent-line-function #'rascal-indent-line)
  (setq-local electric-indent-chars (append "{}()" electric-indent-chars)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.rsc\\'" . rascal-mode))

;;;; Language server (Eglot)

(defun rascal--server-command (&optional _interactive)
  "Command line that starts the Rascal language server over stdio.
Mirrors what the VS Code extension runs."
  (let ((cp (rascal--classpath)))
    (list rascal-java-program
          "-Dlog4j2.configurationFactory=org.rascalmpl.vscode.lsp.log.LogJsonConfiguration"
          (concat "-Dlog4j2.level=" rascal-lsp-log-level)
          "-Drascal.lsp.deploy=true"
          (concat "-Drascal.compilerClasspath=" cp)
          (concat "-Xmx" rascal-lsp-max-heap)
          "-cp" cp
          "org.rascalmpl.vscode.lsp.rascal.RascalLanguageServer")))

(add-to-list 'eglot-server-programs '(rascal-mode . rascal--server-command))

;; The JVM + type checker take a while to start on first use.
(add-hook 'rascal-mode-hook
          (lambda () (setq-local eglot-connect-timeout 120)))

(add-hook 'rascal-mode-hook #'eglot-ensure)

;;;; Project root

(defun rascal-project-find (dir)
  "Return a project for the Rascal project containing DIR, or nil.
A Rascal project root is the nearest folder with META-INF/RASCAL.MF."
  (when-let* ((root (locate-dominating-file dir "META-INF/RASCAL.MF")))
    (cons 'transient (expand-file-name root))))

;; Checked before the default git/VC lookup, so a Rascal project inside a
;; bigger git repo (e.g. one course repo with several assignments) still
;; gets its own root.
(add-hook 'project-find-functions #'rascal-project-find)

;;;; REPL

(defun rascal--project-root ()
  (if-let* ((proj (project-current)))
      (expand-file-name (project-root proj))
    default-directory))

(defun rascal--repl-buffer-name (root)
  (format "rascal: %s" (file-name-nondirectory (directory-file-name root))))

(defcustom rascal-repl-terminal (if (require 'eat nil t) 'eat 'term)
  "Terminal emulator for the Rascal REPL.
`eat' (install with M-x package-install RET eat) leaves C-x, M-x,
C-c and C-h to Emacs and sends everything else, including M-DEL,
to the REPL.  `term' is built in; there C-x is the prefix for normal
Emacs commands (C-x o, C-x b, ...) and C-x C-j switches to line mode."
  :type '(choice (const eat) (const term)))

(defun rascal--repl-command ()
  (list rascal-java-program
        (concat "-Xmx" rascal-repl-max-heap)
        "-Dfile.encoding=UTF8"
        "-cp" (rascal--jar "rascal.jar")
        "org.rascalmpl.shell.RascalShell"))

(defun rascal--repl-start (name)
  "Start the REPL in buffer *NAME* and return that buffer."
  (let ((cmd (rascal--repl-command)))
    (pcase rascal-repl-terminal
      ('eat
       (require 'eat)
       (let ((buf (apply #'eat-make name (car cmd) nil (cdr cmd))))
         (with-current-buffer buf (eat-semi-char-mode))
         buf))
      (_
       (let ((buf (apply #'make-term name (car cmd) nil (cdr cmd))))
         (with-current-buffer buf
           (term-mode)
           (term-char-mode)
           ;; Like `ansi-term': C-x reaches Emacs instead of the REPL.
           (term-set-escape-char ?\C-x))
         buf)))))

(defun rascal--repl-send (string)
  "Send STRING to the REPL in the current buffer, as if typed."
  (if (derived-mode-p 'eat-mode)
      (eat-term-send-string eat-terminal string)
    (term-send-raw-string string)))

(defun rascal-repl ()
  "Open (or switch to) a Rascal REPL for the current project.
Started in the project root, so the REPL picks up the project's
pom.xml / RASCAL.MF just like the VS Code \"Rascal terminal\"."
  (interactive)
  (let* ((root (rascal--project-root))
         (name (rascal--repl-buffer-name root))
         (buf (get-buffer (concat "*" name "*"))))
    (unless (and buf (get-buffer-process buf))
      (when buf (kill-buffer buf))
      (let ((default-directory root))
        (setq buf (rascal--repl-start name))))
    (pop-to-buffer buf)
    buf))

;; Wait for the first prompt so a just-started REPL doesn't drop our input.
(defun rascal--wait-for-prompt (&optional timeout)
  (let ((deadline (+ (float-time) (or timeout 60)))
        (proc (get-buffer-process (current-buffer))))
    (while (and (process-live-p proc)
                (< (float-time) deadline)
                (not (save-excursion
                       (goto-char (point-min))
                       (search-forward "rascal>" nil t))))
      (accept-process-output proc 0.2))))

(defun rascal--current-module ()
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^\\s-*module\\s-+\\([[:alnum:]_:\\\\]+\\)" nil t)
      (match-string-no-properties 1))))

(defun rascal-repl-import-module (&optional run-main)
  "Import the current module in the project's Rascal REPL.
With prefix argument RUN-MAIN, also call main()."
  (interactive "P")
  (let ((module (or (rascal--current-module)
                    (user-error "No `module' declaration in this buffer"))))
    (when (buffer-modified-p) (save-buffer))
    (with-current-buffer (rascal-repl)
      (rascal--wait-for-prompt)
      (rascal--repl-send (format "import %s;\r" module))
      (when run-main
        (rascal--repl-send "main();\r")))))

(provide 'rascal)
