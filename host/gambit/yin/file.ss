;; Native Gambit ports back Yin's regular files. Only operations for which
;; they have no equivalent go through the private file worker.

(define (gambit-yin-absolute-path path)
  (when (memv #\nul (string->list path))
    (error "NUL in file path" path))
  (if (and (> (string-length path) 0) (char=? (string-ref path 0) #\/))
      path
      (string-append (current-directory) path)))

(define (gambit-yin-file-info path follow?)
  (with-exception-catcher
    (lambda (e)
      (if (no-such-file-or-directory-exception? e) #f (raise e)))
    (lambda () (file-info path follow?))))

(define (gambit-yin-file-kind path follow?)
  (let ((info (gambit-yin-file-info path follow?)))
    (if info (file-info-type info) 'absent)))

(define (gambit-yin-classify path follow?)
  (keyword #f
    (case (gambit-yin-file-kind (gambit-yin-absolute-path path) (jolt-truthy? follow?))
      ((regular) "regular") ((directory) "directory") ((fifo) "fifo")
      ((symbolic-link) "symlink") ((absent) "absent") (else "other"))))

(define (gambit-yin-mkdirs path)
  (case (gambit-yin-file-kind path #t)
    ((directory) #f)
    ((absent)
     (gambit-yin-mkdirs (path-directory (path-strip-trailing-directory-separator path)))
     (with-exception-catcher
       (lambda (e)
         (if (and (file-exists-exception? e)
                  (eq? (gambit-yin-file-kind path #t) 'directory))
             #f
             (raise e)))
       (lambda () (create-directory path) #t)))
    (else (error "Not a directory" path))))

(define (gambit-yin-realpath path)
  (let ((path (gambit-yin-absolute-path path)))
    ;; Lexical, not realpath(3): Gambit exposes no readlink port on this
    ;; target, so a symlinked directory keeps its given spelling. The lock
    ;; seam below makes that honest for ownership — it keys its in-process
    ;; hold table by the lock file's device/inode, so two spellings of one
    ;; directory still name one owner. The existence check is only a clear
    ;; early refusal; the subsequent store open rechecks what it needs.
    (unless (eq? (gambit-yin-file-kind path #t) 'directory)
      (error "Expected an existing directory" path))
    (let ((normalized (path-normalize path)))
      (if (string=? normalized "/")
          normalized
          (path-strip-trailing-directory-separator normalized)))))

(define (gambit-yin-file-worker operation path fd size dev ino)
  (let* ((op (case operation
               ((lock) 0) ((unlock) 1) ((truncate) 2)
               ((sync-directory) 3) ((check-writable) 4)))
         (result (joltffi-await-file op path fd size dev ino)))
    (when (< result 0)
      (error (string-append "Gambit " (symbol->string operation) " failed for " path
                            " (errno " (number->string (- result)) ")")))
    result))

;; The durable store's `canonical-dir` key is lexical on this host, so a
;; symlinked spelling must still be refused before this process opens a
;; second descriptor for a lock inode it already holds: closing any
;; descriptor for a file drops every POSIX record lock this process holds
;; on it. These tables key the one owner by device/inode, not by spelling.
;; The identity is read with stat after the worker's open; an external
;; actor replacing the lock file in that instant is outside the
;; cooperating-owner contract, and the fcntl lock itself remains on the
;; worker's descriptor.
(define gambit-yin-held-locks (make-table test: equal?))
(define gambit-yin-held-lock-fds (make-table test: equal?))

(define (gambit-yin-lock-identity path)
  (let ((info (gambit-yin-file-info path #t)))
    (and info (cons (file-info-device info) (file-info-inode info)))))

(define (gambit-yin-lock-file path)
  (let* ((path (gambit-yin-absolute-path path))
         (held (gambit-yin-lock-identity path)))
    (if (and held (table-ref gambit-yin-held-locks held #f))
        (keyword #f "held")
        (let ((result (gambit-yin-file-worker 'lock path 0 0 0 0)))
          (cond
            ((= result 2147483647) (keyword #f "held"))
            (else
             (let ((identity (or (gambit-yin-lock-identity path) held)))
               (when identity
                 (table-set! gambit-yin-held-locks identity result)
                 (table-set! gambit-yin-held-lock-fds result identity)))
             result))))))

(define (gambit-yin-unlock-file fd)
  (let ((identity (table-ref gambit-yin-held-lock-fds fd #f)))
    (when identity
      (table-set! gambit-yin-held-locks identity #f)
      (table-set! gambit-yin-held-lock-fds fd #f)))
  (gambit-yin-file-worker 'unlock "" fd 0 0 0)
  jolt-nil)

;; Log handles pin the port and its initial identity. Exact recovery cuts
;; require ftruncate, which reopens and checks that identity on the worker.
;;
;; The classify/open pair is a TOCTOU window bounded on both sides: the
;; durable store already holds the directory's exclusive lock here (its
;; `open` locks before it creates the content file), so a cooperating owner
;; cannot swap the path; and the post-open `file-info` recheck refuses any
;; non-regular entry before a byte is read or appended. The recorded
;; device/inode then makes every later truncate refuse a replacement.
(define (gambit-yin-open-log path)
  (let ((path (gambit-yin-absolute-path path)))
    (gambit-yin-mkdirs (path-directory path))
    (unless (memq (gambit-yin-file-kind path #t) '(absent regular))
      (error "Content log is not a regular file" path))
    (let ((port (open-file (list path: path create: 'maybe buffering: #f))))
      (with-exception-catcher
        (lambda (e) (close-port port) (raise e))
        (lambda ()
          (let ((info (file-info path)))
            (unless (eq? (file-info-type info) 'regular)
              (error "Content log is not a regular file" path))
            (vector port path (file-info-device info) (file-info-inode info))))))))

(define (gambit-yin-log-length log)
  (output-port-byte-position (vector-ref log 0) 0 2))

(define (gambit-yin-log-read log offset size)
  (let* ((port (vector-ref log 0))
         (n (jnum->exact size))
         (bytes (make-u8vector n)))
    (input-port-byte-position port (jnum->exact offset))
    (unless (= n (read-subu8vector bytes 0 n port))
      (error "Content log ended before the requested bytes" (vector-ref log 1)))
    bytes))

(define (gambit-yin-log-read-s32be log offset)
  (let* ((b (gambit-yin-log-read log offset 4))
         (n (+ (* (u8vector-ref b 0) 16777216)
               (* (u8vector-ref b 1) 65536)
               (* (u8vector-ref b 2) 256)
               (u8vector-ref b 3))))
    (if (< n 2147483648) n (- n 4294967296))))

(define (gambit-yin-log-append log bytes)
  (let ((port (vector-ref log 0))
        (n (u8vector-length bytes)))
    (when (> n 2147483647)
      (error "Content log frame exceeds the signed 32-bit length"))
    (let ((prefix (u8vector (bitwise-and (arithmetic-shift n -24) 255)
                            (bitwise-and (arithmetic-shift n -16) 255)
                            (bitwise-and (arithmetic-shift n -8) 255)
                            (bitwise-and n 255))))
      (gambit-yin-log-length log)
      (write-subu8vector prefix 0 4 port)
      (write-subu8vector bytes 0 n port)))
  jolt-nil)

(define (gambit-yin-log-truncate log size)
  (gambit-yin-file-worker 'truncate (vector-ref log 1) 0 (jnum->exact size)
                          (vector-ref log 2) (vector-ref log 3))
  jolt-nil)

(define (gambit-yin-log-sync log)
  (force-output (vector-ref log 0) 1)
  jolt-nil)

(define (gambit-yin-log-close log)
  (close-port (vector-ref log 0))
  jolt-nil)

;; Gambit's call-with-file procedures close only on normal return.
(define (gambit-yin-with-file-port port f)
  (dynamic-wind (lambda () #f)
                (lambda () (f port))
                (lambda () (close-port port))))

(define (gambit-yin-read-file path limit)
  (let* ((path (gambit-yin-absolute-path path))
         (bounded? (not (jolt-nil? limit)))
         (entry (gambit-yin-file-kind path (not bounded?))))
    (cond
      ((eq? entry 'absent) (keyword #f "absent"))
      ((or (eq? entry 'regular)
           (and (eq? entry 'symbolic-link)
                (eq? (gambit-yin-file-kind path #t) 'regular)))
       (gambit-yin-with-file-port (open-input-file path)
         (lambda (port)
           ;; Seeking rejects a FIFO before reading, even if it appeared
           ;; after classification. Gambit opens file ports with O_NONBLOCK.
           (let* ((size (input-port-byte-position port 0 2))
                  (n (if bounded? (min size (+ 1 (jnum->exact limit))) size))
                  (bytes (make-u8vector n)))
             (input-port-byte-position port 0)
             (let ((count (read-subu8vector bytes 0 n port)))
               (if (= count n) bytes (subu8vector bytes 0 count)))))))
      (else (keyword #f "not-regular")))))

;; `create: #t` is Gambit's O_CREAT|O_EXCL: the open is one atomic claim,
;; the target is never truncated, and an existing entry fails before any
;; byte is written. There is deliberately no pre-existence check, so no
;; check-then-create window exists. The key-file seam answers :exists;
;; the HEAD-temp seam lets the exclusive-create failure escape, as the
;; Chez arm's write-new-synced! does.
(define (gambit-yin-write-new path bytes private?)
  (let* ((path (gambit-yin-absolute-path path))
         (owner-only? (jolt-truthy? private?))
         (opened
          ;; Only the exclusive open is classified: a write or fsync failure
          ;; after a successful create must escape unchanged.
          (with-exception-catcher
            (lambda (e)
              (if (and owner-only?
                       (or (file-exists-exception? e)
                           ;; An entry that raced in is still never
                           ;; overwritten; classify only after the open
                           ;; failed, and only for the key-file seam.
                           (not (eq? 'absent (gambit-yin-file-kind path #f)))))
                  (keyword #f "exists")
                  (raise e)))
            (lambda ()
              (open-output-file
                (list path: path create: #t buffering: #f
                      permissions: (if owner-only? #o600 #o666)))))))
    (if (keyword? opened)
        opened
        (begin
          (gambit-yin-with-file-port opened
            (lambda (port)
              (write-subu8vector bytes 0 (u8vector-length bytes) port)
              (force-output port 1)))
          jolt-nil))))

(define (gambit-yin-rename-file from to)
  (rename-file (gambit-yin-absolute-path from) (gambit-yin-absolute-path to) #t)
  jolt-nil)

(define (gambit-yin-sync-dir path)
  (gambit-yin-file-worker 'sync-directory (gambit-yin-absolute-path path) 0 0 0 0)
  jolt-nil)

(register-host-methods! "file"
  (list
    (cons "exists" (lambda (f)
      (not (eq? 'absent (gambit-yin-file-kind (gambit-yin-absolute-path (jhost-state f)) #t)))))
    (cons "isDirectory" (lambda (f)
      (eq? 'directory (gambit-yin-file-kind (gambit-yin-absolute-path (jhost-state f)) #t))))
    (cons "canWrite" (lambda (f)
      (= 1 (gambit-yin-file-worker 'check-writable (gambit-yin-absolute-path (jhost-state f)) 0 0 0 0))))
    (cons "mkdirs" (lambda (f)
      (gambit-yin-mkdirs (gambit-yin-absolute-path (jhost-state f)))))))
