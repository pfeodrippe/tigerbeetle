(ns tigerbeetle.recife.client-sessions
  (:require [recife.core :as r]
            [recife.helpers :as rh]))

;; Scope: TigerBeetle client-session lifecycle and submission discipline.
;; Includes: registration/eviction, one in-flight request rule, retries, restart.
;; Excludes: detailed request execution and ledger mutation rules.

(def global
  {::sessions {}
   ::next-session-id 1
   ::registration-requests []
   ::submission-requests []
   ::cluster-replies []
   ::delivery-uncertain []
   ::restart-events []
   ::session-events []
   ::session-errors []
   ::forwarded-requests []
   ::retried-requests []
   ::config {:clients-max 3}
   :clock/now 0})

(defn pop-front [xs]
  (vec (rest xs)))

(defn active-sessions-map [db]
  (reduce-kv
   (fn [acc session-id session]
     (if (= :active (:status session))
       (assoc acc session-id session)
       acc))
   {}
   (::sessions db)))

(defn active-session-count [db]
  (reduce-kv
   (fn [acc _session-id session]
     (if (= :active (:status session))
       (inc acc)
       acc))
   0
   (::sessions db)))

(defn least-recently-committed-session-id [db]
  (let [active-map (active-sessions-map db)]
    (when (seq active-map)
      (reduce-kv
       (fn [best-id session-id session]
         (if (nil? best-id)
           session-id
           (let [best-session (get active-map best-id)
                 best-key [(or (:last-committed-at best-session) -1)
                           (:registered-at best-session)
                           best-id]
                 current-key [(or (:last-committed-at session) -1)
                              (:registered-at session)
                              session-id]]
             (if (neg? (compare current-key best-key))
               session-id
               best-id))))
       nil
       active-map))))

(defn now+ [db]
  (inc (:clock/now db)))

(r/defproc register-session
  (fn [{:keys [::registration-requests ::next-session-id ::config] :as db}]
    (when (seq registration-requests)
      (let [request (first registration-requests)
            db* (update db ::registration-requests pop-front)
            now (now+ db*)
            clients-max (get config :clients-max 0)
            active-cnt (active-session-count db*)
            evictee-id (when (>= active-cnt clients-max)
                         (least-recently-committed-session-id db*))
            db** (cond-> db*
                   (some? evictee-id)
                   (-> (assoc-in [::sessions evictee-id :status] :evicted)
                       (assoc-in [::sessions evictee-id :in-flight-request-id] nil)
                       (update ::session-events conj
                               {:session-id evictee-id
                                :kind :evicted
                                :timestamp now})))
            new-session-id next-session-id
            new-session {:session-id new-session-id
                         :client-id (:client-id request)
                         :status :active
                         :registered-at now
                         :last-committed-at nil
                         :in-flight-request-id nil
                         :last-reply-checksum nil}]
        (-> db**
            (assoc :clock/now now)
            (update ::next-session-id inc)
            (assoc-in [::sessions new-session-id] new-session)
            (update ::session-events conj
                    {:session-id new-session-id
                     :kind :registered
                     :timestamp now}))))))

(r/defproc submit-request
  (fn [{:keys [::registration-requests ::submission-requests ::sessions] :as db}]
    (when (and (empty? registration-requests)
               (seq submission-requests))
      (let [submission (first submission-requests)
            db* (update db ::submission-requests pop-front)
            session-id (:session-id submission)
            session (get sessions session-id)
            now (now+ db*)]
        (cond
          (or (nil? session)
              (not= :active (:status session)))
          (-> db*
              (assoc :clock/now now)
              (update ::session-errors conj
                      {:session-id session-id
                       :request-id (:request-id submission)
                       :error :session_evicted
                       :timestamp now}))

          (some? (:in-flight-request-id session))
          (-> db*
              (assoc :clock/now now)
              (update ::session-errors conj
                      {:session-id session-id
                       :request-id (:request-id submission)
                       :error :in_flight_request_exists
                       :timestamp now}))

          :else
          (-> db*
              (assoc :clock/now now)
              (assoc-in [::sessions session-id :in-flight-request-id] (:request-id submission))
              (update ::session-events conj
                      {:session-id session-id
                       :kind :request_submitted
                       :request-id (:request-id submission)
                       :timestamp now})
              (update ::forwarded-requests conj
                      {:session-id session-id
                       :request-id (:request-id submission)})))))))

(r/defproc receive-reply
  (fn [{:keys [::registration-requests ::submission-requests
               ::cluster-replies ::sessions] :as db}]
    (when (and (empty? registration-requests)
               (empty? submission-requests)
               (seq cluster-replies))
      (let [reply (first cluster-replies)
            db* (update db ::cluster-replies pop-front)
            session-id (:session-id reply)
            session (get sessions session-id)
            now (now+ db*)]
        (if (and session
                 (= :active (:status session))
                 (= (:request-id reply) (:in-flight-request-id session)))
          (-> db*
              (assoc :clock/now now)
              (assoc-in [::sessions session-id :in-flight-request-id] nil)
              (assoc-in [::sessions session-id :last-reply-checksum] (:reply-checksum reply))
              (assoc-in [::sessions session-id :last-committed-at] now)
              (update ::session-events conj
                      {:session-id session-id
                       :kind :reply_received
                       :request-id (:request-id reply)
                       :timestamp now}))
          (assoc db* :clock/now now))))))

(r/defproc retry-request
  (fn [{:keys [::registration-requests ::submission-requests
               ::cluster-replies ::delivery-uncertain ::sessions] :as db}]
    (when (and (empty? registration-requests)
               (empty? submission-requests)
               (empty? cluster-replies)
               (seq delivery-uncertain))
      (let [uncertain (first delivery-uncertain)
            db* (update db ::delivery-uncertain pop-front)
            session-id (:session-id uncertain)
            session (get sessions session-id)
            now (now+ db*)]
        (if (and session
                 (= :active (:status session))
                 (= (:request-id uncertain) (:in-flight-request-id session)))
          (-> db*
              (assoc :clock/now now)
              (update ::session-events conj
                      {:session-id session-id
                       :kind :request_retried
                       :request-id (:request-id uncertain)
                       :timestamp now})
              (update ::retried-requests conj
                      {:session-id session-id
                       :request-id (:request-id uncertain)}))
          (assoc db* :clock/now now))))))

(r/defproc restart-session
  (fn [{:keys [::registration-requests ::submission-requests ::cluster-replies
               ::delivery-uncertain ::restart-events ::sessions] :as db}]
    (when (and (empty? registration-requests)
               (empty? submission-requests)
               (empty? cluster-replies)
               (empty? delivery-uncertain)
               (seq restart-events))
      (let [event (first restart-events)
            db* (update db ::restart-events pop-front)
            previous-id (:previous-session-id event)
            now (now+ db*)
            has-previous? (contains? sessions previous-id)]
        (-> db*
            (assoc :clock/now now)
            (cond->
             has-previous?
             (-> (assoc-in [::sessions previous-id :status] :terminated)
                 (assoc-in [::sessions previous-id :in-flight-request-id] nil)
                 (update ::session-events conj
                         {:session-id previous-id
                          :kind :terminated
                          :timestamp now})))
            (update ::registration-requests conj {:client-id (:new-client-id event)}))))))

(rh/definvariant active-session-count-bounded
  [{:keys [::sessions ::config]}]
  (<= (reduce-kv
       (fn [acc _session-id session]
         (if (= :active (:status session))
           (inc acc)
           acc))
       0
       sessions)
      (get config :clients-max 0)))

(rh/definvariant non-active-sessions-have-no-inflight
  [{:keys [::sessions]}]
  (reduce-kv
   (fn [ok? _session-id session]
     (and ok?
          (if (= :active (:status session))
            true
            (nil? (:in-flight-request-id session)))))
   true
   sessions))

(rh/definvariant at-most-one-inflight-per-active-session
  [{:keys [::sessions]}]
  (reduce-kv
   (fn [ok? _session-id session]
     (and ok?
          (or (nil? (:in-flight-request-id session))
              (integer? (:in-flight-request-id session)))))
   true
   sessions))

(def components
  #{register-session
    submit-request
    receive-reply
    retry-request
    restart-session
    active-session-count-bounded
    non-active-sessions-have-no-inflight
    at-most-one-inflight-per-active-session})

;; ============================================================================
;; Nondeterministic scenario using r/one-of for state space exploration
;; ============================================================================
;;
;; This scenario explores:
;; - Multiple session registrations with eviction when at capacity
;; - Request submission with varying session/request IDs
;; - Reply delivery and retry scenarios
;; - Session restart after eviction

(def scenario-global
  (-> global
      ;; Allow registering multiple clients
      (assoc ::registration-requests
             [{:client-id (r/one-of #{1001 1002})}
              {:client-id (r/one-of #{1003 1004})}
              {:client-id 1005}
              {:client-id 1006}])
      ;; Submit requests to different sessions (some may not exist yet)
      (assoc ::submission-requests
             [{:session-id (r/one-of #{1 2 3}) :request-id 88}
              {:session-id (r/one-of #{1 2 3}) :request-id 89}])
      ;; Uncertain delivery for retries
      (assoc ::delivery-uncertain
             [{:session-id (r/one-of #{1 2}) :request-id 88}])
      ;; Cluster replies
      (assoc ::cluster-replies
             [{:session-id (r/one-of #{1 2 3}) :request-id 88 :reply-checksum :reply-88}])
      ;; Restart events
      (assoc ::restart-events
             [{:previous-session-id (r/one-of #{1 2}) :new-client-id 2001}])))
