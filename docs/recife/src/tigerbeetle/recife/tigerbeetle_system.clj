(ns tigerbeetle.recife.tigerbeetle-system
  (:require [clojure.set :as set]
            [tigerbeetle.recife.ledger-state-machine :as ledger]
            [tigerbeetle.recife.request-and-query-contracts :as requests]
            [tigerbeetle.recife.client-sessions :as sessions]
            [tigerbeetle.recife.cluster-consensus :as consensus]))

;; Scope: System-level composition of the TigerBeetle Recife models.
;; This module intentionally composes subsystem state/behaviors into one
;; executable whole while preserving each subsystem's boundaries.

(def global
  (merge ledger/global
         requests/global
         sessions/global
         consensus/global
         {:clock/now 0}))

(def scenario-global
  (merge ledger/scenario-global
         requests/scenario-global
         sessions/scenario-global
         consensus/scenario-global
         {:clock/now 0}))

(def components
  (set/union ledger/components
             requests/components
             sessions/components
             consensus/components))
