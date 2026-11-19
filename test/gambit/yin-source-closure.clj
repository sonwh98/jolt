;; Run from the Jolt root:
;; clojure -M test/gambit/yin-source-closure.clj ../datomworld [--gambit]
;; The default walks the stock launcher roots. --gambit includes the local
;; host profile and the native jolt.ffi namespace supplied by boot.ss.
(require '[clojure.java.io :as io] '[clojure.string :as str])
(import '[clojure.lang LispReader$Resolver] '[java.io PushbackReader])
(def root (or (first *command-line-args*)
              (throw (ex-info "Pass a datomworld source directory" {}))))
(def gambit? (= "--gambit" (second *command-line-args*)))
(def roots (cond->> [[(str root "/src/jolt") [".jolt" ".cljc" ".clj"]]
            [(str root "/src/cljc") [".cljc" ".clj"]]
            [(str root "/src/clj") [".clj"]]
            ["stdlib" [".jolt" ".cljc" ".clj"]]
            ["jolt-core" [".cljc" ".clj"]]]
             gambit? (cons ["host/gambit/yin" [".jolt"]])))
(def booted (cond-> {'clojure.core [nil nil]}
              gambit? (assoc 'jolt.ffi [nil nil])))
(defn source [n]
  (let [path (-> (str n) (str/replace "." "/") (str/replace "-" "_"))]
    (first (for [[dir suffixes] roots, suffix suffixes
                 :let [file (io/file dir (str path suffix))]
                 :when (.isFile file)]
             file))))
(defn read-source [file n]
  (with-open [r (PushbackReader. (io/reader file))]
    (binding [*default-data-reader-fn* tagged-literal
              *reader-resolver* (reify LispReader$Resolver
                                  (currentNS [_] n)
                                  (resolveAlias [_ s] s)
                                  (resolveClass [_ _] nil)
                                  (resolveVar [_ _] nil))]
      (into [] (take-while #(not= ::eof %))
            (repeatedly #(read {:read-cond :allow :features #{:jolt} :eof ::eof} r))))))
(defn require-names [clauses]
  (for [clause clauses :when (and (seq? clause) (#{:require :use} (first clause)))
        spec (rest clause) :when (or (not (sequential? spec)) (not-any? #{:as-alias} spec))
        :let [target (if (sequential? spec) (first spec) spec)]
        :when (symbol? target)]
    target))
(defn walk [pending loaded]
  (if-let [n (first pending)]
    (if (contains? loaded n)
      (recur (rest pending) loaded)
      (let [f (source n)
            forms (when f (read-source f n))
            ns-form (first forms)
            clauses (filter seq? (drop 2 ns-form))
            deps (if (= 'ns (first ns-form))
                   (require-names clauses)
                   [])]
        (recur (concat deps (rest pending)) (assoc loaded n [f forms]))))
    loaded))
(def loaded (walk (if gambit? '[jolt.gambit.yin] '[yin.repl.main]) booted))
(doseq [[n [f forms]] (sort-by key loaded)]
  (println "NS" n (if f (str f) :booted))
  (when (and (nil? f) (not (contains? booted n)))
    (throw (ex-info "Namespace has no source" {:ns n})))
  (let [ns-form (first forms)
        aliases (into #{} (for [clause (drop 2 ns-form)
                               :when (and (seq? clause) (= :require (first clause)))
                               spec (rest clause)
                               :when (and (vector? spec) (= 'jolt.scheme (first spec)))]
                           (str (second (drop-while #(not= :as %) spec)))))]
    (doseq [form (tree-seq coll? seq forms)
            :when (and (seq? form) (symbol? (first form)))
            :let [head (first form) role (name head)]
            :when (and (#{"proc" "call" "defsfn" "scheme" "eval-string" "scheme-proc"} role)
                       (or (#{"jolt.scheme" "jolt.host"} (namespace head))
                           (aliases (namespace head))))]
      (let [operand (if (= role "defsfn") (nth form 2) (second form))]
        (println "SCHEME" n head (pr-str operand))))))
