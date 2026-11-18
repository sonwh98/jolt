;; W0 — build-configuration witness for the provisioned Gambit 4.9.8.
;;
;; Records, verbatim:
;;   - ___VERSION of the compiled-in runtime
;;   - the threading/VM configuration macros as the INSTALLED configured
;;     gambit.h substitutes them (___SINGLE_THREADED_VMS is substituted by
;;     configure via @CONF_SINGLE_MULTIPLE_THREADED_VMS@, include/gambit.h.in:1471,
;;     so a program compiled against the installed headers reports the
;;     provisioned build's configuration, not an arbitrary default)
;;   - ___MAX_PROCESSORS, VM layout, thread system, rc-allocation for foreign
;;   - ___SINGLE_HOST as passed by the installed gambuild-C (bin/gambuild-C:27
;;     sets DEFS_OBJ=" -D___SINGLE_HOST ")
;;   - runtime-observable state: (##cpu-count), (##core-count),
;;     (##current-vm-processor-count), heap parameters via the documented C API
;;     (gambit.h: ___get_min_heap/___get_max_heap/___get_live_percent/
;;     ___get_parallelism_level, gambit.h ~14788-14804)
;;
;; Run: ./w0-config.exe

(c-declare #<<c-declare-end

#include <stdio.h>

static char w0_buf[16384];

static char *w0_probe (void)
{
  int n = 0;
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___VERSION=%ld\n", (long)___VERSION);

#ifdef ___SINGLE_VM
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___SINGLE_VM=defined\n");
#else
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___SINGLE_VM=UNDEFINED\n");
#endif
#ifdef ___MULTIPLE_VMS
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___MULTIPLE_VMS=defined\n");
#endif
#ifdef ___SINGLE_THREADED_VMS
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___SINGLE_THREADED_VMS=defined\n");
#else
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___SINGLE_THREADED_VMS=UNDEFINED\n");
#endif
#ifdef ___MULTIPLE_THREADED_VMS
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___MULTIPLE_THREADED_VMS=defined\n");
#endif
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___MAX_PROCESSORS=%d\n", (int)___MAX_PROCESSORS);
#ifdef ___USE_POSIX_THREAD_SYSTEM
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___USE_POSIX_THREAD_SYSTEM=defined\n");
#endif
#ifdef ___USE_WIN32_THREAD_SYSTEM
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___USE_WIN32_THREAD_SYSTEM=defined\n");
#endif
#ifdef ___USE_NO_THREAD_SYSTEM
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___USE_NO_THREAD_SYSTEM=defined\n");
#endif
#ifdef ___SINGLE_HOST
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___SINGLE_HOST=defined (-D by gambuild-C)\n");
#else
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___SINGLE_HOST=UNDEFINED\n");
#endif
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___SINGLE_HOST_LIMIT=%d\n", (int)___SINGLE_HOST_LIMIT);
#ifdef ___USE_RC_ALLOCATION_FOR_FOREIGN
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___USE_RC_ALLOCATION_FOR_FOREIGN=defined\n");
#endif
#ifdef ___SUPPORT_LOWLEVEL_EXEC
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "___SUPPORT_LOWLEVEL_EXEC=defined\n");
#endif

  /* Documented C API getters (gambit.h). */
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "min-heap-bytes=%lu\n",
                 (unsigned long)___EXT(___get_min_heap) ());
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "max-heap-bytes=%lu\n",
                 (unsigned long)___EXT(___get_max_heap) ());
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "live-percent=%d\n", ___EXT(___get_live_percent) ());
  n += snprintf (w0_buf+n, sizeof(w0_buf)-n, "parallelism-level=%d\n", ___EXT(___get_parallelism_level) ());

  return w0_buf;
}

c-declare-end
)

(define w0-probe (c-lambda () nonnull-char-string "w0_probe"))

(display "=== W0 build-configuration witness ===")
(newline)
(display (w0-probe))
(display "##cpu-count=")       (display (##cpu-count)) (newline)
(display "##core-count=")      (display (##core-count)) (newline)
(display "##current-vm-processor-count=")
(display (##current-vm-processor-count)) (newline)

;; Try to raise the processor count through the documented resize entry
;; (gambit.h: ___current_vm_resize). On a ___SINGLE_THREADED_VMS build the
;; request is clamped to ___MAX_PROCESSORS = 1 (setup.c:1165-1168).
(let ((before (##current-vm-processor-count)))
  (##current-vm-resize #f 4)   ;; thunk #f: resize without running a thunk
  (display "after ##current-vm-resize(4): processor-count=")
  (display (##current-vm-processor-count))
  (display " (before: ")
  (display before)
  (display ")")
  (newline))
(display "W0-VERDICT: PASS (configuration recorded)")
(newline)
