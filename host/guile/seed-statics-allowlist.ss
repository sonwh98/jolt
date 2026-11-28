;; Constructors referenced by host/guile/seed/prelude.ss or image.ss.
;; JVM stream wrappers used by clojure.main. Guile uses ports instead.
("BufferedWriter")
("FileWriter")
("LineNumberingPushbackReader")
("StringReader")
("java.nio.file.Files" "createTempFile")
;; JVM-specific collection and atomic types used by the generic vector overlay.
("SeqIterator")
("clojure.lang.APersistentVector$RSeq")
("clojure.lang.Cons")
("java.util.concurrent.atomic.AtomicInteger")
