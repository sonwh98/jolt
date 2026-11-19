(ns p1c.source-entry
  (:require [p1c.source-dependency :as dependency]))

(defn result []
  #?(:jolt (dependency/combine 17 25) :default :wrong-reader-feature))
