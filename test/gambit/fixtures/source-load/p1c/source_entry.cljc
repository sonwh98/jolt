(ns p1c.source-entry
  (:require [p1c.source-dependency :as dependency]))

(def answer
  (delay #?(:jolt (dependency/combine 17 25) :default :wrong-reader-feature)))

(defn result []
  (force answer))
