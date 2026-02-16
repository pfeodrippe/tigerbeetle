(ns tigerbeetle.recife.cluster-consensus
  (:require [recife.core :as r]
            [recife.helpers :as rh]))

;; Scope: VSR-style replication lifecycle at behavioral level.
;; Includes: prepare/ack/commit quorum flow, view-change progression,
;; state-sync progression, grid repair, determinism mismatch signaling.
;; Excludes: WAL format, storage structures, and exact repair algorithms.

(def global
  {::cluster {:cluster-id 0
              :replica-count 3
              :replication-quorum 2
              :view-change-quorum 2
              :nack-quorum 2
              :latest-committed-op 0
              :latest-checkpoint-id :ckpt-0}
   ::replicas
   {1 {:replica-id 1
       :role :primary
       :status :normal
       :view 0
       :commit-op 0
       :op-head 0
       :checkpoint-id :ckpt-0
       :checkpoint-op 0
       :active true}
    2 {:replica-id 2
       :role :backup
       :status :normal
       :view 0
       :commit-op 0
       :op-head 0
       :checkpoint-id :ckpt-0
       :checkpoint-op 0
       :active true}
    3 {:replica-id 3
       :role :backup
       :status :normal
       :view 0
       :commit-op 0
       :op-head 0
       :checkpoint-id :ckpt-0
       :checkpoint-op 0
       :active true}}
   ::client-requests []
   ::prepares {}
   ::prepare-acks {}
   ::commit-notices []
   ::start-view-change-signals []
   ::svc-votes {}
   ::view-change-round :none
   ::dvc-quorum-observed #{}
   ::repair-completed-views #{}
   ::state-sync-needs []
   ::state-sync {}
   ::sync-ready-for-forest #{}
   ::grid-repairs {}
   ::matching-grid-blocks #{}
   ::next-checkpoint-committed #{}
   ::checkpoint-mismatches []
   ::determinism-violations []
   ::cluster-events []
   :clock/now 0})

(defn pop-front [xs]
  (vec (rest xs)))

(defn now+ [db]
  (inc (:clock/now db)))

(defn primary-id [db]
  (reduce-kv
   (fn [_ replica-id replica]
     (when (= :primary (:role replica))
       (reduced replica-id)))
   nil
   (::replicas db)))

(defn replica-active? [db replica-id]
  (true? (get-in db [::replicas replica-id :active])))

(defn active-replica-ids [db]
  (reduce-kv
   (fn [acc replica-id replica]
     (if (:active replica)
       (conj acc replica-id)
       acc))
   #{}
   (::replicas db)))

(defn next-op [db]
  (inc (max (get-in db [::cluster :latest-committed-op])
            (or (get-in db [::replicas (primary-id db) :op-head]) 0)
            (apply max 0 (keys (::prepares db))))))

(defn preceding-ops-committed? [db op]
  (every?
   (fn [idx]
     (if-let [prepare (get-in db [::prepares idx])]
       (= :committed (:status prepare))
       true))
   (range 1 op)))

(defn new-primary-for-view [db target-view]
  (let [replica-count (get-in db [::cluster :replica-count])]
    (inc (mod target-view replica-count))))

(r/defproc primary-transforms-request-into-prepare
  (fn [{:keys [::client-requests ::replicas] :as db}]
    (when (seq client-requests)
      (let [primary (primary-id db)
            primary-state (get replicas primary)]
        (when (and primary
                   (:active primary-state)
                   (= :normal (:status primary-state)))
          (let [request (first client-requests)
                op (next-op db)
                now (now+ db)
                prepare {:op op
                         :request-id (:request-id request)
                         :client-session-id (:client-session-id request)
                         :primary-id primary
                         :view (:view primary-state)
                         :checkpoint-id (:checkpoint-id primary-state)
                         :status :prepared
                         :prepare-timestamp now}]
            (-> db
                (assoc :clock/now now)
                (update ::client-requests pop-front)
                (assoc-in [::prepares op] prepare)
                (assoc-in [::prepare-acks op] #{primary})
                (assoc-in [::replicas primary :op-head] op)
                (update ::cluster-events conj
                        {:kind :prepare_created
                         :op op
                         :timestamp now}))))))))

(r/defproc replica-persists-prepare-and-acknowledges
  (fn [{:keys [::prepares ::prepare-acks] :as db}]
    (let [prepared-op
          (reduce-kv
           (fn [_ op prepare]
             (when (= :prepared (:status prepare))
               (reduced op)))
           nil
           prepares)]
      (when prepared-op
        (let [current-acks (get prepare-acks prepared-op #{})
              target-replica
              (first (sort (remove current-acks (active-replica-ids db))))]
          (when target-replica
            (let [now (now+ db)]
              (-> db
                  (assoc :clock/now now)
                  (update-in [::prepare-acks prepared-op] (fnil conj #{}) target-replica)
                  (update ::cluster-events conj
                          {:kind :prepare_acked
                           :op prepared-op
                           :replica-id target-replica
                           :timestamp now})))))))))

(r/defproc primary-commits-prepare-after-replication-quorum
  (fn [{:keys [::cluster ::prepares ::prepare-acks] :as db}]
    (let [replication-quorum (:replication-quorum cluster)
          committed-op
          (first
           (sort
            (reduce-kv
             (fn [acc op prepare]
               (let [acks (count (get prepare-acks op #{}))]
                 (if (and (= :prepared (:status prepare))
                          (>= acks replication-quorum)
                          (preceding-ops-committed? db op))
                   (conj acc op)
                   acc)))
             []
             prepares)))]
      (when committed-op
        (let [prepare (get prepares committed-op)
              primary (:primary-id prepare)
              now (now+ db)]
          (-> db
              (assoc :clock/now now)
              (assoc-in [::prepares committed-op :status] :committed)
              (assoc-in [::cluster :latest-committed-op] committed-op)
              (assoc-in [::replicas primary :commit-op] committed-op)
              (update ::commit-notices conj {:op committed-op :view (:view prepare)})
              (update ::cluster-events conj
                      {:kind :prepare_committed
                       :op committed-op
                       :timestamp now})))))))

(r/defproc backups-advance-commit-from-notice
  (fn [{:keys [::commit-notices ::replicas] :as db}]
    (when (seq commit-notices)
      (let [notice (first commit-notices)
            op (:op notice)
            now (now+ db)]
        (-> db
            (assoc :clock/now now)
            (update ::commit-notices pop-front)
            (assoc ::replicas
                   (reduce-kv
                    (fn [acc replica-id replica]
                      (assoc acc replica-id
                             (if (and (= :backup (:role replica))
                                      (:active replica)
                                      (< (:commit-op replica) op))
                               (assoc replica :commit-op op)
                               replica)))
                    {}
                    replicas))
            (update ::cluster-events conj
                    {:kind :commit_notice_applied
                     :op op
                     :timestamp now}))))))

(r/defproc backup-triggers-start-view-change
  (fn [{:keys [::start-view-change-signals ::replicas] :as db}]
    (when (seq start-view-change-signals)
      (let [signal (first start-view-change-signals)
            replica-id (:replica-id signal)
            replica (get replicas replica-id)
            now (now+ db)]
        (if (and replica
                 (= :backup (:role replica))
                 (contains? #{:normal :view_change} (:status replica)))
          (let [target-view (inc (:view replica))]
            (-> db
                (assoc :clock/now now)
                (update ::start-view-change-signals pop-front)
                (assoc-in [::replicas replica-id :status] :view_change)
                (update-in [::svc-votes target-view] (fnil conj #{}) replica-id)
                (update ::cluster-events conj
                        {:kind :start_view_change_broadcast
                         :replica-id replica-id
                         :target-view target-view
                         :timestamp now})))
          (-> db
              (assoc :clock/now now)
              (update ::start-view-change-signals pop-front)))))))

(r/defproc replica-enters-view-change-after-svc-quorum
  (fn [{:keys [::cluster ::svc-votes ::view-change-round ::replicas] :as db}]
    (let [quorum (:view-change-quorum cluster)
          target-view
          (first
           (sort
            (reduce-kv
             (fn [acc view votes]
               (if (>= (count votes) quorum)
                 (conj acc view)
                 acc))
             []
             svc-votes)))]
      (when (and target-view
                 (or (= :none view-change-round)
                     (> target-view (:target-view view-change-round))))
        (let [new-primary (new-primary-for-view db target-view)
              now (now+ db)]
          (-> db
              (assoc :clock/now now)
              (assoc ::view-change-round
                     {:target-view target-view
                      :new-primary-id new-primary
                      :status :collecting_dvc
                      :nack-quorum-observed false})
              (assoc ::replicas
                     (reduce-kv
                      (fn [acc replica-id replica]
                        (assoc acc replica-id
                               (if (:active replica)
                                 (assoc replica
                                        :view target-view
                                        :status :view_change)
                                 replica)))
                      {}
                      replicas))
              (update ::cluster-events conj
                      {:kind :view_change_round_started
                       :target-view target-view
                       :new-primary-id new-primary
                       :timestamp now})))))))

(r/defproc new-primary-repairs-suffix-before-starting-view
  (fn [{:keys [::view-change-round ::dvc-quorum-observed] :as db}]
    (when (and (map? view-change-round)
               (= :collecting_dvc (:status view-change-round))
               (contains? dvc-quorum-observed (:target-view view-change-round)))
      (let [now (now+ db)]
        (-> db
            (assoc :clock/now now)
            (assoc-in [::view-change-round :status] :repairing)
            (update ::cluster-events conj
                    {:kind :repair_started
                     :target-view (:target-view view-change-round)
                     :timestamp now}))))))

(r/defproc new-primary-starts-view-after-repair
  (fn [{:keys [::view-change-round ::repair-completed-views ::replicas] :as db}]
    (when (and (map? view-change-round)
               (= :repairing (:status view-change-round))
               (contains? repair-completed-views (:target-view view-change-round)))
      (let [new-primary-id (:new-primary-id view-change-round)
            now (now+ db)]
        (-> db
            (assoc :clock/now now)
            (assoc-in [::view-change-round :status] :starting_view)
            (assoc ::replicas
                   (reduce-kv
                    (fn [acc replica-id replica]
                      (assoc acc replica-id
                             (cond-> (assoc replica :status :normal)
                               (= replica-id new-primary-id)
                               (assoc :role :primary)
                               (not= replica-id new-primary-id)
                               (assoc :role :backup))))
                    {}
                    replicas))
            (update ::cluster-events conj
                    {:kind :start_view_broadcast
                     :target-view (:target-view view-change-round)
                     :new-primary-id new-primary-id
                     :timestamp now}))))))

(r/defproc trigger-state-sync-when-repair-cannot-catch-up
  (fn [{:keys [::state-sync-needs ::replicas] :as db}]
    (when (seq state-sync-needs)
      (let [need (first state-sync-needs)
            replica-id (:replica-id need)
            replica (get replicas replica-id)
            now (now+ db)]
        (if replica
          (-> db
              (assoc :clock/now now)
              (update ::state-sync-needs pop-front)
              (assoc-in [::replicas replica-id :status] :syncing)
              (assoc-in [::state-sync replica-id]
                        {:replica-id replica-id
                         :target-checkpoint-id (:checkpoint-id need)
                         :sync-op-min (:sync-op-min need)
                         :sync-op-max (:sync-op-max need)
                         :status :installing_checkpoint})
              (update ::cluster-events conj
                      {:kind :state_sync_started
                       :replica-id replica-id
                       :timestamp now}))
          (-> db
              (assoc :clock/now now)
              (update ::state-sync-needs pop-front)))))))

(r/defproc state-sync-repairs-replies-grid-and-forest
  (fn [{:keys [::state-sync] :as db}]
    (let [target
          (reduce-kv
           (fn [_ replica-id sync]
             (when (= :installing_checkpoint (:status sync))
               (reduced replica-id)))
           nil
           state-sync)]
      (when target
        (let [now (now+ db)]
          (-> db
              (assoc :clock/now now)
              (assoc-in [::state-sync target :status] :repairing_replies)
              (update ::cluster-events conj
                      {:kind :state_sync_repairing_replies
                       :replica-id target
                       :timestamp now})))))))

(r/defproc state-sync-progresses-to-forest-sync
  (fn [{:keys [::state-sync ::sync-ready-for-forest] :as db}]
    (let [target
          (reduce-kv
           (fn [_ replica-id sync]
             (when (and (= :repairing_replies (:status sync))
                        (contains? sync-ready-for-forest replica-id))
               (reduced replica-id)))
           nil
           state-sync)]
      (when target
        (let [now (now+ db)]
          (-> db
              (assoc :clock/now now)
              (assoc-in [::state-sync target :status] :syncing_forest)
              (update ::cluster-events conj
                      {:kind :state_sync_syncing_forest
                       :replica-id target
                       :timestamp now})))))))

(r/defproc state-sync-completes-at-next-checkpoint
  (fn [{:keys [::state-sync ::next-checkpoint-committed] :as db}]
    (let [target
          (reduce-kv
           (fn [_ replica-id sync]
             (when (and (= :syncing_forest (:status sync))
                        (contains? next-checkpoint-committed replica-id))
               (reduced replica-id)))
           nil
           state-sync)]
      (when target
        (let [now (now+ db)]
          (-> db
              (assoc :clock/now now)
              (assoc-in [::state-sync target :status] :completed)
              (assoc-in [::replicas target :status] :normal)
              (update ::cluster-events conj
                      {:kind :state_sync_completed
                       :replica-id target
                       :timestamp now})))))))

(r/defproc repair-grid-block-from-peers
  (fn [{:keys [::grid-repairs ::matching-grid-blocks] :as db}]
    (let [target
          (reduce-kv
           (fn [_ block-address repair]
             (when (and (= :none (:repaired-at repair))
                        (contains? matching-grid-blocks block-address))
               (reduced block-address)))
           nil
           grid-repairs)]
      (when target
        (let [now (now+ db)]
          (-> db
              (assoc :clock/now now)
              (assoc-in [::grid-repairs target :repaired-at] now)
              (update ::cluster-events conj
                      {:kind :grid_block_repaired
                       :block-address target
                       :timestamp now})))))))

(r/defproc storage-determinism-mismatch-requires-operator-intervention
  (fn [{:keys [::checkpoint-mismatches] :as db}]
    (when (seq checkpoint-mismatches)
      (let [mismatch (first checkpoint-mismatches)
            replica-id (:replica-id mismatch)
            expected (get-in db [::replicas replica-id :checkpoint-id])
            now (now+ db)]
        (-> db
            (assoc :clock/now now)
            (update ::checkpoint-mismatches pop-front)
            (update ::determinism-violations conj
                    {:replica-id replica-id
                     :expected-checkpoint-id expected
                     :observed-checkpoint-id (:observed-checkpoint-id mismatch)
                     :timestamp now})
            (update ::cluster-events conj
                    {:kind :determinism_violation_detected
                     :replica-id replica-id
                     :timestamp now}))))))

(rh/definvariant replication-quorum-bounded-by-replica-count
  [{:keys [::cluster]}]
  (<= (:replication-quorum cluster)
      (:replica-count cluster)))

(rh/definvariant committed-prepares-have-quorum-acks
  [{:keys [::cluster ::prepares ::prepare-acks]}]
  (reduce-kv
   (fn [ok? op prepare]
     (and ok?
          (if (= :committed (:status prepare))
            (>= (count (get prepare-acks op #{}))
                (:replication-quorum cluster))
            true)))
   true
   prepares))

(rh/definvariant cluster-commit-op-dominates-replicas
  [{:keys [::cluster ::replicas]}]
  (let [cluster-commit (:latest-committed-op cluster)]
    (reduce-kv
     (fn [ok? _ replica]
       (and ok? (<= (:commit-op replica) cluster-commit)))
     true
     replicas)))

(rh/definvariant completed-sync-returns-replica-to-normal
  [{:keys [::state-sync ::replicas]}]
  (reduce-kv
   (fn [ok? replica-id sync]
     (and ok?
          (if (= :completed (:status sync))
            (= :normal (get-in replicas [replica-id :status]))
            true)))
   true
   state-sync))

(def components
  #{primary-transforms-request-into-prepare
    replica-persists-prepare-and-acknowledges
    primary-commits-prepare-after-replication-quorum
    backups-advance-commit-from-notice
    backup-triggers-start-view-change
    replica-enters-view-change-after-svc-quorum
    new-primary-repairs-suffix-before-starting-view
    new-primary-starts-view-after-repair
    trigger-state-sync-when-repair-cannot-catch-up
    state-sync-repairs-replies-grid-and-forest
    state-sync-progresses-to-forest-sync
    state-sync-completes-at-next-checkpoint
    repair-grid-block-from-peers
    storage-determinism-mismatch-requires-operator-intervention
    replication-quorum-bounded-by-replica-count
    committed-prepares-have-quorum-acks
    cluster-commit-op-dominates-replicas
    completed-sync-returns-replica-to-normal})

(def scenario-global
  (-> global
      (assoc ::client-requests
             [{:request-id 9001
               :client-session-id 77
               :operation :create_transfers
               :payload-checksum :p-9001}])
      (assoc ::start-view-change-signals
             [{:replica-id 2}
              {:replica-id 3}])
      (assoc ::dvc-quorum-observed #{1})
      (assoc ::repair-completed-views #{1})
      (assoc ::state-sync-needs
             [{:replica-id 3
               :checkpoint-id :ckpt-2
               :sync-op-min 10
               :sync-op-max 20}])
      (assoc ::sync-ready-for-forest #{3})
      (assoc ::next-checkpoint-committed #{3})
      (assoc ::grid-repairs
             {42 {:block-address 42
                  :expected-checksum :abc-42
                  :repaired-at :none}})
      (assoc ::matching-grid-blocks #{42})
      (assoc ::checkpoint-mismatches
             [{:replica-id 2 :observed-checkpoint-id :ckpt-bad}])))
