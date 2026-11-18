;; W0MT — build-configuration witness for the LOCAL MULTITHREADED-VM 4.9.8
;; build (p1a-mt/gambit-builds/mt), the codex review's step 1 record.
;;
;; Records, verbatim:
;;   - ___VERSION of the compiled-in runtime
;;   - the threading/VM configuration macros as THIS build's configured
;;     gambit.h substitutes them (include/gambit.h:1469-1491 — generated in
;;     the build tree with ___MULTIPLE_THREADED_VMS and ___MAX_PROCESSORS 8)
;;   - the SMP cond-expand feature (lib/_thread.scm:9 selects the SMP
;;     scheduler implementation under (cond-expand (enable-smp ...)))
;;   - runtime-observable state under EXPLICIT -:p2 startup (main.c:46-49):
;;     (##current-vm-processor-count), (##cpu-count), (##core-count),
;;     heap parameters via the documented C API, and the SMP-only
;;     (##current-processor-id) primitive (lib/_thread.scm:667)
;;
;; NOTE: this witness deliberately does NOT call (##current-vm-resize ...) —
;; the review (step 1) warns that new processors execute a supplied thunk
;; (setup.c:810-835,992-994); parallelism here comes from normal startup only.
;;
;; Run: ./w0mt.exe -:p2

(c-declare #<<c-declare-end

#include <stdio.h>

static char w0mt_buf[16384];

static char *w0mt_probe (void)
{
  int n = 0;
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___VERSION=%ld\n", (long)___VERSION);

#ifdef ___SINGLE_VM
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___SINGLE_VM=defined\n");
#else
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___SINGLE_VM=UNDEFINED\n");
#endif
#ifdef ___SINGLE_THREADED_VMS
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___SINGLE_THREADED_VMS=defined\n");
#else
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___SINGLE_THREADED_VMS=UNDEFINED\n");
#endif
#ifdef ___MULTIPLE_THREADED_VMS
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___MULTIPLE_THREADED_VMS=defined\n");
#else
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___MULTIPLE_THREADED_VMS=UNDEFINED\n");
#endif
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___MAX_PROCESSORS=%d\n", (int)___MAX_PROCESSORS);
#ifdef ___USE_POSIX_THREAD_SYSTEM
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___USE_POSIX_THREAD_SYSTEM=defined\n");
#endif
#ifdef ___SINGLE_HOST
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___SINGLE_HOST=defined (-D by gambuild-C)\n");
#else
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___SINGLE_HOST=UNDEFINED\n");
#endif
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "___SINGLE_HOST_LIMIT=%d\n", (int)___SINGLE_HOST_LIMIT);

  /* TLS pstate mechanism (gambit.h:8607-8685): which mode this build uses */
#ifdef ___USE_THREAD_LOCAL_STORAGE_GETTER_SETTER
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "pstate-TLS-mode=getter/setter (___get_tls_ptr)\n");
#else
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "pstate-TLS-mode=direct ___tls_ptr (thread-local storage class)\n");
#endif

  /* Documented C API getters (gambit.h). */
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "min-heap-bytes=%lu\n",
                 (unsigned long)___EXT(___get_min_heap) ());
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "max-heap-bytes=%lu\n",
                 (unsigned long)___EXT(___get_max_heap) ());
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "live-percent=%d\n", ___EXT(___get_live_percent) ());
  n += snprintf (w0mt_buf+n, sizeof(w0mt_buf)-n, "parallelism-level=%d\n", ___EXT(___get_parallelism_level) ());

  return w0mt_buf;
}

c-declare-end
)

(define w0mt-probe (c-lambda () nonnull-char-string "w0mt_probe"))

(display "=== W0MT build-configuration witness (MT build) ===")
(newline)
(display (w0mt-probe))
(display "smp-feature=")
(display (cond-expand (enable-smp "ENABLED") (else "disabled")))
(newline)
(display "##cpu-count=")       (display (##cpu-count)) (newline)
(display "##core-count=")      (display (##core-count)) (newline)
(display "##current-vm-processor-count=")
(display (##current-vm-processor-count)) (newline)
(display "primordial ##current-processor-id=")
(display (##current-processor-id)) (newline)
(display "W0MT-VERDICT: PASS (MT configuration recorded; no vm-resize used)")
(newline)
