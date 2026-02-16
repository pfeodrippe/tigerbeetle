(ns tigerbeetle.recife.runner
  (:require [recife.core :as r]
            [tigerbeetle.recife.ledger-state-machine :as ledger]
            [tigerbeetle.recife.request-and-query-contracts :as requests]
            [tigerbeetle.recife.client-sessions :as sessions]
            [tigerbeetle.recife.cluster-consensus :as consensus]
            [tigerbeetle.recife.tigerbeetle-system :as system]))

(def default-opts
  {:seed 7
   :fp 0
   :workers 1
   :depth 100
   :no-deadlock true
   :async false})

(defn await-result [result]
  (if (instance? clojure.lang.IDeref result)
    @result
    result))

(defn summary [result]
  (select-keys result [:trace :trace-info :distinct-states :generated-states :seed :fp]))

(defn assert-ok! [label result]
  (when-not (= :ok (:trace result))
    (throw (ex-info (str label " failed model check")
                    {:label label
                     :result result})))
  result)

(defn run-check! [label global components]
  (println (str "== " label " =="))
  (let [result (-> (r/run-model global components default-opts)
                   await-result)]
    (println (pr-str (summary result)))
    (assert-ok! label result)))

(defn -main []
  (run-check! "ledger-state-machine"
              ledger/scenario-global
              ledger/components)
  (run-check! "request-and-query-contracts"
              requests/scenario-global
              requests/components)
  (run-check! "client-sessions"
              sessions/scenario-global
              sessions/components)
  (run-check! "cluster-consensus"
              consensus/scenario-global
              consensus/components)
  (run-check! "tigerbeetle-system"
              system/scenario-global
              system/components)
  (println "All Recife model checks passed."))
