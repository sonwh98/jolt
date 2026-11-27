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
;;        sub-millisecond round-trip through utime's ns arguments (platform-
;;        branched FFI stat repair on darwin where stat:mtimensec is 0);
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
             (srfi srfi-1)
             (srfi srfi-8))

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
(define EAGAIN-VAL (or (false-if-exception EAGAIN) (if darwin? 35 11)))
(define EACCES-VAL (or (false-if-exception EACCES) 13))
(define AT-FDCWD (if darwin? -2 -100))

(define c-fcntl
  (foreign-library-function #f "fcntl"
                            #:return-type int
                            #:arg-types (list int int '*)
                            #:return-errno? #t))

;; struct flock bytevector (used only for the direct variadic EFAULT probe):
;;   - darwin-arm64: 24 bytes (off_t start@0, off_t len@8, pid_t@16, short type@20, short whence@22)
;;   - linux-x86_64: 32 bytes (short type@0, short whence@2, off_t start@8, off_t len@16, pid_t@24)
(define (make-flock type)
  (let ((bv (make-bytevector (if darwin? 24 32) 0)))
    (if darwin?
        (begin
          (bytevector-u64-native-set! bv 0 0)
          (bytevector-u64-native-set! bv 8 0)
          (bytevector-u16-native-set! bv 20 type)
          (bytevector-u16-native-set! bv 22 0))
        (begin
          (bytevector-u16-native-set! bv 0 type)
          (bytevector-u16-native-set! bv 2 0)
          (bytevector-u64-native-set! bv 8 0)
          (bytevector-u64-native-set! bv 16 0)
          (bytevector-s32-native-set! bv 24 0)))
    bv))

;; ---- child mode -------------------------------------------------------------
;; argv: w8-files.scm lock-child <file> <shim-lib>
;; The C shim constructs struct flock from <fcntl.h> directly (ABI-safe on
;; both darwin-arm64 and linux-x86_64) and returns errno at the boundary.
;; Exit 42 ONLY on lock-conflict (EAGAIN/EACCES), 0 on acquisition, 43 otherwise.
(define child-mode? (and (pair? script-args)
                         (string=? (car script-args) "lock-child")))
(when child-mode?
  (let* ((path (cadr script-args))
         (shim-path (caddr script-args))
         ;; O_RDWR: a write lock on an O_RDONLY fd is refused with EBADF
         ;; on darwin — recorded platform fact, so both sides open RDWR.
         (fd (open-fdes path (logior O_RDWR)))
         (shim-setlk
          (foreign-library-function (load-foreign-library shim-path)
                                    "w8_setlk"
                                    #:return-type int
                                    #:arg-types (list int int int64 int64)
                                    #:return-errno? #t)))
    (receive (rc err) (shim-setlk fd F-WRLCK 0 0)
      (close-fdes fd)
      (cond ((zero? rc) (exit 0))
            ((and (= rc -1) (or (= err EAGAIN-VAL) (= err EACCES-VAL)))
             (exit 42))
            (else
             (format #t "lock-child unexpected rc=~a errno=~a~%" rc err)
             (exit 43))))))

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
(define shim-lib
  (string-append tmpdir "/libw8shim." (if darwin? "dylib" "so")))
(call-with-output-file shim-src
  (lambda (p)
    (display "#include <fcntl.h>\n" p)
    (display "#include <string.h>\n" p)
    (display "int w8_setlk (int fd, int l_type, long long l_start, long long l_len) {\n" p)
    (display "  struct flock fl;\n" p)
    (display "  memset (&fl, 0, sizeof (fl));\n" p)
    (display "  fl.l_type = (short) l_type;\n" p)
    (display "  fl.l_whence = SEEK_SET;\n" p)
    (display "  fl.l_start = (off_t) l_start;\n" p)
    (display "  fl.l_len = (off_t) l_len;\n" p)
    (display "  return fcntl (fd, F_SETLK, &fl);\n" p)
    (display "}\n" p)))
(let ((rc (system* "cc" "-shared" "-fPIC" "-o" shim-lib shim-src)))
  (check "IO3a0 compiled the non-variadic fcntl shim (constructs struct flock \
from <fcntl.h>; variadic-direct calls EFAULT — recorded)"
         (zero? rc)))
(define shim-setlk
  (foreign-library-function (load-foreign-library shim-lib)
                            "w8_setlk"
                            #:return-type int
                            #:arg-types (list int int int64 int64)
                            #:return-errno? #t))
(define lock-file (string-append tmpdir "/locked"))
(call-with-output-file lock-file (lambda (p) (display "L" p)))
;; record the direct-variadic failure for the audit trail (O_RDWR so EBADF
;; cannot mask EFAULT; boundary-captured errno proves EFAULT = 14 on darwin-arm64)
(let ((fl (make-flock F-WRLCK))
      (fd (open-fdes lock-file O_RDWR)))
  (receive (direct-rc direct-err)
      (c-fcntl fd F-SETLK (bytevector->pointer fl))
    (close-fdes fd)
    (format #t "IO3a1 direct variadic fcntl F_SETLK (O_RDWR) => rc=~a errno=~a~%"
            direct-rc direct-err)
    (when darwin?
      (check "IO3a1 direct variadic fcntl F_SETLK fails EFAULT(14) on darwin-arm64"
             (and (= direct-rc -1) (= direct-err 14))))))
(define parent-fd (open-fdes lock-file O_RDWR))
(receive (locked lock-err) (shim-setlk parent-fd F-WRLCK 0 0)
  (format #t "IO3a parent F_SETLK via shim (whole-file write lock) => rc=~a errno=~a~%"
          locked lock-err)
  (check "IO3a parent acquired the whole-file write lock (F_SETLK => 0)"
         (= locked 0)))
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
(format #t "IO3b child under parent lock exit code = ~a (42 = EAGAIN/EACCES)~%"
        excluded-code)
(check "IO3b child process is EXCLUDED (EAGAIN/EACCES) while parent holds lock"
       (eqv? excluded-code 42))
(receive (unlocked unlock-err) (shim-setlk parent-fd F-UNLCK 0 0)
  (format #t "IO3c parent F_UNLCK via shim => rc=~a errno=~a~%"
          unlocked unlock-err)
  (check "IO3c parent unlock F_UNLCK succeeds (rc=0)" (= unlocked 0)))
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
;; RECORDED FINDING (darwin-arm64, Guile 3.0.11): utime's ns arguments DO
;; apply to the underlying inode (tv_nsec=456000000 observed via FFI stat),
;; while Guile's core stat:mtimensec answers 0 for EVERY file on darwin
;; (so sa-file-mtime-ms through core stat has SECOND resolution on darwin).
;; The repair is an FFI stat(2) reading signed time_t (s64) + tv_nsec:
;;   - darwin-arm64: st_mtimespec at offset 48 (tv_sec s64@48, tv_nsec s64@56)
;;   - linux-x86_64: st_mtim at offset 88 (tv_sec s64@88, tv_nsec s64@96)
(define c-stat
  (foreign-library-function #f "stat"
                            #:return-type int
                            #:arg-types (list '* '*)))
(define c-utimensat
  (foreign-library-function #f "utimensat"
                            #:return-type int
                            #:arg-types (list int '* '* int)
                            #:return-errno? #t))
(define (ffi-mtime-ms path)
  (let* ((buf (make-bytevector 144 0))     ; rooted across the call
         (rc (c-stat (string->pointer path) (bytevector->pointer buf)))
         (sec-off (if darwin? 48 88))
         (nsec-off (if darwin? 56 96)))
    (and (zero? rc)
         (+ (* (bytevector-s64-native-ref buf sec-off) 1000)
            (quotient (bytevector-s64-native-ref buf nsec-off) 1000000)))))
(define mt-file (string-append tmpdir "/mtime"))
(call-with-output-file mt-file (lambda (p) (display "m" p)))
(utime mt-file 1700000000 1700000000 0 456000000)
(let* ((st (stat mt-file))
       (core-ms (+ (* (stat:mtime st) 1000)
                   (quotient (stat:mtimensec st) 1000000)))
       (ffi-ms (ffi-mtime-ms mt-file)))
  (format #t "IO5 after utime(..., 456000000 ns): core stat mtime-ms=~a \
(nsec=~a); FFI stat mtime-ms=~a~%" core-ms (stat:mtimensec st) ffi-ms)
  (if darwin?
      (check "IO5a darwin core stat drops ns to 0 (second-resolution floor)"
             (and (= (stat:mtime st) 1700000000)
                  (= (stat:mtimensec st) 0)
                  (= core-ms 1700000000000)))
      (check "IO5a non-darwin core stat preserves utime ns (ms resolution)"
             (= core-ms 1700000000456)))
  (check "IO5b FFI stat recovers exact sub-second mtime from utime ns \
(1700000000456 ms)"
         (eqv? ffi-ms 1700000000456)))

;; IO5c pre-epoch signed time_t case (-10s + 250ms = -9750ms) via utimensat
(define mt-pre (string-append tmpdir "/mtime-pre"))
(call-with-output-file mt-pre (lambda (p) (display "p" p)))
(let ((ts (make-bytevector 32 0)))
  (bytevector-s64-native-set! ts 0 -10)
  (bytevector-s64-native-set! ts 8 250000000)
  (bytevector-s64-native-set! ts 16 -10)
  (bytevector-s64-native-set! ts 24 250000000)
  (receive (rc err)
      (c-utimensat AT-FDCWD (string->pointer mt-pre) (bytevector->pointer ts) 0)
    (let ((pre-ms (ffi-mtime-ms mt-pre)))
      (format #t "IO5c pre-epoch utimensat(-10s, 250ms) rc=~a err=~a => \
ffi-mtime-ms=~a (core stat:mtime=~a)~%"
              rc err pre-ms (stat:mtime (stat mt-pre)))
      (check "IO5c FFI stat reads signed time_t for pre-epoch mtime \
(-9750 ms)"
             (and (zero? rc) (eqv? pre-ms -9750))))))

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
