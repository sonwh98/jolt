# p1b-inv/CONSUMERS.md — native consumers' binding surfaces (seed inventory for the shim registry)

Companion artifacts: `ffi-call-sites.md` (construction sites), `shim-registry.edn`
(shape ids referenced below). Fork `gambit-ffi-inv` @ a6852ef8; consumers live in
the datomworld checkout (`native/` + `src/jolt/dao` + `src/jolt/yang/antlr`) and
in this fork's stdlib. Static analysis only — one row per BINDING SITE (some C
entries are bound in more than one namespace; each site is its own row because
each site is its own construction path through `ffi/defcfn` → `__cfn` →
ffi.clj §1.2-1.4).

Column key: shape = `shim-registry.edn` shape id; blk = `:blocking` on the
binding; err = `:capture-native-error`; cb = callable (C→jolt) rather than
procedure (jolt→C).

## 1. jolt-crypto — `native/jolt-crypto` (extern "C" wrapper over BLAKE3 + libcrypto EVP)

C wrapper: `native/jolt-crypto/jolt_crypto.c` (235 lines), exports exactly the
ten allowlisted entries (`exports.darwin` / `exports.linux`), layout 4
(`jolt_crypto.c:64`). Bound by four jolt namespaces (all via
`ffi/load-library` + `ffi/defcfn`).

| Symbol | C entry | Signature (jolt types) | shape | blk | err | cb | site | J-slice / gate |
|---|---|---|---|---|---|---|---|---|
| c-layout-version | jolt_crypto_layout_version | [] :int | :shape/s01-noarg-int | no | no | no | src/jolt/dao/host/hash.jolt:69 | load gate: refuses a library answering ≠ 4 (hash.jolt:95-97) |
| c-provenance | jolt_crypto_provenance | [:pointer :size_t] :int | :shape/s02-ptr-size-int | no | no | no | src/jolt/dao/host/hash.jolt:70 | provenance gate (§6.3): 4096-byte buf, tab-separated version/path/digest (hash.jolt:122-130) |
| c-blake3 | jolt_crypto_blake3 | [:pointer :size_t :pointer] :int | :shape/s05-digest-blocking | YES | no | no | src/jolt/dao/host/hash.jolt:73 | P entries; blocking hash → real-GC gate (astra P2) |
| c-sha256 | jolt_crypto_sha256 | [:pointer :size_t :pointer] :int | :shape/s05-digest-blocking | YES | no | no | src/jolt/dao/host/hash.jolt:77 | same |
| c-random | jolt_crypto_random | [:pointer :size_t] :int | :shape/s04-ptr-size-int-blocking | YES | no | no | src/jolt/dao/posix/random.jolt:25 | J2 (yin.vm.linker :jolt arm; owner ruling 1792655000000) |
| c-random | jolt_crypto_random | [:pointer :size_t] :int | :shape/s04-ptr-size-int-blocking | YES | no | no | src/jolt/dao/stream/ws/crypto.jolt:56 | second binding site, same shape |
| c-cleanse | jolt_crypto_cleanse | [:pointer :size_t] :void | :shape/s03-ptr-size-void | no | no | no | src/jolt/dao/posix/random.jolt:29 | no-allocation-during-cleanse gate |
| c-cleanse | jolt_crypto_cleanse | [:pointer :size_t] :void | :shape/s03-ptr-size-void | no | no | no | src/jolt/dao/host/sign.jolt:56 | same |
| c-sha1 | jolt_crypto_sha1 | [:pointer :size_t :pointer] :int | :shape/s05-digest-blocking | YES | no | no | src/jolt/dao/stream/ws/crypto.jolt:52 | J6c: RFC 6455 Sec-WebSocket-Accept only (crypto.jolt:12) |
| c-public | jolt_crypto_ed25519_public | [:pointer :pointer] :int | :shape/s06-ptr-ptr-int-blocking | YES | no | no | src/jolt/dao/host/sign.jolt:50 | J1b sign surface |
| c-sign | jolt_crypto_ed25519_sign | [:pointer :pointer :size_t :pointer] :int | :shape/s07-sign-blocking | YES | no | no | src/jolt/dao/host/sign.jolt:52 | J1b |
| c-verify | jolt_crypto_ed25519_verify | [:pointer :pointer :size_t :pointer] :int | :shape/s07-sign-blocking | YES | no | no | src/jolt/dao/host/sign.jolt:54 | J1b (answers 1/0/negative) |

**The twenty audited libcrypto entries** — not Scheme bindings; they are the
EVP/* symbols `jolt_crypto_provenance` dladdr-audits for single-origin
(`jolt_crypto.c:208-227`, split detection `JC_SPLIT` at 225-226). Listed for
the P2 provenance gate: EVP_DigestInit_ex, EVP_Digest, EVP_DigestUpdate,
EVP_DigestFinal_ex, EVP_sha256, EVP_sha1, EVP_PKEY_new_raw_private_key,
EVP_PKEY_new_raw_public_key, EVP_PKEY_get_raw_public_key, EVP_DigestSignInit,
EVP_DigestSign, EVP_DigestVerifyInit, EVP_DigestVerify, EVP_MD_CTX_new,
EVP_MD_CTX_free, EVP_PKEY_free, OPENSSL_cleanse, OpenSSL_version_num,
OpenSSL_version, RAND_bytes. (RAND_bytes and EVP_sha1 are the two astra named;
they are entries 20 and 6 of this table.)

## 2. jolt-file — `native/jolt-file` (POSIX wrapper; libc only; JOLT_FILE_LAYOUT 3)

C wrapper: `native/jolt-file/jolt_file.c` (456 lines). All 24 bindings in one
namespace: `src/jolt/dao/posix/file.jolt`. J-slices from the file's own layout
comments: J4a = lines 67-95 (layout 1), J4b = 96-102 ("J4b (layout 2)"),
J4d = 103-111 ("J4d (layout 3)").

| Symbol | C entry | Signature | shape | blk | err | cb | site | J-slice |
|---|---|---|---|---|---|---|---|---|
| c-layout-version | jolt_file_layout_version | [] :int32 | :shape/s01b-noarg-int32 | no | no | no | file.jolt:67 | load gate (refuses < 3) |
| c-eintr | jolt_file_eintr | [] :int32 | :shape/s01b-noarg-int32 | no | no | no | file.jolt:81 | J4a (EINTR const) |
| c-make-parents | jolt_file_make_parents | [:pointer :int64] :int64 | :shape/s08-path-open-blocking | YES | no | no | file.jolt:82 | J4a |
| c-open | jolt_file_open | [:pointer :int64] :int64 | :shape/s08-path-open-blocking | YES | no | no | file.jolt:84 | J4a (frame writer) |
| c-length | jolt_file_length | [:int64] :int64 | :shape/s09-handle-blocking | YES | no | no | file.jolt:85 | J4a |
| c-pread | jolt_file_pread | [:int64 :int64 :pointer :int64 :int64] :int64 | :shape/s10-pread-pwrite-blocking | YES | no | no | file.jolt:86 | J4a (byte-identical frames, short/EINTR) |
| c-pwrite | jolt_file_pwrite | [:int64 :int64 :pointer :int64 :int64] :int64 | :shape/s10-pread-pwrite-blocking | YES | no | no | file.jolt:88 | J4a |
| c-truncate | jolt_file_truncate | [:int64 :int64] :int64 | :shape/s11-truncate-blocking | YES | no | no | file.jolt:90 | J4a |
| c-sync | jolt_file_sync | [:int64] :int64 | :shape/s09-handle-blocking | YES | no | no | file.jolt:91 | J4a |
| c-close | jolt_file_close | [:int64] :int64 | :shape/s09-handle-blocking | YES | no | no | file.jolt:92 | J4a (descriptor lifetime) |
| c-s32be-get | jolt_file_s32be_get | [:pointer :int64] :int32 | :shape/s12-s32be-get | no | no | no | file.jolt:93 | J4a (frame header read) |
| c-s32be-put | jolt_file_s32be_put | [:pointer :int64 :int32] :void | :shape/s12b-s32be-put | no | no | no | file.jolt:94 | J4a |
| c-strerror | jolt_file_strerror | [:int64 :pointer :int64] :int64 | :shape/s13-strerror | no | no | no | file.jolt:95 | J4a (error text) |
| c-classify | jolt_file_classify | [:pointer :int64 :int32] :int64 | :shape/s14-classify-blocking | YES | no | no | file.jolt:97 | J4b (wrapper/layout refusal before mutation) |
| c-fclassify | jolt_file_fclassify | [:int64] :int64 | :shape/s09-handle-blocking | YES | no | no | file.jolt:99 | J4b |
| c-fidentity | jolt_file_fidentity | [:int64 :pointer] :int64 | :shape/s15-fidentity-blocking | YES | no | no | file.jolt:100 | J4b (cross-host reopen identity) |
| c-open-excl | jolt_file_open_excl | [:pointer :int64] :int64 | :shape/s08-path-open-blocking | YES | no | no | file.jolt:101 | J4b (locking) |
| c-open-read | jolt_file_open_read | [:pointer :int64] :int64 | :shape/s08-path-open-blocking | YES | no | no | file.jolt:102 | J4b |
| c-open-private | jolt_file_open_private | [:pointer :int64] :int64 | :shape/s08-path-open-blocking | YES | no | no | file.jolt:104 | J4d (mode-0600 key creation) |
| c-eexist | jolt_file_eexist | [] :int32 | :shape/s01b-noarg-int32 | no | no | no | file.jolt:105 | J4d (exclusive-create const) |
| c-lock | jolt_file_lock | [:int64] :int64 | :shape/s09-handle-blocking | YES | no | no | file.jolt:106 | J4b/J4d (lock contend/hold probes) |
| c-realpath | jolt_file_realpath | [:pointer :int64 :pointer :int64] :int64 | :shape/s16-two-path-blocking | YES | no | no | file.jolt:107 | J4d |
| c-rename | jolt_file_rename | [:pointer :int64 :pointer :int64] :int64 | :shape/s16-two-path-blocking | YES | no | no | file.jolt:109 | J4d (atomic replace) |
| c-sync-dir | jolt_file_sync_dir | [:pointer :int64] :int64 | :shape/s08-path-open-blocking | YES | no | no | file.jolt:111 | J4d |

jolt-file bindings carry NO `:capture-native-error` — failure classification
rides on returned status codes (`JF_*` at file.jolt:412) and the wrapper's own
`jolt_file_strerror`.

## 3. jolt-parser — `native/jolt-parser` (ANTLR4 C++ runtime behind the extern "C" ABI)

C wrapper: `native/jolt-parser/jolt_parser.cpp` (1430 lines; `JOLT_EXPORT`
entries at 1163-1268). Production bindings: `src/jolt/yang/antlr/cst.jolt`;
test-seam bindings live in the dev probes.

| Symbol | C entry | Signature | shape | blk | err | cb | site | Notes |
|---|---|---|---|---|---|---|---|---|
| c-export | jolt_parser_export | [:pointer :pointer :size_t :pointer :pointer] :int | :shape/s17-parser-export-blocking | YES | no | no | src/jolt/yang/antlr/cst.jolt:60 | dedicated parse thread + stack (jolt_parser.cpp:1163+) |
| c-free | jolt_parser_free | [:pointer] :void | :shape/s18-ptr-free-ordinary | no | no | no | cst.jolt:64 | std::free of owned buffer (cpp:1220) |
| c-worker-new | jolt_parser_worker_new | [] :pointer | :shape/s19-noarg-ptr | no | no | no | cst.jolt:65 | cpp:1163 |
| c-worker-free | jolt_parser_worker_free | [:pointer] :void | :shape/s18-ptr-free-ordinary | **no — QUESTION MARK** | no | no | cst.jolt:66 | **astra's blocking-mark question, now pinned with evidence:** the entry dispatches destruction onto a freshly spawned parse thread and `pthread_join`s it (jolt_parser.cpp:1176-1186; `on_parse_thread` 769-780 — pthread_create + pthread_join), so the call can block for the duration of a worker teardown while its Scheme binding is NOT marked `:blocking`. Qualify or correct the binding (astra P3 note; registry :open-question :worker-free-blocking-mark) |
| c-export-layout-version | jolt_parser_export_layout_version | [] :int | :shape/s01-noarg-int | no | no | no | cst.jolt:67 | export-layout 2 gate (cst.jolt:70) |
| c-parse | jolt_parser_parse | [:pointer :size_t :pointer :pointer] :int | (fixture/dev only — no registry shape; same flag tuple as :shape/s17 with one arg fewer) | YES | no | no | src/dev/jolt_parser_probe.clj:43 | JPT1 parse seam |
| c-layout-version | jolt_parser_layout_version | [] :int | :shape/s01-noarg-int (dev) | no | no | no | src/dev/jolt_parser_probe.clj:45 | |
| inject (ffi/cfn) | jolt_parser_inject_fault | [:int] :int | (dev only) | no | no | no | src/dev/jolt_j5_child.clj:50, src/dev/jolt_j0c_parity.clj:292 | J5 injected-exception control |
| c-budget | jolt_parser_budget | [:pointer] :int | (dev only) | no | no | no | src/dev/jolt_j5_budget.clj:53 | J5b budget |
| c-live-workers | jolt_parser_live_workers | [] :int64 | (dev only) | no | no | no | src/dev/jolt_j5_budget.clj:56 | |
| c-last-stats | jolt_parser_last_stats | [:pointer] :int | (dev only) | no | no | no | src/dev/jolt_j5_budget.clj:57, jolt_j5_measure.clj:53 | |
| c-stack-probe | jolt_parser_stack_probe | [:int] :int | (dev only) | no | no | no | src/dev/jolt_j5_measure.clj:54 | parse-stack paint seam |
| (unbound C entries) | jolt_parser_worker_cache_stats, jolt_parser_static_cache_stats | [:pointer/:none] :int style | — | — | — | — | jolt_parser.cpp:1262+ | C-side test seams, no jolt binding on this SHA |

## 4. Fork stdlib consumers (surfaces the Gambit lane itself runs or refuses)

### 4.1 `stdlib/jolt/ffi.clj` — the FFI namespace's own bindings

| Symbol | C entry | Signature | shape | blk | err | cb | site |
|---|---|---|---|---|---|---|---|
| c-errno-location | __errno_location | [] :pointer | :shape/s20-errno-accessor | no | no | no | ffi.clj:1950 |
| c-error-location | __error | [] :pointer | :shape/s20-errno-accessor | no | no | no | ffi.clj:1951 |
| c-errno-msvc | _errno | [] :pointer | :shape/s20-errno-accessor | no | no | no | ffi.clj:1952 |
| c-errno-bionic | __errno | [] :pointer | :shape/s20-errno-accessor | no | no | no | ffi.clj:1953 |
| c-strerror | strerror | [:int] :string | :shape/s21-int-string | no | no | no | ffi.clj:1954 |

Note: the errno accessors are themselves `foreign-fn` bindings — the Gambit
shim design must not depend on them circularly (the shims capture errno
internally per astra §2; these accessors remain the `ffi/errno` read path).

### 4.2 `stdlib/jolt/io_poller.clj` (11 bindings)

| Symbol | C entry | Signature | shape | blk | err | cb | site |
|---|---|---|---|---|---|---|---|
| c-fcntl | fcntl | [:int :int :varargs :int] :int | :shape/s22-varargs-fcntl | no | no | no | io_poller.clj:90 |
| c-close | close | [:int] :int | (platform; same tuple as :shape/s26c minus capture) | no | no | no | io_poller.clj:91 |
| c-write | write | [:int :pointer :size_t] :ssize_t | (platform, ordinary) | no | no | no | io_poller.clj:92 |
| c-getsockopt | getsockopt | [:int :int :int :pointer :pointer] :int | :shape/s23-capture-ordinary | no | YES | no | io_poller.clj:93 |
| c-kqueue | kqueue | [] :int | (platform, ordinary no-arg) | no | no | no | io_poller.clj:96 |
| c-kevent | kevent | [:int :pointer :int :pointer :int :pointer] :int | :shape/s24-wait-blocking | YES | no | no | io_poller.clj:97 |
| c-kevent-change | kevent | same tuple | :shape/s23-capture-ordinary | no | YES | no | io_poller.clj:100 |
| c-epoll-create1 | epoll_create1 | [:int] :int | (platform, ordinary) | no | no | no | io_poller.clj:103 |
| c-epoll-ctl | epoll_ctl | [:int :int :int :pointer] :int | (platform, ordinary) | no | no | no | io_poller.clj:104 |
| c-epoll-wait | epoll_wait | [:int :pointer :int :int] :int | :shape/s24b-epoll-wait-blocking | YES | no | no | io_poller.clj:105 |
| c-eventfd | eventfd | [:uint :int] :int | (platform, ordinary) | no | no | no | io_poller.clj:106 |

### 4.3 `stdlib/jolt/socket/native.clj` (35 binding forms; POSIX and Windows branches intern the same var names)

| Symbol | C entry | Signature | shape | blk | err | cb | site |
|---|---|---|---|---|---|---|---|
| c-socket | socket | [:int :int :int] :int | :shape/s26-socket-capture | no | YES | no | native.clj:216 |
| c-bind | bind | [:int :pointer :int] :int | :shape/s26b-bind-capture | no | YES | no | native.clj:217 |
| c-listen | listen | [:int :int] :int | :shape/s26c-listen-shutdown-capture | no | YES | no | native.clj:218 |
| c-connect | connect | [:int :pointer :int] :int | :shape/s25-connect-blocking-capture | YES | YES | no | native.clj:219 |
| c-shutdown | shutdown | [:int :int] :int | :shape/s26c-listen-shutdown-capture | no | YES | no | native.clj:221 |
| c-setsockopt | setsockopt | [:int :int :int :pointer :int] :int | :shape/s26d-setsockopt-capture | no | YES | no | native.clj:222 |
| c-getsockopt | getsockopt | [:int :int :int :pointer :pointer] :int | :shape/s23-capture-ordinary | no | YES | no | native.clj:224 |
| c-getsockname | getsockname | [:int :pointer :pointer] :int | :shape/s26e-getsockname-capture | no | YES | no | native.clj:226 |
| c-getpeername | getpeername | [:int :pointer :pointer] :int | :shape/s26e-getsockname-capture | no | YES | no | native.clj:228 |
| c-getaddrinfo | getaddrinfo | [:pointer :pointer :pointer :pointer] :int | (platform, blocking no-capture) | YES | no | no | native.clj:230 |
| c-freeaddrinfo | freeaddrinfo | [:pointer] :void | :shape/s18-ptr-free-ordinary | no | no | no | native.clj:231 |
| c-inet-ntop | inet_ntop | [:int :pointer :pointer :uint] :pointer | (platform, ordinary) | no | no | no | native.clj:232 |
| c-inet-pton | inet_pton | [:int :pointer :pointer] :int | (platform, ordinary) | no | no | no | native.clj:233 |
| c-gethostname | gethostname | [:pointer :size_t] :int | (platform, ordinary) | no | no | no | native.clj:234 |
| c-getnameinfo | getnameinfo | [:pointer :uint :pointer :uint :pointer :uint :int] :int | (platform, blocking no-capture) | YES | no | no | native.clj:235 |
| c-if-nametoindex | if_nametoindex | [:pointer] :uint | (platform, ordinary) | no | no | no | native.clj:238 |
| c-recv (win) | recv | [:int :pointer :int :int] :int | :shape/s25-family | YES | YES | no | native.clj:248-249 |
| c-send (win) | send | [:int :pointer :int :int] :int | :shape/s25-family | YES | YES | no | native.clj:250-251 |
| c-close (win) | closesocket | [:int] :int | :shape/s25-family (SO_LINGER wait) | YES | YES | no | native.clj:253 |
| c-accept (win) | accept | [:int :pointer :pointer] :int | :shape/s26g-accept-capture-blocking | YES | YES | no | native.clj:254-255 |
| c-poll (win) | WSAPoll | [:pointer :uint :int] :int | :shape/s26f-poll-capture-blocking | YES | YES | no | native.clj:256-257 |
| c-ioctl (win) | ioctlsocket | [:int :int :pointer] :int | :shape/s23-family (fixed-arity) | no | YES | no | native.clj:258 |
| c-set-handle-information | SetHandleInformation | [:uptr :uint :uint] :int | (platform, ordinary) | no | no | no | native.clj:259 |
| c-get-handle-information | GetHandleInformation | [:uptr :pointer] :int | (platform, ordinary) | no | no | no | native.clj:260 |
| c-recv (posix) | recv | [:int :pointer :size_t :int] :ssize_t | :shape/s25b-recv-blocking-capture | YES | YES | no | native.clj:262-263 |
| c-send (posix) | send | [:int :pointer :size_t :int] :ssize_t | :shape/s25-family | YES | YES | no | native.clj:264-265 |
| c-close (posix) | close | [:int] :int | :shape/s25-family | YES | YES | no | native.clj:267 |
| c-accept4 / c-accept (posix) | accept4 / accept | [:int :pointer :pointer :int] / [:int :pointer :pointer] | :shape/s26g-accept-capture-blocking | YES | YES | no | native.clj:272-276 |
| c-poll (posix) | poll | [:pointer :int :int] :int | :shape/s26f-poll-capture-blocking | YES | YES | no | native.clj:277-278 |
| c-ioctl (posix) | ioctl | [:int :ulong :varargs :pointer] :int | :shape/s22c-varargs-ioctl-capture | no | YES | no | native.clj:283 |
| c-fcntl (posix) | fcntl | [:int :int :varargs :int] :int | :shape/s22b-varargs-fcntl-capture | no | YES | no | native.clj:284 |
| c-gai-strerror | gai_strerror | [:int] :pointer | (platform, ordinary) | no | no | no | native.clj:285 |
| c-getifaddrs | getifaddrs | [:pointer] :int | (platform, ordinary) | no | no | no | native.clj:286 |
| c-freeifaddrs | freeifaddrs | [:pointer] :void | :shape/s18-ptr-free-ordinary | no | no | no | native.clj:287 |

The file's header (native.clj:8-13) is the design rationale for
`:capture-native-error` everywhere: Winsock never sets errno, and a later-call
errno read is racy — exactly the atomic-capture requirement the shims implement.

### 4.4 `stdlib/jolt/mvn_http.clj` (22 bindings — libssl/libcrypto via system paths, ordinary, no blocking flags)

| Symbol | Signature | shape | site |
|---|---|---|---|
| c-TLS-client-method | [] :pointer | :shape/s19-noarg-ptr | mvn_http.clj:274 |
| c-SSL-CTX-new | [:pointer] :pointer | (platform, ptr→ptr ordinary) | :275 |
| c-SSL-CTX-free | [:pointer] :void | :shape/s18-ptr-free-ordinary | :276 |
| c-SSL-CTX-set-verify | [:pointer :int :pointer] :void | (platform, ordinary) | :277 |
| c-SSL-CTX-default-verify | [:pointer] :int | (platform, ordinary) | :278 |
| c-SSL-new | [:pointer] :pointer | (platform, ordinary) | :279 |
| c-SSL-free | [:pointer] :void | :shape/s18-ptr-free-ordinary | :280 |
| c-SSL-set-bio | [:pointer :pointer :pointer] :void | (platform, ordinary) | :281 |
| c-SSL-set-connect | [:pointer] :void | (platform, ordinary) | :282 |
| c-SSL-connect | [:pointer] :int | (platform, ordinary) | :283 |
| c-SSL-read | [:pointer :pointer :int] :int | (platform, ordinary) | :284 |
| c-SSL-write | [:pointer :pointer :int] :int | (platform, ordinary) | :285 |
| c-SSL-get-error | [:pointer :int] :int | (platform, ordinary) | :286 |
| c-SSL-ctrl | [:pointer :int :int64 :pointer] :int64 | (platform, ordinary) | :287 |
| c-SSL-CTX-ctrl | [:pointer :int :int64 :pointer] :int64 | (platform, ordinary) | :288 |
| c-SSL-shutdown | [:pointer] :int | (platform, ordinary) | :289 |
| c-SSL-set1-host | [:pointer :pointer] :int | (platform, ordinary) | :290 |
| c-BIO-new | [:pointer] :pointer | (platform, ordinary) | :291 |
| c-BIO-s-mem | [] :pointer | :shape/s19-noarg-ptr | :292 |
| c-BIO-read | [:pointer :pointer :int] :int | (platform, ordinary) | :293 |
| c-BIO-write | [:pointer :pointer :int] :int | (platform, ordinary) | :294 |
| c-BIO-ctrl | [:pointer :int :int64 :pointer] :int64 | (platform, ordinary) | :295 |

(SSL_connect/SSL_read can block in C terms but are deliberately NOT marked
`:blocking` on this fork — no GC-progress claim is made for them today; noted
for the P1b designer as a pre-existing Chez-only assumption, not a new gap.)

### 4.5 `stdlib/jolt/winsock.clj` (1 binding)

| Symbol | C entry | Signature | shape | blk | err | cb | site |
|---|---|---|---|---|---|---|---|
| c-wsa-startup | WSAStartup | [:int :pointer] :int | (platform, ordinary) | no | no | no | winsock.clj:41 |

## 5. Headline counts

- Consumer triad binding rows: **41** (crypto 12, file 24, parser 5) + **7**
  dev-probe parser rows.
- Fork stdlib binding rows: **74** (ffi.clj 5, io_poller 11, socket/native 35,
  mvn_http 22, winsock 1).
- Every consumer-triad blocking row (28 of 41) routes through
  `sa-foreign-procedure-blocking` / the scoped `__collect_safe` arm of
  ffi-call-sites.md §1.2 — the shapes the blocking-gate shims must witness.
- Exactly ONE callable row is production-reachable today: none — all callable
  constructions on this SHA come from fixtures (registry S-27/S-29); the
  consumers are all outbound calls. (jolt build --library's export callable,
  build.ss:4649, is Chez-AOT-only.)
- Blocking + capture combinations: **6 production rows** (connect, recv, send,
  close, accept, poll) — the S-25 family, astra's "combinations with supported
  conventions".
- Open question carried forward: **1** (jolt_parser_worker_free blocking mark,
  §3).
