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
(require 'seq)
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
    ("@[[:alnum:]_]+" . font-lock-preprocessor-face))
  "Fallback highlighting; the language server adds semantic highlighting on top.
Location literals |...| and regex literals /.../ are highlighted as
strings by `rascal-syntax-propertize'.")

;; Location literals (|project://x/|) and regex literals (/a*b/) contain
;; characters the syntax table would misread: "//" starts a comment and a
;; quote starts a string.  Marking their delimiters as string fences makes
;; Emacs treat each literal as one string.
(defconst rascal--literal-re
  (concat
   ;; Group 1: a location, |scheme:/...|
   "\\(|[[:alpha:]][[:alnum:]+.-]*:/[^|\n]*|\\)"
   "\\|"
   ;; Group 2: a regex, /.../, after ( , = : ! { [ & | ? or `case'/`return'.
   ;; A division never follows those; "//" and "/*" start comments.
   "\\(?:[(,=:!{[&|?]\\|\\_<\\(?:case\\|return\\)\\)[ \t]*"
   "\\(/\\(?:[^/*\\\n]\\|\\\\.\\)\\(?:[^/\\\n]\\|\\\\.\\)*/\\)")
  "Matches a Rascal location literal (group 1) or regex literal (group 2).")

(defun rascal-syntax-propertize (start end)
  "Mark location and regex literals between START and END as strings."
  (goto-char start)
  (while (re-search-forward rascal--literal-re end t)
    (let ((beg (or (match-beginning 1) (match-beginning 2)))
          (stop (or (match-end 1) (match-end 2))))
      (if (nth 8 (save-excursion (syntax-ppss beg)))
          ;; Already inside a comment or string: not a literal.
          (goto-char (1+ beg))
        (put-text-property beg (1+ beg) 'syntax-table (string-to-syntax "|"))
        (put-text-property (1- stop) stop 'syntax-table (string-to-syntax "|"))
        (goto-char stop)))))

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
  (setq-local syntax-propertize-function #'rascal-syntax-propertize)
  (setq-local indent-line-function #'rascal-indent-line)
  (setq-local electric-indent-chars (append "{}()" electric-indent-chars)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.rsc\\'" . rascal-mode))

;;;; Language server (Eglot)

(defconst rascal--fallback-resolver-class
  "org.rascalmpl.vscode.lsp.uri.FallbackResolver"
  "Class that older rascal-lsp versions (e.g. 0.13.x) must be told about.")

(defvar rascal--fallback-resolver-cache nil
  "Cons (JAR-MTIME . BOOL): whether rascal-lsp.jar has the fallback resolver.")

(defun rascal--jar-has-fallback-resolver-p (jar)
  "Non-nil if JAR contains `rascal--fallback-resolver-class'.
Zip files store entry names uncompressed, so a plain byte search works."
  (let ((mtime (file-attribute-modification-time (file-attributes jar))))
    (unless (equal (car rascal--fallback-resolver-cache) mtime)
      (setq rascal--fallback-resolver-cache
            (cons mtime
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally jar)
                    (and (search-forward
                          (concat (subst-char-in-string
                                   ?. ?/ rascal--fallback-resolver-class)
                                  ".class")
                          nil t)
                         t)))))
    (cdr rascal--fallback-resolver-cache)))

(defun rascal--server-command (&optional _interactive)
  "Command line that starts the Rascal language server over stdio.
Mirrors what the VS Code extension runs."
  (let ((cp (rascal--classpath))
        (lsp-jar (rascal--jar "rascal-lsp.jar")))
    (append
     (list rascal-java-program
           "-Dlog4j2.configurationFactory=org.rascalmpl.vscode.lsp.log.LogJsonConfiguration"
           (concat "-Dlog4j2.level=" rascal-lsp-log-level)
           "-Drascal.lsp.deploy=true"
           ;; Rascal reads its own library modules from the jar with Java's
           ;; default charset.  On Java < 18 that follows the locale; without
           ;; a UTF-8 locale the Rascal grammar fails to load and every
           ;; module depending on it reports "Undeclared ..." errors.
           "-Dfile.encoding=UTF-8")
     ;; Versions that ship this class (e.g. 0.13.5) crash at startup
     ;; without the flag; newer versions removed it and must not get it.
     (when (rascal--jar-has-fallback-resolver-p lsp-jar)
       (list (concat "-Drascal.fallbackResolver=" rascal--fallback-resolver-class)))
     (list (concat "-Drascal.compilerClasspath=" cp)
           (concat "-Xmx" rascal-lsp-max-heap)
           "-cp" cp
           "org.rascalmpl.vscode.lsp.rascal.RascalLanguageServer"))))

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

;;;;; Workspace folders: |project://NAME/| for folders other than the project

(defcustom rascal-repl-workspace-folders nil
  "Folders the REPL makes available as |project://NAME/|.
This is the Emacs version of adding folders to the VS Code workspace.
Each entry is either a folder, which gets its own name as NAME, or a
cons (NAME . FOLDER) to choose the name.  Relative folders are relative
to the Rascal project root.  Best set per project in a .dir-locals.el
file in the project root, for example:

  ((rascal-mode . ((rascal-repl-workspace-folders
                    . ((\"smallsql\" . \"smallsql0.21_src\")
                       \"hsqldb-2.3.1\")))))

The folder contents are indexed when the REPL starts, so for files
added later, start a new REPL."
  :type '(repeat (choice directory (cons string directory)))
  :safe (lambda (v)
          (and (listp v)
               (seq-every-p (lambda (e)
                              (or (stringp e)
                                  (and (consp e) (stringp (car e))
                                       (stringp (cdr e)))))
                            v))))

;; The plain REPL only knows |project://| for its own project.  These
;; helpers map every file and folder under a physical folder to
;; |project://NAME/...| with IO::registerLocations.  That does exact
;; lookups, so each path gets its own entry (folders with and without a
;; trailing slash).
(defconst rascal--repl-register-helpers
  '("import IO;"
    "map[loc,loc] rascalElWalk(loc p, loc l) { map[loc,loc] m = (l : p); if (isDirectory(p)) { m[l[path = l.path + \"/\"]] = p; for (str e <- listEntries(p)) m += rascalElWalk(p + e, l + e); } return m; }"
    "void rascalElRegister(str name, loc root) { map[loc,loc] m = rascalElWalk(root, |project://<name>/|); m[|project://<name>|] = root; registerLocations(\"project\", name, m); }")
  "Rascal definitions sent to the REPL, one command per line.")

(defun rascal--file-loc (dir)
  "Rascal |file:///...| literal for directory DIR."
  (format "|file://%s|"
          (replace-regexp-in-string
           " " "%20" (directory-file-name (expand-file-name dir)) t t)))

(defun rascal--repl-register-folders (root folders)
  "In the current REPL buffer, register FOLDERS (relative to ROOT)."
  (when folders
    (dolist (line rascal--repl-register-helpers)
      (rascal--repl-send (concat line "\r")))
    (dolist (entry folders)
      (let* ((dir (expand-file-name (if (consp entry) (cdr entry) entry) root))
             (name (if (consp entry)
                       (car entry)
                     (file-name-nondirectory (directory-file-name dir)))))
        (if (not (file-directory-p dir))
            (message "Rascal: workspace folder %s does not exist" dir)
          (rascal--repl-send
           (format "rascalElRegister(\"%s\", %s);\r"
                   name (rascal--file-loc dir))))))))

;;;;; Starting the REPL

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

(defun rascal-repl ()
  "Open (or switch to) a Rascal REPL for the current project.
Started in the project root, so the REPL picks up the project's
pom.xml / RASCAL.MF just like the VS Code \"Rascal terminal\".
Folders in `rascal-repl-workspace-folders' become |project://NAME/|."
  (interactive)
  (let* ((root (rascal--project-root))
         (folders rascal-repl-workspace-folders) ; read before switching buffer
         (name (rascal--repl-buffer-name root))
         (buf (get-buffer (concat "*" name "*"))))
    (unless (and buf (get-buffer-process buf))
      (when buf (kill-buffer buf))
      (let ((default-directory root))
        (setq buf (rascal--repl-start name)))
      (when folders
        (with-current-buffer buf
          (message "Rascal: starting REPL and registering workspace folders...")
          (rascal--wait-for-prompt)
          (rascal--repl-register-folders root folders))))
    (pop-to-buffer buf)
    buf))

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
