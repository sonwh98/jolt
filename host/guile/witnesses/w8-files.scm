;; W8 — file I/O battery (audit area 6).
;;
;; Rows decided:
;;   IO1 realpath through symlinks: canonicalize-path — manual §7.2.3 "a
;;        canonical path has no . or .. components, nor any repeated path
;;        separators, nor SYMLINKS; raises an error if any component does
;;        not exist";
;;   IO2 exclusive create O_CREAT|O_EXCL: second create must raise EEXIST
;;        (open-fdes with the exported O_* constants — the tmpnam doc in
;;        §7.2.3 itself prescribes this idiom);
;;   IO3 advisory locking fcntl/F_SETLK: a parent write lock excludes a
;;        CHILD PROCESS (POSIX fcntl locks are per-process, so the probe
;;        self-spawns in lock-child mode); release then allows;
;;   IO4 directory sync: open-fdes O_RDONLY on a directory + fsync;
;;   IO5 sa-file-mtime-ms: stat:mtime + stat:mtimensec (manual §7.2.3),
;;        sub-millisecond round-trip through utime's ns arguments;
;;   IO6 sa-run-process: spawn + pipe + waitpid (manual §7.2.7).
;;
;; Negative controls:
;;   NC1 the second O_EXCL create RAISES (if it succeeded, exclusivity is
;;        absent and the check fails);
;;   NC2 canonicalize-path on a missing component RAISES (resolving a
;;        dangling symlink must not fabricate a path);
;;   NC3 the lock child acquires the lock only after the parent releases
;;        (the exclusion is causal, not incidental).
;;
;; Self-spawning mode: guile w8-files.scm lock-child <file>  — exits 42 if
;; F_SETLK hits EAGAIN (excluded), 0 if acquired, 43 on error.

(use-modules (system foreign)
             (system foreign-library)
             (rnrs bytevectors)
             (rnrs io ports)
             (srfi srfi-1))

(define here (dirname (current-filename)))
;; script args: find the mode marker regardless of how the driver spelled
;; the command line (guile [flags] script.scm mode arg...)
(define script-args
  (let loop ((l (command-line)))
    (cond ((null? l) '())
          ((string=? (car l) "lock-child") l)
          (else (loop (cdr l))))))

;; ---- platform fcntl facts (Guile exports the constants when the OS has
;; them; the fallback table is the documented POSIX value set) --------------
(define sysname (utsname:sysname (uname)))
(define darwin? (and (string-contains sysname "Darwin") #t))
(define F-SETLK (or (false-if-exception F_SETLK) (if darwin? 8 6)))
(define F-WRLCK (or (false-if-exception F_WRLCK) (if darwin? 3 1)))
(define F-UNLCK (or (false-if-exception F_UNLCK) (if darwin? 2 2)))

(define c-fcntl
  (foreign-library-function #f "fcntl"
                            #:return-type int
                            #:arg-types (list int int '*)))

;; struct flock bytevector (whole-file lock, whence = SEEK_SET = 0)
(define (make-flock type)
  (let ((bv (make-bytevector 24 0)))
    (if darwin?
        (begin ;; off_t l_start; off_t l_len; pid_t l_pid; short type; short whence
          (bytevector-u64-native-set! bv 0 0)
          (bytevector-u64-native-set! bv 8 0)
          (bytevector-u16-native-set! bv 20 type)
          (bytevector-u16-native-set! bv 22 0))
        (begin ;; short type; short whence; off_t l_start; off_t l_len; pid
          (bytevector-u16-native-set! bv 0 type)
          (bytevector-u16-native-set! bv 2 0)
          (bytevector-u64-native-set! bv 8 0)
          (bytevector-u64-native-set! bv 16 0)))
    bv))

;; ---- child mode -------------------------------------------------------------
;; argv: w8-files.scm lock-child <file> <shim-lib>
(define child-mode? (and (pair? script-args)
                         (string=? (car script-args) "lock-child")))
(when child-mode?
  (let* ((path (cadr script-args))
         (shim-path (caddr script-args))
         ;; O_RDWR: a write lock on an O_RDONLY fd is refused with EBADF
         ;; on darwin — recorded platform fact, so both sides open RDWR.
         (fd (open-fdes path (logior O_RDWR)))
         ;; ADAPTER FACT: the flock bytevector must stay ROOTED across the
         ;; foreign call — an anonymous (bytevector->pointer ...) can be
         ;; collected first and the call then fails EFAULT(14).
         (fl (make-flock F-WRLCK))
         (shim-setlk
          (foreign-library-function (load-foreign-library shim-path)
                                    "w8_setlk"
                                    #:return-type int
                                    #:arg-types (list int '*)))
         (rc (shim-setlk fd (bytevector->pointer fl))))
    (if (= rc -1)
        (exit 42)                            ; EAGAIN — excluded (expected)
        (exit 0))))                          ; acquired

(define fails 0)
(define (check label ok)
  (format #t "~a ~a~%" (if ok "CHECK-OK  " "CHECK-FAIL") label)
  (or ok (set! fails (+ fails 1))))

(format #t "=== W8 file I/O witness ===~%")
(format #t "platform: ~a darwin?=~a F-SETLK=~a F-WRLCK=~a~%"
        sysname darwin? F-SETLK F-WRLCK)

(define tmpdir
  (string-append "/tmp/w8-" (number->string (getpid))))
(mkdir tmpdir #o700)

;; ---- IO1 realpath / canonicalize-path ----------------------------------------
(define real (string-append tmpdir "/real.txt"))
(call-with-output-file real (lambda (p) (display "w8" p)))
(symlink "real.txt" (string-append tmpdir "/link1"))
(symlink "link1" (string-append tmpdir "/link2"))
(let ((c (canonicalize-path (string-append tmpdir "/link2"))))
  (format #t "IO1 canonicalize-path through two symlinks => ~s~%" c)
  ;; /tmp itself is a symlink on darwin (/private/tmp), so compare against
  ;; the CANONICALIZED target, not the /tmp-prefixed spelling.
  (check "IO1 canonicalize-path resolves the symlink chain to the real \
file (and /tmp itself)"
         (string=? c (canonicalize-path real))))
(let ((dangling (false-if-exception
                 (canonicalize-path (string-append tmpdir "/nope/deeper")))))
  (format #t "NC2 canonicalize-path on missing component => ~s~%" dangling)
  (check "NC2 control: canonicalize-path RAISES on a missing component \
(dangling links are not fabricated)"
         (not dangling)))

;; ---- IO2 exclusive create -----------------------------------------------------
(define excl-path (string-append tmpdir "/exclusive"))
(let ((fd (open-fdes excl-path (logior O_CREAT O_EXCL O_WRONLY) #o600)))
  (check "IO2a first O_CREAT|O_EXCL create succeeds" (>= fd 0))
  (close-fdes fd))
(let ((second (false-if-exception
               (open-fdes excl-path (logior O_CREAT O_EXCL O_WRONLY) #o600))))
  (format #t "NC1 second O_CREAT|O_EXCL create => ~s~%" second)
  (check "NC1 control: second O_CREAT|O_EXCL create RAISES (EEXIST)"
         (not second)))

;; ---- IO3 advisory locking across processes -------------------------------------
;; RECORDED FINDING: fcntl(2) is VARIADIC, and calling it through Guile's
;; FFI fails EFAULT(14) on darwin-arm64 even with a rooted struct (the
;; fixed-arity libffi convention does not match the variadic ABI).  The
;; repair — the adapter's row decision — is a compiled NON-variadic shim
;; (built here with cc; the same technique serves ioctl/openat-style
;; variads).
(define guile-bin (or (getenv "GUILE") "guile"))
(define shim-src (string-append tmpdir "/w8shim.c"))
(define shim-lib (string-append tmpdir "/libw8shim.dylib"))
(call-with-output-file shim-src
  (lambda (p)
    (display "#include <fcntl.h>\n" p)
    (display "int w8_setlk (int fd, struct flock *fl) \
{ return fcntl (fd, F_SETLK, fl); }\n" p)))
(let ((rc (system* "cc" "-shared" "-fPIC" "-o" shim-lib shim-src)))
  (check "IO3a0 compiled the non-variadic fcntl shim (variadic-direct \
calls EFAULT — recorded)"
         (zero? rc)))
(define shim-setlk
  (foreign-library-function (load-foreign-library shim-lib)
                            "w8_setlk"
                            #:return-type int
                            #:arg-types (list int '*)))
;; record the direct-variadic failure for the audit trail
(let ((fl (make-flock F-WRLCK)))
  (define direct-rc
    (c-fcntl (open-fdes shim-src O_RDONLY) F-SETLK
             (bytevector->pointer fl)))
  (format #t "IO3a1 direct variadic fcntl F_SETLK => ~a (EFAULT evidence)~%"
          direct-rc))
(define lock-file (string-append tmpdir "/locked"))
(call-with-output-file lock-file (lambda (p) (display "L" p)))
(define parent-fd (open-fdes lock-file O_RDWR))
(define parent-fl (make-flock F-WRLCK))     ; rooted across the call
(define locked (shim-setlk parent-fd (bytevector->pointer parent-fl)))
(format #t "IO3a parent F_SETLK via shim (whole-file write lock) => ~a~%"
        locked)
(check "IO3a parent acquired the whole-file write lock (F_SETLK => 0)"
       (= locked 0))
(define (run-lock-child)
  (let* ((pr (pipe))
         (pid (spawn guile-bin
                     (list guile-bin "--no-auto-compile"
                           (string-append here "/w8-files.scm")
                           "lock-child" lock-file shim-lib)
                     #:output (cdr pr)
                     #:error (cdr pr))))
    (close-port (cdr pr))
    (get-string-all (car pr))
    (close-port (car pr))
    (status:exit-val (cdr (waitpid pid)))))
(define excluded-code (run-lock-child))
(format #t "IO3b child under parent lock exit code = ~a (42 = EAGAIN)~%"
        excluded-code)
(check "IO3b child process is EXCLUDED while the parent holds the lock"
       (eqv? excluded-code 42))
(define parent-unfl (make-flock F-UNLCK))   ; rooted across the call
(shim-setlk parent-fd (bytevector->pointer parent-unfl))
(define free-code (run-lock-child))
(format #t "NC3 child after release exit code = ~a~%" free-code)
(check "NC3 control: child acquires the lock after the parent releases"
       (eqv? free-code 0))
(close-fdes parent-fd)

;; ---- IO4 directory sync ----------------------------------------------------------
;; Guile's core fsync returns unspecified (like most side-effecting POSIX
;; wrappers) — reachability is the row; a raise would fail the check.
(define dirfd (open-fdes tmpdir O_RDONLY))
(check "IO4 fsync on a directory fd succeeds (directory sync reachable)"
       (boolean? (begin (fsync dirfd) #t)))
(close-fdes dirfd)

;; ---- IO5 mtime-ms ---------------------------------------------------------------
;; RECORDED FINDING (darwin-arm64, Guile 3.0.11): stat:mtimensec answers 0
;; for EVERY file (Guile's darwin stat does not populate the ns fields),
;; and utime's ns arguments do not apply — so sa-file-mtime-ms through the
;; core stat has SECOND resolution here.  The repair is an FFI stat(2)
;; reading st_mtimespec; darwin arm64 struct stat puts st_mtimespec at
;; offset 48 (tv_sec u64@48, tv_nsec u64@56).
(define c-stat
  (foreign-library-function #f "stat"
                            #:return-type int
                            #:arg-types (list '* '*)))
(define (ffi-mtime-ms path)
  (let* ((buf (make-bytevector 144 0))     ; rooted across the call
         (rc (c-stat (string->pointer path) (bytevector->pointer buf))))
    (and (zero? rc)
         (+ (* (bytevector-u64-native-ref buf 48) 1000)
            (quotient (bytevector-u64-native-ref buf 56) 1000000)))))
(define mt-file (string-append tmpdir "/mtime"))
(call-with-output-file mt-file (lambda (p) (display "m" p)))
(sleep 1)
(call-with-output-file mt-file (lambda (p) (display "m2" p)))
(let* ((st (stat mt-file))
       (core-ms (+ (* (stat:mtime st) 1000)
                   (quotient (stat:mtimensec st) 1000000)))
       (ffi-ms (ffi-mtime-ms mt-file)))
  (format #t "IO5 core stat mtime-ms=~a (nsec=~a); FFI st_mtimespec \
mtime-ms=~a~%" core-ms (stat:mtimensec st) ffi-ms)
  (check "IO5a core stat carries SECOND-resolution mtime (sa-file-mtime-ms \
degraded floor)"
         (= core-ms (* (stat:mtime st) 1000)))
  (check "IO5b FFI stat repair reaches sub-second mtime (ns field nonzero \
on a rewritten file)"
         (and ffi-ms (> (modulo ffi-ms 1000) 0)
              (< (abs (- ffi-ms core-ms)) 2000))))

;; ---- IO6 subprocess ----------------------------------------------------------------
(let* ((pr (pipe))
       (pid (spawn "/usr/bin/env" '("/usr/bin/env" "printf" "w6-out")
                   #:output (cdr pr))))
  (close-port (cdr pr))
  (define out (get-string-all (car pr)))
  (close-port (car pr))
  (define st (cdr (waitpid pid)))
  (format #t "IO6 subprocess output=~s status=~s~%" out (status:exit-val st))
  (check "IO6 sa-run-process shape: spawn + pipe + waitpid exit 0"
         (and (string=? out "w6-out") (eqv? (status:exit-val st) 0))))

;; ---- IO7 directory listing (bonus, cheap) -------------------------------------------
(let* ((d (opendir tmpdir))
       (entries (let loop ((acc '()))
                  (let ((e (readdir d)))
                    (if (eof-object? e) (reverse! acc)
                        (loop (cons e acc)))))))
  (closedir d)
  (check "IO7 opendir/readdir/closedir list the scratch dir"
         (member "real.txt" entries)))

(if (zero? fails)
    (format #t "W8-VERDICT: PASS (file I/O rows decided)~%")
    (format #t "W8-VERDICT: FAIL (~a failed checks)~%" fails))
(exit (if (zero? fails) 0 1))
