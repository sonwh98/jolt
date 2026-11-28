;; Guile 3.0.11 on macOS arm64: match each compiled procedure's VM entry to
;; Guile's JIT log and copy its actual machine code while the process is alive.
;; Run from the repo root after building the platform helper:
;;
;;   mkdir -p build/guile/fence-jit
;;   G="$(mise where guile@3.0.11)/bin/guile"
;;   gtimeout 90s env GUILE_JIT_THRESHOLD=0 GUILE_JIT_LOG=2 "$G" --no-auto-compile \
;;     -l host/guile/boot.ss -s host/guile/witnesses/w2-fence-jit.scm \
;;     >build/guile/fence-jit/bytecode.log 2>build/guile/fence-jit/jit.log
;;   for proc in producer consumer; do
;;     cc -c "build/guile/fence-jit/$proc.s" -o "build/guile/fence-jit/$proc.o"
;;     xcrun llvm-objdump -d "build/guile/fence-jit/$proc.o"
;;   done
;;   xcrun llvm-objdump -d build/guile/libjolt-guile-platform.dylib
;;
;; Observed with mise Guile 3.0.11 on Darwin arm64, offsets relative to entry:
;;   Producer: vector slot STR at 0x78, fence procedure dispatch BL at 0x188
;;     (continuation 0x18c), atomic slot STLR at 0x1c4.
;;   Consumer: atomic slot LDAR at 0x4c, fence procedure dispatch BL at 0x160
;;     (continuation 0x164), vector slot LDR at 0x1b8.
;; The dispatch loads its procedure from the module variable shown in the VM
;; dump and branches to its entry via the local call trampoline. The optimized
;; platform helper emits DMB ISH for release and DMB ISHLD for acquire.
;; This is a manual native witness for the same compound forms as guilecheck.
;; The gate also exercises the actual publication accessors under races.

(eval
 '(begin
    (use-modules (system base compile) (system vm program) (system vm disassembler)
                 (system foreign) (ice-9 rdelim))

    (define (native-range proc)
      (let ((entry (format #f "jit: vcode: start=0x~x," (program-code proc)))
            (prefix "jit: mcode: 0x"))
        (call-with-input-file "build/guile/fence-jit/jit.log"
          (lambda (port)
            (let loop ((matched? #f))
              (let ((line (read-line port)))
                (cond
                  ((eof-object? line) (error "missing native range" entry))
                  ((string-prefix? "jit: vcode:" line)
                   (loop (string-prefix? entry line)))
                  ((and matched? (string-prefix? prefix line))
                   (let ((comma (string-index line #\,)))
                     (cons (string->number (substring line (string-length prefix) comma) 16)
                           (string->number (substring line (+ comma 2))))))
                  (else (loop matched?)))))))))

    (define (dump-native name proc)
      (let* ((range (native-range proc))
             (size (cdr range))
             (bytes (pointer->bytevector (make-pointer (car range)) size)))
        (unless (and (positive? size) (zero? (modulo size 4)))
          (error "invalid arm64 code size" name size))
        (format #t "~a VM entry 0x~x, native entry 0x~x, ~a bytes~%"
                name (program-code proc) (car range) size)
        (disassemble-program proc)
        (call-with-output-file (format #f "build/guile/fence-jit/~a.s" name)
          (lambda (port)
            (format port ".text~%_~a:~%" name)
            (do ((i 0 (+ i 4))) ((= i size))
              (format port ".inst 0x~8,'0x~%" (bytevector-u32-native-ref bytes i)))))))

    (let* ((producer (compile '(lambda (v bx)
                                (vector-set! v 0 42)
                                (memory-order-release)
                                (atomic-box-set! bx v))
                              #:env (interaction-environment)))
           (consumer (compile '(lambda (bx)
                                (let ((v (atomic-box-ref bx)))
                                  (memory-order-acquire)
                                  (vector-ref v 0)))
                              #:env (interaction-environment)))
           (v (vector 0))
           (bx (make-atomic-box #f)))
      (producer v bx)
      (unless (= (consumer bx) 42) (error "fence witness read the wrong payload"))
      (dump-native 'producer producer)
      (dump-native 'consumer consumer)))
 (resolve-module '(jolt runtime)))
