(ns tigerbeetle.recife.ledger-state-machine
  (:require [recife.core :as r]
            [recife.helpers :as rh]))

;; Scope: Account/transfer ledger behavior.
;; Includes: account creation, transfer creation, pending/post/void/expiry lifecycle,
;; idempotency outcomes, transient transfer-id failures, and balance invariants.
;; Excludes: request/query envelope contracts, client sessions, consensus internals.

(def integer-max 340282366920938463463374607431768211455N)

(def transient-transfer-errors
  #{:debit_account_not_found
    :credit_account_not_found
    :pending_transfer_not_found
    :exceeds_credits
    :exceeds_debits
    :debit_account_already_closed
    :credit_account_already_closed})

(def global
  {::accounts {}
   ::transfers {}
   ::pending-transfer-status {}
   ::failed-transfer-ids {}
   ::mutation-outcomes []
   ::account-events []
   ::create-account-commands []
   ::create-transfer-commands []
   ::clock-max 20
   :clock/now 0})

(defn pop-front [xs]
  (vec (rest xs)))

(defn boolv [v]
  (true? v))

(defn max-object-timestamp [db]
  (let [account-ts (map :timestamp (vals (::accounts db)))
        transfer-ts (map :timestamp (vals (::transfers db)))]
    (reduce max 0 (concat account-ts transfer-ts))))

(defn next-cluster-timestamp [db]
  (inc (max (:clock/now db)
            (max-object-timestamp db))))

(defn valid-id? [id]
  (and (integer? id)
       (pos? id)
       (not= id integer-max)))

(defn account-flags-from-command [command]
  {:debits_must_not_exceed_credits (boolv (:debits-must-not-exceed-credits command))
   :credits_must_not_exceed_debits (boolv (:credits-must-not-exceed-debits command))
   :history (boolv (:history command))
   :imported (boolv (:imported command))
   :closed (boolv (:closed command))})

(defn account-shape-from-command [command]
  {:id (:id command)
   :ledger (:ledger command)
   :code (:code command)
   :user-data-128 (or (:user-data-128 command) 0)
   :user-data-64 (or (:user-data-64 command) 0)
   :user-data-32 (or (:user-data-32 command) 0)
   :flags (account-flags-from-command command)})

(defn account-shape-from-state [account]
  {:id (:id account)
   :ledger (:ledger account)
   :code (:code account)
   :user-data-128 (:user-data-128 account)
   :user-data-64 (:user-data-64 account)
   :user-data-32 (:user-data-32 account)
   :flags (:flags account)})

(defn account-command-matches-existing? [command account]
  (= (account-shape-from-command command)
     (account-shape-from-state account)))

(defn account-mismatch-reason [command account]
  (let [flags-c (account-flags-from-command command)
        flags-a (:flags account)]
    (cond
      (not= flags-c flags-a) :exists_with_different_flags
      (not= (or (:user-data-128 command) 0) (:user-data-128 account))
      :exists_with_different_user_data_128
      (not= (or (:user-data-64 command) 0) (:user-data-64 account))
      :exists_with_different_user_data_64
      (not= (or (:user-data-32 command) 0) (:user-data-32 account))
      :exists_with_different_user_data_32
      (not= (:ledger command) (:ledger account))
      :exists_with_different_ledger
      (not= (:code command) (:code account))
      :exists_with_different_code
      :else :exists)))

(defn record-mutation
  ([db command-id result]
   (record-mutation db command-id result nil))
  ([db command-id result reason]
   (update db ::mutation-outcomes conj
           {:command-id command-id
            :result result
            :reason reason})))

(defn imported-timestamp-valid? [db command]
  (let [ts (:timestamp command)]
    (and (integer? ts)
         (pos? ts)
         (< ts (:clock/now db))
         (> ts (max-object-timestamp db)))))

(defn transfer-mode [command]
  (or (:mode command) :single-phase))

(defn transfer-flags [command]
  {:pending (= :pending (transfer-mode command))
   :post_pending_transfer (= :post-pending (transfer-mode command))
   :void_pending_transfer (= :void-pending (transfer-mode command))
   :balancing_debit (boolv (:balancing-debit command))
   :balancing_credit (boolv (:balancing-credit command))
   :closing_debit (boolv (:closing-debit command))
   :closing_credit (boolv (:closing-credit command))
   :imported (boolv (:imported command))})

(defn transfer-shape-from-command [command]
  {:id (:id command)
   :debit-account-id (:debit-account-id command)
   :credit-account-id (:credit-account-id command)
   :pending-id (or (:pending-id command) 0)
   :timeout (or (:timeout command) 0)
   :ledger (:ledger command)
   :code (:code command)
   :user-data-128 (or (:user-data-128 command) 0)
   :user-data-64 (or (:user-data-64 command) 0)
   :user-data-32 (or (:user-data-32 command) 0)
   :flags (transfer-flags command)
   :mode (transfer-mode command)})

(defn transfer-shape-from-state [transfer]
  {:id (:id transfer)
   :debit-account-id (:debit-account-id transfer)
   :credit-account-id (:credit-account-id transfer)
   :pending-id (:pending-id transfer)
   :timeout (:timeout transfer)
   :ledger (:ledger transfer)
   :code (:code transfer)
   :user-data-128 (:user-data-128 transfer)
   :user-data-64 (:user-data-64 transfer)
   :user-data-32 (:user-data-32 transfer)
   :flags (:flags transfer)
   :mode (:mode transfer)})

(defn transfer-command-matches-existing? [db command transfer]
  (let [flags (:flags transfer)
        transfer-mode* (:mode transfer)]
    (if (or (:post_pending_transfer flags) (:void_pending_transfer flags))
      (let [pending-transfer (get-in db [::transfers (:pending-id transfer)])
            expected-amount (if (= transfer-mode* :void-pending)
                              (if (zero? (or (:amount command) 0))
                                (:amount pending-transfer)
                                (:amount command))
                              (if (= integer-max (or (:amount command) 0))
                                (:amount pending-transfer)
                                (or (:amount command) 0)))
            user-data-128 (if (zero? (or (:user-data-128 command) 0))
                            (:user-data-128 pending-transfer)
                            (:user-data-128 command))
            user-data-64 (if (zero? (or (:user-data-64 command) 0))
                           (:user-data-64 pending-transfer)
                           (:user-data-64 command))
            user-data-32 (if (zero? (or (:user-data-32 command) 0))
                           (:user-data-32 pending-transfer)
                           (:user-data-32 command))
            debit-id (if (zero? (or (:debit-account-id command) 0))
                       (:debit-account-id pending-transfer)
                       (:debit-account-id command))
            credit-id (if (zero? (or (:credit-account-id command) 0))
                        (:credit-account-id pending-transfer)
                        (:credit-account-id command))
            ledger (if (zero? (or (:ledger command) 0))
                     (:ledger pending-transfer)
                     (:ledger command))
            code (if (zero? (or (:code command) 0))
                   (:code pending-transfer)
                   (:code command))]
        (and (= expected-amount (:amount transfer))
             (= debit-id (:debit-account-id transfer))
             (= credit-id (:credit-account-id transfer))
             (= ledger (:ledger transfer))
             (= code (:code transfer))
             (= user-data-128 (:user-data-128 transfer))
             (= user-data-64 (:user-data-64 transfer))
             (= user-data-32 (:user-data-32 transfer))
             (= (or (:pending-id command) 0) (:pending-id transfer))
             (= (transfer-mode command) transfer-mode*)))
      (let [shape-c (transfer-shape-from-command command)
            shape-t (transfer-shape-from-state transfer)
            amount-c (or (:amount command) 0)
            amount-t (:amount transfer)]
        (and (= (dissoc shape-c :id)
                (dissoc shape-t :id))
             (if (or (:balancing_debit (:flags transfer))
                     (:balancing_credit (:flags transfer)))
               (>= amount-c amount-t)
               (= amount-c amount-t)))))))

(defn transfer-mismatch-reason [command transfer]
  (let [shape-c (transfer-shape-from-command command)
        shape-t (transfer-shape-from-state transfer)]
    (cond
      (not= (:flags shape-c) (:flags shape-t)) :exists_with_different_flags
      (not= (:pending-id shape-c) (:pending-id shape-t)) :exists_with_different_pending_id
      (not= (:timeout shape-c) (:timeout shape-t)) :exists_with_different_timeout
      (not= (:debit-account-id shape-c) (:debit-account-id shape-t))
      :exists_with_different_debit_account_id
      (not= (:credit-account-id shape-c) (:credit-account-id shape-t))
      :exists_with_different_credit_account_id
      (not= (or (:amount command) 0) (:amount transfer)) :exists_with_different_amount
      (not= (:user-data-128 shape-c) (:user-data-128 shape-t))
      :exists_with_different_user_data_128
      (not= (:user-data-64 shape-c) (:user-data-64 shape-t))
      :exists_with_different_user_data_64
      (not= (:user-data-32 shape-c) (:user-data-32 shape-t))
      :exists_with_different_user_data_32
      (not= (:ledger shape-c) (:ledger shape-t)) :exists_with_different_ledger
      (not= (:code shape-c) (:code shape-t)) :exists_with_different_code
      :else :exists)))

(defn amount-for-balancing [command debit-account credit-account]
  (let [requested (or (:amount command) 0)
        debit-room (max 0
                        (- (:credits-posted debit-account)
                           (+ (:debits-pending debit-account)
                              (:debits-posted debit-account))))
        credit-room (max 0
                         (- (:debits-posted credit-account)
                            (+ (:credits-pending credit-account)
                               (:credits-posted credit-account))))
        for-debit (if (boolv (:balancing-debit command))
                    (min requested debit-room)
                    requested)]
    (if (boolv (:balancing-credit command))
      (min for-debit credit-room)
      for-debit)))

(defn debit-exceeds-credits? [account amount]
  (and (get-in account [:flags :debits_must_not_exceed_credits])
       (> (+ (:debits-pending account)
             (:debits-posted account)
             amount)
          (:credits-posted account))))

(defn credit-exceeds-debits? [account amount]
  (and (get-in account [:flags :credits_must_not_exceed_debits])
       (> (+ (:credits-pending account)
             (:credits-posted account)
             amount)
          (:debits-posted account))))

(defn append-account-event [db event]
  (update db ::account-events conj event))

(defn mark-transient-failure [db transfer-id reason]
  (if (contains? transient-transfer-errors reason)
    (assoc-in db [::failed-transfer-ids transfer-id] reason)
    db))

(defn effective-timestamp [db command]
  (if (boolv (:imported command))
    (:timestamp command)
    (next-cluster-timestamp db)))

(defn create-account-rejection-reason [db command]
  (cond
    (not (valid-id? (:id command)))
    (if (zero? (:id command))
      :id_must_not_be_zero
      :id_must_not_be_int_max)

    (and (boolv (:debits-must-not-exceed-credits command))
         (boolv (:credits-must-not-exceed-debits command)))
    :flags_are_mutually_exclusive

    (not= 0 (or (:debits-pending command) 0))
    :debits_pending_must_be_zero
    (not= 0 (or (:debits-posted command) 0))
    :debits_posted_must_be_zero
    (not= 0 (or (:credits-pending command) 0))
    :credits_pending_must_be_zero
    (not= 0 (or (:credits-posted command) 0))
    :credits_posted_must_be_zero
    (zero? (or (:ledger command) 0))
    :ledger_must_not_be_zero
    (zero? (or (:code command) 0))
    :code_must_not_be_zero

    (and (boolv (:imported command))
         (not (imported-timestamp-valid? db command)))
    :imported_event_timestamp_invalid

    (and (not (boolv (:imported command)))
         (not (zero? (or (:timestamp command) 0))))
    :timestamp_must_be_zero

    :else nil))

(r/defproc create-account
  (fn [{:keys [::create-account-commands ::accounts] :as db}]
    (when (seq create-account-commands)
      (let [command (first create-account-commands)
            db* (update db ::create-account-commands pop-front)
            existing (get accounts (:id command))]
        (cond
          existing
          (if (account-command-matches-existing? command existing)
            (record-mutation db* (:id command) :exists)
            (record-mutation db* (:id command) :rejected
                             (account-mismatch-reason command existing)))

          :else
          (if-let [reason (create-account-rejection-reason db* command)]
            (record-mutation db* (:id command) :rejected reason)
            (let [timestamp (effective-timestamp db* command)
                  account {:id (:id command)
                           :ledger (:ledger command)
                           :code (:code command)
                           :user-data-128 (or (:user-data-128 command) 0)
                           :user-data-64 (or (:user-data-64 command) 0)
                           :user-data-32 (or (:user-data-32 command) 0)
                           :debits-pending 0
                           :debits-posted 0
                           :credits-pending 0
                           :credits-posted 0
                           :flags (account-flags-from-command command)
                           :timestamp timestamp}]
              (-> db*
                  (assoc-in [::accounts (:id command)] account)
                  (assoc :clock/now (max (:clock/now db*) timestamp))
                  (record-mutation (:id command) :ok)))))))))

(defn regular-transfer-rejection-reason [db command]
  (let [mode (transfer-mode command)
        flags (transfer-flags command)]
    (cond
      (not (valid-id? (:id command)))
      (if (zero? (:id command))
        :id_must_not_be_zero
        :id_must_not_be_int_max)

      (and (:post_pending_transfer flags) (:void_pending_transfer flags))
      :flags_are_mutually_exclusive

      (and (not= mode :pending)
           (not (zero? (or (:timeout command) 0))))
      :timeout_reserved_for_pending_transfer

      (and (not= mode :pending)
           (or (:closing_debit flags) (:closing_credit flags)))
      :closing_transfer_must_be_pending

      (not (zero? (or (:pending-id command) 0)))
      :pending_id_must_be_zero

      (zero? (or (:debit-account-id command) 0))
      :debit_account_id_must_not_be_zero
      (= integer-max (or (:debit-account-id command) 0))
      :debit_account_id_must_not_be_int_max

      (zero? (or (:credit-account-id command) 0))
      :credit_account_id_must_not_be_zero
      (= integer-max (or (:credit-account-id command) 0))
      :credit_account_id_must_not_be_int_max

      (= (:debit-account-id command) (:credit-account-id command))
      :accounts_must_be_different

      (zero? (or (:ledger command) 0))
      :ledger_must_not_be_zero
      (zero? (or (:code command) 0))
      :code_must_not_be_zero

      (and (boolv (:imported command))
           (not (imported-timestamp-valid? db command)))
      :imported_event_timestamp_must_not_regress

      (and (not (boolv (:imported command)))
           (not (zero? (or (:timestamp command) 0))))
      :timestamp_must_be_zero

      :else nil)))

(defn apply-regular-transfer [db command]
  (let [debit (get-in db [::accounts (:debit-account-id command)])
        credit (get-in db [::accounts (:credit-account-id command)])]
    (cond
      (nil? debit)
      {:ok? false :reason :debit_account_not_found}

      (nil? credit)
      {:ok? false :reason :credit_account_not_found}

      (not= (:ledger debit) (:ledger credit))
      {:ok? false :reason :accounts_must_have_the_same_ledger}

      (not= (:ledger command) (:ledger debit))
      {:ok? false :reason :transfer_must_have_the_same_ledger_as_accounts}

      (:closed (:flags debit))
      {:ok? false :reason :debit_account_already_closed}

      (:closed (:flags credit))
      {:ok? false :reason :credit_account_already_closed}

      :else
      (let [amount (amount-for-balancing command debit credit)]
        (cond
          (debit-exceeds-credits? debit amount)
          {:ok? false :reason :exceeds_credits}

          (credit-exceeds-debits? credit amount)
          {:ok? false :reason :exceeds_debits}

          :else
          (let [timestamp (effective-timestamp db command)
                mode (transfer-mode command)
                transfer {:id (:id command)
                          :debit-account-id (:debit-account-id command)
                          :credit-account-id (:credit-account-id command)
                          :requested-amount (or (:amount command) 0)
                          :amount amount
                          :pending-id 0
                          :user-data-128 (or (:user-data-128 command) 0)
                          :user-data-64 (or (:user-data-64 command) 0)
                          :user-data-32 (or (:user-data-32 command) 0)
                          :timeout (or (:timeout command) 0)
                          :ledger (:ledger command)
                          :code (:code command)
                          :flags (transfer-flags command)
                          :mode mode
                          :timestamp timestamp}
                debit* (cond-> debit
                         (= mode :pending)
                         (update :debits-pending + amount)
                         (not= mode :pending)
                         (update :debits-posted + amount)
                         (boolv (:closing-debit command))
                         (assoc-in [:flags :closed] true))
                credit* (cond-> credit
                          (= mode :pending)
                          (update :credits-pending + amount)
                          (not= mode :pending)
                          (update :credits-posted + amount)
                          (boolv (:closing-credit command))
                          (assoc-in [:flags :closed] true))
                db* (-> db
                        (assoc-in [::transfers (:id command)] transfer)
                        (assoc-in [::accounts (:id debit)] debit*)
                        (assoc-in [::accounts (:id credit)] credit*)
                        (assoc :clock/now (max (:clock/now db) timestamp))
                        (append-account-event
                         {:timestamp timestamp
                          :event-type (if (= mode :pending)
                                        :two_phase_pending
                                        :single_phase)
                          :transfer-id (:id command)
                          :transfer-pending-id nil
                          :debit-account-id (:id debit)
                          :credit-account-id (:id credit)
                          :debit-balances (select-keys debit* [:debits-pending
                                                               :debits-posted
                                                               :credits-pending
                                                               :credits-posted])
                          :credit-balances (select-keys credit* [:debits-pending
                                                                 :debits-posted
                                                                 :credits-pending
                                                                 :credits-posted])
                          :amount-requested (or (:amount command) 0)
                          :amount amount}))]
            (if (= mode :pending)
              {:ok? true
               :db (assoc-in db* [::pending-transfer-status (:id command)]
                             {:status :pending
                              :expires-at (when (pos? (or (:timeout command) 0))
                                            (+ timestamp (or (:timeout command) 0)))})}
              {:ok? true
               :db db*})))))))

(defn apply-post-or-void-transfer [db command]
  (let [mode (transfer-mode command)
        flags (transfer-flags command)
        pending-id (or (:pending-id command) 0)]
    (cond
      (and (:post_pending_transfer flags) (:void_pending_transfer flags))
      {:ok? false :reason :flags_are_mutually_exclusive}

      (:pending flags)
      {:ok? false :reason :flags_are_mutually_exclusive}

      (or (:balancing_debit flags)
          (:balancing_credit flags)
          (:closing_debit flags)
          (:closing_credit flags))
      {:ok? false :reason :flags_are_mutually_exclusive}

      (zero? pending-id)
      {:ok? false :reason :pending_id_must_not_be_zero}

      (= pending-id integer-max)
      {:ok? false :reason :pending_id_must_not_be_int_max}

      (= pending-id (:id command))
      {:ok? false :reason :pending_id_must_be_different}

      (not (zero? (or (:timeout command) 0)))
      {:ok? false :reason :timeout_reserved_for_pending_transfer}

      :else
      (if-let [pending-transfer (get-in db [::transfers pending-id])]
        (cond
          (not= :pending (:mode pending-transfer))
          {:ok? false :reason :pending_transfer_not_pending}

          (and (pos? (or (:debit-account-id command) 0))
               (not= (:debit-account-id command) (:debit-account-id pending-transfer)))
          {:ok? false :reason :pending_transfer_has_different_debit_account_id}

          (and (pos? (or (:credit-account-id command) 0))
               (not= (:credit-account-id command) (:credit-account-id pending-transfer)))
          {:ok? false :reason :pending_transfer_has_different_credit_account_id}

          (and (pos? (or (:ledger command) 0))
               (not= (:ledger command) (:ledger pending-transfer)))
          {:ok? false :reason :pending_transfer_has_different_ledger}

          (and (pos? (or (:code command) 0))
               (not= (:code command) (:code pending-transfer)))
          {:ok? false :reason :pending_transfer_has_different_code}

          :else
          (let [pending-state (get-in db [::pending-transfer-status pending-id])
                now (:clock/now db)]
            (cond
              (nil? pending-state)
              {:ok? false :reason :pending_transfer_not_found}

              (= :posted (:status pending-state))
              {:ok? false :reason :pending_transfer_already_posted}

              (= :voided (:status pending-state))
              {:ok? false :reason :pending_transfer_already_voided}

              (= :expired (:status pending-state))
              {:ok? false :reason :pending_transfer_expired}

              (and (some? (:expires-at pending-state))
                   (<= (:expires-at pending-state) now))
              {:ok? false :reason :pending_transfer_expired}

              :else
              (let [requested (or (:amount command) 0)
                    amount (if (= mode :void-pending)
                             (if (zero? requested)
                               (:amount pending-transfer)
                               requested)
                             (if (= requested integer-max)
                               (:amount pending-transfer)
                               requested))]
                (cond
                  (> amount (:amount pending-transfer))
                  {:ok? false :reason :exceeds_pending_transfer_amount}

                  (and (= mode :void-pending)
                       (< amount (:amount pending-transfer)))
                  {:ok? false :reason :pending_transfer_has_different_amount}

                  :else
                  (let [debit (get-in db [::accounts (:debit-account-id pending-transfer)])
                        credit (get-in db [::accounts (:credit-account-id pending-transfer)])]
                    (cond
                      (nil? debit)
                      {:ok? false :reason :debit_account_not_found}

                      (nil? credit)
                      {:ok? false :reason :credit_account_not_found}

                      (and (:closed (:flags debit))
                           (= mode :post-pending))
                      {:ok? false :reason :debit_account_already_closed}

                      (and (:closed (:flags credit))
                           (= mode :post-pending))
                      {:ok? false :reason :credit_account_already_closed}

                      :else
                      (let [timestamp (effective-timestamp db command)
                            transfer {:id (:id command)
                                      :debit-account-id (:debit-account-id pending-transfer)
                                      :credit-account-id (:credit-account-id pending-transfer)
                                      :requested-amount requested
                                      :amount amount
                                      :pending-id pending-id
                                      :user-data-128 (if (zero? (or (:user-data-128 command) 0))
                                                       (:user-data-128 pending-transfer)
                                                       (:user-data-128 command))
                                      :user-data-64 (if (zero? (or (:user-data-64 command) 0))
                                                      (:user-data-64 pending-transfer)
                                                      (:user-data-64 command))
                                      :user-data-32 (if (zero? (or (:user-data-32 command) 0))
                                                      (:user-data-32 pending-transfer)
                                                      (:user-data-32 command))
                                      :timeout 0
                                      :ledger (:ledger pending-transfer)
                                      :code (:code pending-transfer)
                                      :flags flags
                                      :mode mode
                                      :timestamp timestamp}
                            debit' (-> debit
                                       (update :debits-pending - (:amount pending-transfer))
                                       (cond->
                                        (= mode :post-pending)
                                        (update :debits-posted + amount)
                                        (and (= mode :void-pending)
                                             (boolv (get-in pending-transfer [:flags :closing_debit])))
                                        (assoc-in [:flags :closed] false)))
                            credit' (-> credit
                                        (update :credits-pending - (:amount pending-transfer))
                                        (cond->
                                         (= mode :post-pending)
                                         (update :credits-posted + amount)
                                         (and (= mode :void-pending)
                                              (boolv (get-in pending-transfer [:flags :closing_credit])))
                                         (assoc-in [:flags :closed] false)))
                            status (if (= mode :post-pending) :posted :voided)]
                        {:ok? true
                         :db (-> db
                                 (assoc-in [::transfers (:id command)] transfer)
                                 (assoc-in [::accounts (:id debit)] debit')
                                 (assoc-in [::accounts (:id credit)] credit')
                                 (assoc-in [::pending-transfer-status pending-id :status] status)
                                 (assoc :clock/now (max (:clock/now db) timestamp))
                                 (append-account-event
                                  {:timestamp timestamp
                                   :event-type (if (= mode :post-pending)
                                                 :two_phase_posted
                                                 :two_phase_voided)
                                   :transfer-id (:id command)
                                   :transfer-pending-id pending-id
                                   :debit-account-id (:id debit)
                                   :credit-account-id (:id credit)
                                   :debit-balances (select-keys debit' [:debits-pending
                                                                        :debits-posted
                                                                        :credits-pending
                                                                        :credits-posted])
                                   :credit-balances (select-keys credit' [:debits-pending
                                                                          :debits-posted
                                                                          :credits-pending
                                                                          :credits-posted])
                                   :amount-requested requested
                                   :amount amount}))}))))))))
        {:ok? false :reason :pending_transfer_not_found}))))

(r/defproc create-transfer
  (fn [{:keys [::create-account-commands ::create-transfer-commands ::transfers
               ::failed-transfer-ids] :as db}]
    (when (and (empty? create-account-commands)
               (seq create-transfer-commands))
      (let [command (first create-transfer-commands)
            db* (update db ::create-transfer-commands pop-front)
            existing (get transfers (:id command))]
        (cond
          (contains? failed-transfer-ids (:id command))
          (record-mutation db* (:id command) :rejected :id_already_failed)

          existing
          (if (transfer-command-matches-existing? db* command existing)
            (record-mutation db* (:id command) :exists)
            (record-mutation db* (:id command) :rejected
                             (transfer-mismatch-reason command existing)))

          :else
          (if-let [reason (regular-transfer-rejection-reason db* command)]
            (-> db*
                (record-mutation (:id command) :rejected reason)
                (mark-transient-failure (:id command) reason))
            (let [result (if (contains? #{:post-pending :void-pending}
                                        (transfer-mode command))
                           (apply-post-or-void-transfer db* command)
                           (apply-regular-transfer db* command))]
              (if (:ok? result)
                (record-mutation (:db result) (:id command) :ok)
                (-> db*
                    (record-mutation (:id command) :rejected (:reason result))
                    (mark-transient-failure (:id command) (:reason result)))))))))))

(r/defproc expire-pending-transfers
  (fn [{:keys [::pending-transfer-status ::transfers ::accounts :clock/now] :as db}]
    (let [updates
          (for [[transfer-id pending] pending-transfer-status
                :let [status (:status pending)
                      expires-at (:expires-at pending)]
                :when (and (= status :pending)
                           (some? expires-at)
                           (<= expires-at now))]
            transfer-id)]
      (when (seq updates)
        (reduce
         (fn [acc transfer-id]
           (let [transfer (get-in acc [::transfers transfer-id])
                 debit (get-in acc [::accounts (:debit-account-id transfer)])
                 credit (get-in acc [::accounts (:credit-account-id transfer)])
                 debit' (-> debit
                            (update :debits-pending - (:amount transfer))
                            (cond->
                             (boolv (get-in transfer [:flags :closing_debit]))
                             (assoc-in [:flags :closed] false)))
                 credit' (-> credit
                             (update :credits-pending - (:amount transfer))
                             (cond->
                              (boolv (get-in transfer [:flags :closing_credit]))
                              (assoc-in [:flags :closed] false)))
                 timestamp (next-cluster-timestamp acc)]
             (-> acc
                 (assoc :clock/now timestamp)
                 (assoc-in [::pending-transfer-status transfer-id :status] :expired)
                 (assoc-in [::accounts (:id debit)] debit')
                 (assoc-in [::accounts (:id credit)] credit')
                 (append-account-event
                  {:timestamp timestamp
                   :event-type :two_phase_expired
                   :transfer-id nil
                   :transfer-pending-id transfer-id
                   :debit-account-id (:id debit)
                   :credit-account-id (:id credit)
                   :debit-balances (select-keys debit' [:debits-pending
                                                        :debits-posted
                                                        :credits-pending
                                                        :credits-posted])
                   :credit-balances (select-keys credit' [:debits-pending
                                                          :debits-posted
                                                          :credits-pending
                                                          :credits-posted])
                   :amount-requested 0
                   :amount (:amount transfer)}))))
         db
         updates)))))

(r/defproc advance-time
  (fn [{:keys [::create-account-commands ::create-transfer-commands
               ::clock-max :clock/now] :as db}]
    (when (and (empty? create-account-commands)
               (empty? create-transfer-commands)
               (< now clock-max))
      (update db :clock/now inc))))

(rh/definvariant balances-are-conserved
  [{:keys [::accounts]}]
  (let [accounts (vals accounts)
        sum-debits-pending (reduce + 0 (map :debits-pending accounts))
        sum-credits-pending (reduce + 0 (map :credits-pending accounts))
        sum-debits-posted (reduce + 0 (map :debits-posted accounts))
        sum-credits-posted (reduce + 0 (map :credits-posted accounts))]
    (and (= sum-debits-pending sum-credits-pending)
         (= sum-debits-posted sum-credits-posted))))

(rh/definvariant pending-status-references-pending-transfer
  [{:keys [::pending-transfer-status ::transfers]}]
  (every?
   (fn [[transfer-id pending]]
     (and (contains? transfers transfer-id)
          (= :pending (:mode (get transfers transfer-id)))
          (contains? #{:pending :posted :voided :expired} (:status pending))))
   pending-transfer-status))

(rh/definvariant transient-failed-ids-never-commit
  [{:keys [::failed-transfer-ids ::transfers]}]
  (every?
   (fn [transfer-id]
     (not (contains? transfers transfer-id)))
   (keys failed-transfer-ids)))

(rh/definvariant account-events-reference-consistent-ledger
  [{:keys [::account-events ::accounts]}]
  (every?
   (fn [event]
     (let [debit (get accounts (:debit-account-id event))
           credit (get accounts (:credit-account-id event))]
       (and debit credit (= (:ledger debit) (:ledger credit)))))
   account-events))

(def components
  #{create-account
    create-transfer
    expire-pending-transfers
    advance-time
    balances-are-conserved
    pending-status-references-pending-transfer
    transient-failed-ids-never-commit
    account-events-reference-consistent-ledger})

(def scenario-global
  (-> global
      (assoc :clock/now 10)
      (assoc ::clock-max 25)
      (assoc ::create-account-commands
             [{:id 1 :ledger 700 :code 10
               :user-data-128 0 :user-data-64 0 :user-data-32 0
               :debits-must-not-exceed-credits false
               :credits-must-not-exceed-debits false
               :history true
               :imported false
               :closed false
               :timestamp 0
               :linked false}
              {:id 2 :ledger 700 :code 10
               :user-data-128 0 :user-data-64 0 :user-data-32 0
               :debits-must-not-exceed-credits false
               :credits-must-not-exceed-debits false
               :history true
               :imported false
               :closed false
               :timestamp 0
               :linked false}])
      (assoc ::create-transfer-commands
             [{:id 100
               :debit-account-id 1
               :credit-account-id 2
               :amount 20
               :pending-id 0
               :user-data-128 0 :user-data-64 0 :user-data-32 0
               :timeout 0
               :ledger 700
               :code 10
               :mode :single-phase
               :balancing-debit false
               :balancing-credit false
               :closing-debit false
               :closing-credit false
               :imported false
               :timestamp 0
               :linked false}
              {:id 101
               :debit-account-id 1
               :credit-account-id 2
               :amount 50
               :pending-id 0
               :user-data-128 0 :user-data-64 0 :user-data-32 0
               :timeout 2
               :ledger 700
               :code 10
               :mode :pending
               :balancing-debit false
               :balancing-credit false
               :closing-debit false
               :closing-credit false
               :imported false
               :timestamp 0
               :linked false}
              {:id 102
               :debit-account-id 1
               :credit-account-id 2
               :amount 20
               :pending-id 101
               :user-data-128 0 :user-data-64 0 :user-data-32 0
               :timeout 0
               :ledger 700
               :code 10
               :mode :post-pending
               :balancing-debit false
               :balancing-credit false
               :closing-debit false
               :closing-credit false
               :imported false
               :timestamp 0
               :linked false}
              {:id 103
               :debit-account-id 1
               :credit-account-id 2
               :amount 30
               :pending-id 0
               :user-data-128 0 :user-data-64 0 :user-data-32 0
               :timeout 1
               :ledger 700
               :code 10
               :mode :pending
               :balancing-debit false
               :balancing-credit false
               :closing-debit false
               :closing-credit true
               :imported false
               :timestamp 0
               :linked false}])))
