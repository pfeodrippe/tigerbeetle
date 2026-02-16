(ns tigerbeetle.recife.request-and-query-contracts
  (:require [recife.core :as r]
            [recife.helpers :as rh]))

;; Scope: Request envelope semantics around batch execution and query reply contracts.
;; Includes: imported-mode consistency, open linked-chain handling, reply-shape rules.
;; Excludes: ledger mutation internals (covered by ledger-state-machine model).

(def operation->shape
  {:create_accounts :create_accounts_results
   :create_transfers :create_transfers_results
   :lookup_accounts :lookup_accounts_rows
   :lookup_transfers :lookup_transfers_rows
   :get_account_transfers :get_account_transfers_rows
   :get_account_balances :get_account_balances_rows
   :query_accounts :query_accounts_rows
   :query_transfers :query_transfers_rows})

(def global
  {::incoming-requests []
   ::resolved-requests {}
   ::event-results []
   ::replies {}
   ::materialized-row-count
   {:lookup_accounts 2
    :lookup_transfers 2
    :get_account_transfers 4
    :get_account_balances 3
    :query_accounts 5
    :query_transfers 5}
   :clock/now 0})

(defn pop-front [xs]
  (vec (rest xs)))

(defn batch-uses-single-imported-mode? [events]
  (or (empty? events)
      (apply = (map #(true? (:imported %)) events))))

(defn last-event-has-linked-flag? [events]
  (boolean (:linked (last events))))

(defn open-linked-chain-start [events]
  (loop [idx 0
         chain-start nil]
    (if (= idx (count events))
      chain-start
      (let [linked? (true? (:linked (nth events idx)))]
        (cond
          (and linked? (nil? chain-start))
          (recur (inc idx) idx)

          (and (not linked?) (some? chain-start))
          (recur (inc idx) nil)

          :else
          (recur (inc idx) chain-start))))))

(defn open-linked-tail-indexes [events]
  (let [start (open-linked-chain-start events)
        end (dec (count events))]
    (if (and (some? start) (< start end))
      (range start end)
      [])))

(defn account-filter-valid? [request]
  (let [f (:account-filter request)]
    (and (map? f)
         (pos? (or (:account-id f) 0))
         (pos? (or (:limit f) 0))
         (>= (or (:timestamp-max f) 0)
             (or (:timestamp-min f) 0)))))

(defn account-filter-valid-for-history? [request]
  (and (account-filter-valid? request)
       (true? (:account-has-history request))))

(defn query-filter-valid? [request]
  (let [f (:query-filter request)]
    (and (map? f)
         (pos? (or (:limit f) 0))
         (>= (or (:timestamp-max f) 0)
             (or (:timestamp-min f) 0)))))

(defn reply-checksum [request row-count]
  (keyword (str "reply-" (:request-id request) "-" row-count)))

(defn make-empty-reply [request]
  {:request-id (:request-id request)
   :operation (:operation request)
   :shape (operation->shape (:operation request))
   :row-count 0
   :reply-checksum (reply-checksum request 0)})

(defn record-request-results [db request results]
  (-> db
      (update ::event-results into results)
      (assoc-in [::resolved-requests (:request-id request)] request)))

(defn resolve-create-batch [request event-key]
  (let [events (vec (get request event-key))]
    (cond
      (not (batch-uses-single-imported-mode? events))
      (mapv (fn [idx]
              {:request-id (:request-id request)
               :event-index idx
               :result :rejected
               :reason :imported_event_expected_or_not_expected})
            (range (count events)))

      (last-event-has-linked-flag? events)
      (let [open-tail-indexes (open-linked-tail-indexes events)
            chain-open-index (dec (count events))
            tail-results (mapv (fn [idx]
                                 {:request-id (:request-id request)
                                  :event-index idx
                                  :result :linked_event_failed
                                  :reason :linked_event_failed})
                               open-tail-indexes)]
        (conj tail-results
              {:request-id (:request-id request)
               :event-index chain-open-index
               :result :linked_event_chain_open
               :reason :linked_event_chain_open}))

      :else
      (mapv (fn [idx]
              {:request-id (:request-id request)
               :event-index idx
               :result :ok
               :reason nil})
            (range (count events))))))

(defn resolve-read-reply [db request]
  (let [operation (:operation request)
        available (get (::materialized-row-count db) operation 0)
        valid? (case operation
                 :lookup_accounts true
                 :lookup_transfers true
                 :get_account_transfers (account-filter-valid? request)
                 :get_account_balances (account-filter-valid-for-history? request)
                 :query_accounts (query-filter-valid? request)
                 :query_transfers (query-filter-valid? request)
                 false)]
    (if (not valid?)
      (make-empty-reply request)
      (let [requested-limit (or (get-in request [:account-filter :limit])
                                (get-in request [:query-filter :limit])
                                available)
            row-count (min available requested-limit)]
        {:request-id (:request-id request)
         :operation operation
         :shape (operation->shape operation)
         :row-count row-count
         :reply-checksum (reply-checksum request row-count)}))))

(r/defproc resolve-next-request
  (fn [{:keys [::incoming-requests] :as db}]
    (when (seq incoming-requests)
      (let [request (first incoming-requests)
            db* (-> db
                    (update ::incoming-requests pop-front)
                    (update :clock/now inc))
            operation (:operation request)]
        (cond
          (= operation :create_accounts)
          (let [results (resolve-create-batch request :account-events)
                reply {:request-id (:request-id request)
                       :operation operation
                       :shape (operation->shape operation)
                       :row-count (count results)
                       :reply-checksum (reply-checksum request (count results))}]
            (-> db*
                (record-request-results request results)
                (assoc-in [::replies (:request-id request)] reply)))

          (= operation :create_transfers)
          (let [results (resolve-create-batch request :transfer-events)
                reply {:request-id (:request-id request)
                       :operation operation
                       :shape (operation->shape operation)
                       :row-count (count results)
                       :reply-checksum (reply-checksum request (count results))}]
            (-> db*
                (record-request-results request results)
                (assoc-in [::replies (:request-id request)] reply)))

          (contains? #{:lookup_accounts
                       :lookup_transfers
                       :get_account_transfers
                       :get_account_balances
                       :query_accounts
                       :query_transfers}
                     operation)
          (let [reply (resolve-read-reply db* request)]
            (-> db*
                (assoc-in [::resolved-requests (:request-id request)] request)
                (assoc-in [::replies (:request-id request)] reply)))

          :else
          ;; Unknown operation is modeled as empty reply so the model stays total.
          (-> db*
              (assoc-in [::resolved-requests (:request-id request)] request)
              (assoc-in [::replies (:request-id request)]
                        (make-empty-reply request))))))))

(rh/definvariant reply-shape-matches-operation
  [{:keys [::replies]}]
  (reduce-kv
   (fn [ok? _request-id reply]
     (and ok?
          (= (:shape reply)
             (operation->shape (:operation reply)))))
   true
   replies))

(rh/definvariant event-result-indexes-are-unique-per-request
  [{:keys [::event-results]}]
  (let [grouped (group-by :request-id event-results)]
    (reduce-kv
     (fn [ok? _request-id results]
       (let [indexes (map :event-index results)]
         (and ok? (= (count indexes) (count (set indexes))))))
     true
     grouped)))

(rh/definvariant invalid-filters-produce-empty-replies
  [{:keys [::resolved-requests ::replies]}]
  (reduce-kv
   (fn [ok? request-id request]
     (let [reply (get replies request-id)
           op (:operation request)]
       (and ok?
            (cond
              (= op :get_account_transfers)
              (if (account-filter-valid? request)
                true
                (zero? (:row-count reply)))

              (= op :get_account_balances)
              (if (account-filter-valid-for-history? request)
                true
                (zero? (:row-count reply)))

              (= op :query_accounts)
              (if (query-filter-valid? request)
                true
                (zero? (:row-count reply)))

              (= op :query_transfers)
              (if (query-filter-valid? request)
                true
                (zero? (:row-count reply)))

              :else
              true))))
   true
   resolved-requests))

(def components
  #{resolve-next-request
    reply-shape-matches-operation
    event-result-indexes-are-unique-per-request
    invalid-filters-produce-empty-replies})

;; ============================================================================
;; Nondeterministic scenario using r/one-of for state space exploration
;; ============================================================================
;;
;; This scenario explores:
;; - Mixed imported mode in batches (should fail validation)
;; - Open linked chains (should fail validation)
;; - Valid vs invalid query filters
;; - Different operation types

(def scenario-global
  (-> global
      (assoc ::incoming-requests
             [{:request-id 1
               :client-session-id 101
               :operation :create_accounts
               :account-events
               [{:id 11 :imported (r/one-of #{true false}) :linked false}
                {:id 12 :imported (r/one-of #{true false}) :linked false}]}
              {:request-id 2
               :client-session-id 101
               :operation :create_transfers
               :transfer-events
               [{:id 21 :imported false :linked (r/one-of #{true false})}
                {:id 22 :imported false :linked (r/one-of #{true false})}]}
              {:request-id 3
               :client-session-id 101
               :operation (r/one-of #{:lookup_accounts :lookup_transfers})
               :lookup-account-ids [1 2 3]}
              {:request-id 4
               :client-session-id 101
               :operation :get_account_balances
               :account-has-history (r/one-of #{true false})
               :account-filter {:account-id (r/one-of #{0 1})
                                :limit (r/one-of #{0 10})
                                :timestamp-min 1
                                :timestamp-max 10}}
              {:request-id 5
               :client-session-id 101
               :operation (r/one-of #{:query_accounts :query_transfers})
               :query-filter {:limit (r/one-of #{0 3})
                              :timestamp-min 1
                              :timestamp-max 100}}])))
