---- MODULE LedgerStateMachine ----
EXTENDS Naturals, Integers, Sequences, TLC

(***************************************************************************)
(* Distilled from code/docs:                                               *)
(* - src/state_machine.zig (create_account/create_transfer/post_or_void/   *)
(*   execute_expire_pending_transfers)                                     *)
(* - src/tigerbeetle.zig (error/result enums, account/transfer flags)      *)
(* - docs/coding/two-phase-transfers.md                                    *)
(***************************************************************************)

CONSTANTS IntMax, MaxClock

ModeSet == {"single_phase", "pending", "post_pending", "void_pending"}
PendingStatusSet == {"none", "pending", "posted", "voided", "expired"}
OutcomeSet == {"ok", "exists", "rejected"}
EventTypeSet == {
  "single_phase",
  "two_phase_pending",
  "two_phase_posted",
  "two_phase_voided",
  "two_phase_expired"
}

AccountIds == {1, 2, 3}
TransferIds == {101, 102, 103, 104, 105}

TransientReasons == {
  "debit_account_not_found",
  "credit_account_not_found",
  "pending_transfer_not_found",
  "exceeds_credits",
  "exceeds_debits",
  "debit_account_already_closed",
  "credit_account_already_closed"
}

AccountFlagsRec == [
  linked : BOOLEAN,
  debits_must_not_exceed_credits : BOOLEAN,
  credits_must_not_exceed_debits : BOOLEAN,
  history : BOOLEAN,
  imported : BOOLEAN,
  closed : BOOLEAN
]

TransferFlagsRec == [
  linked : BOOLEAN,
  pending : BOOLEAN,
  post_pending_transfer : BOOLEAN,
  void_pending_transfer : BOOLEAN,
  balancing_debit : BOOLEAN,
  balancing_credit : BOOLEAN,
  closing_debit : BOOLEAN,
  closing_credit : BOOLEAN,
  imported : BOOLEAN
]

AccountRec == [
  id : Nat,
  debits_pending : Nat,
  debits_posted : Nat,
  credits_pending : Nat,
  credits_posted : Nat,
  user_data_128 : Nat,
  user_data_64 : Nat,
  user_data_32 : Nat,
  ledger : Nat,
  code : Nat,
  flags : AccountFlagsRec,
  timestamp : Nat
]

TransferRec == [
  id : Nat,
  debit_account_id : Nat,
  credit_account_id : Nat,
  amount : Nat,
  pending_id : Nat,
  user_data_128 : Nat,
  user_data_64 : Nat,
  user_data_32 : Nat,
  timeout : Nat,
  ledger : Nat,
  code : Nat,
  flags : TransferFlagsRec,
  timestamp : Nat,
  mode : ModeSet
]

PendingRec == [status : PendingStatusSet, expires_at : Nat]

AccountCommandRec == [
  id : Nat,
  debits_pending : Nat,
  debits_posted : Nat,
  credits_pending : Nat,
  credits_posted : Nat,
  user_data_128 : Nat,
  user_data_64 : Nat,
  user_data_32 : Nat,
  ledger : Nat,
  code : Nat,
  flags : AccountFlagsRec,
  timestamp : Nat
]

TransferCommandRec == [
  id : Nat,
  debit_account_id : Nat,
  credit_account_id : Nat,
  amount : Nat,
  pending_id : Nat,
  user_data_128 : Nat,
  user_data_64 : Nat,
  user_data_32 : Nat,
  timeout : Nat,
  ledger : Nat,
  code : Nat,
  flags : TransferFlagsRec,
  timestamp : Nat,
  mode : ModeSet
]

OutcomeRec == [command_id : Nat, result : OutcomeSet, reason : STRING]

AccountEventRec == [
  timestamp : Nat,
  event_type : EventTypeSet,
  transfer_id : Nat,
  pending_id : Nat,
  debit_account_id : Nat,
  credit_account_id : Nat,
  amount_requested : Nat,
  amount : Nat,
  ledger : Nat,
  pending_status : PendingStatusSet
]

NoAccount == [
  id |-> 0,
  debits_pending |-> 0,
  debits_posted |-> 0,
  credits_pending |-> 0,
  credits_posted |-> 0,
  user_data_128 |-> 0,
  user_data_64 |-> 0,
  user_data_32 |-> 0,
  ledger |-> 0,
  code |-> 0,
  flags |-> [
    linked |-> FALSE,
    debits_must_not_exceed_credits |-> FALSE,
    credits_must_not_exceed_debits |-> FALSE,
    history |-> FALSE,
    imported |-> FALSE,
    closed |-> FALSE
  ],
  timestamp |-> 0
]

NoTransfer == [
  id |-> 0,
  debit_account_id |-> 0,
  credit_account_id |-> 0,
  amount |-> 0,
  pending_id |-> 0,
  user_data_128 |-> 0,
  user_data_64 |-> 0,
  user_data_32 |-> 0,
  timeout |-> 0,
  ledger |-> 0,
  code |-> 0,
  flags |-> [
    linked |-> FALSE,
    pending |-> FALSE,
    post_pending_transfer |-> FALSE,
    void_pending_transfer |-> FALSE,
    balancing_debit |-> FALSE,
    balancing_credit |-> FALSE,
    closing_debit |-> FALSE,
    closing_credit |-> FALSE,
    imported |-> FALSE
  ],
  timestamp |-> 0,
  mode |-> "single_phase"
]

NoPending == [status |-> "none", expires_at |-> 0]

VARIABLES
  accounts,
  transfers,
  pending,
  failed_transfer_ids,
  account_events,
  outcomes,
  create_account_queue,
  create_transfer_queue,
  clock

vars == <<
  accounts,
  transfers,
  pending,
  failed_transfer_ids,
  account_events,
  outcomes,
  create_account_queue,
  create_transfer_queue,
  clock
>>

IsPresentAccount(a) == a.id # 0
IsPresentTransfer(t) == t.id # 0

AccountFor(id) == IF id \in AccountIds THEN accounts[id] ELSE NoAccount
TransferFor(id) == IF id \in TransferIds THEN transfers[id] ELSE NoTransfer
PendingFor(id) == IF id \in TransferIds THEN pending[id] ELSE NoPending

Max2(a, b) == IF a >= b THEN a ELSE b
Min2(a, b) == IF a <= b THEN a ELSE b

MaxAccountTimestamp ==
  Max2(Max2(accounts[1].timestamp, accounts[2].timestamp), accounts[3].timestamp)

MaxTransferTimestamp ==
  Max2(
    Max2(transfers[101].timestamp, transfers[102].timestamp),
    Max2(
      transfers[103].timestamp,
      Max2(transfers[104].timestamp, transfers[105].timestamp)
    )
  )

MaxObjectTimestamp == Max2(MaxAccountTimestamp, MaxTransferTimestamp)

EffectiveTimestamp(cmd) ==
  IF cmd.flags.imported THEN cmd.timestamp ELSE Max2(clock, MaxObjectTimestamp) + 1

RecordOutcome(command_id, result, reason) ==
  [command_id |-> command_id, result |-> result, reason |-> reason]

AccountCommandMatchesExisting(cmd, e) ==
  /\ cmd.id = e.id
  /\ cmd.user_data_128 = e.user_data_128
  /\ cmd.user_data_64 = e.user_data_64
  /\ cmd.user_data_32 = e.user_data_32
  /\ cmd.ledger = e.ledger
  /\ cmd.code = e.code
  /\ cmd.flags = e.flags

ExistingAccountMismatchReason(cmd, e) ==
  IF cmd.flags # e.flags THEN "exists_with_different_flags"
  ELSE IF cmd.user_data_128 # e.user_data_128 THEN "exists_with_different_user_data_128"
  ELSE IF cmd.user_data_64 # e.user_data_64 THEN "exists_with_different_user_data_64"
  ELSE IF cmd.user_data_32 # e.user_data_32 THEN "exists_with_different_user_data_32"
  ELSE IF cmd.ledger # e.ledger THEN "exists_with_different_ledger"
  ELSE IF cmd.code # e.code THEN "exists_with_different_code"
  ELSE "exists"

CreateAccountReason(cmd) ==
  IF cmd.id = 0 THEN "id_must_not_be_zero"
  ELSE IF cmd.id = IntMax THEN "id_must_not_be_int_max"
  ELSE IF cmd.flags.debits_must_not_exceed_credits /\ cmd.flags.credits_must_not_exceed_debits
    THEN "flags_are_mutually_exclusive"
  ELSE IF cmd.debits_pending # 0 THEN "debits_pending_must_be_zero"
  ELSE IF cmd.debits_posted # 0 THEN "debits_posted_must_be_zero"
  ELSE IF cmd.credits_pending # 0 THEN "credits_pending_must_be_zero"
  ELSE IF cmd.credits_posted # 0 THEN "credits_posted_must_be_zero"
  ELSE IF cmd.ledger = 0 THEN "ledger_must_not_be_zero"
  ELSE IF cmd.code = 0 THEN "code_must_not_be_zero"
  ELSE IF ~cmd.flags.imported /\ cmd.timestamp # 0 THEN "timestamp_must_be_zero"
  ELSE IF cmd.flags.imported /\ cmd.timestamp <= MaxObjectTimestamp
    THEN "imported_event_timestamp_must_not_regress"
  ELSE "none"

TransferCommandMatchesExisting(cmd, e) ==
  IF e.mode \in {"post_pending", "void_pending"} THEN
    /\ cmd.pending_id = e.pending_id
    /\ cmd.mode = e.mode
  ELSE
    /\ cmd.pending_id = e.pending_id
    /\ cmd.timeout = e.timeout
    /\ cmd.debit_account_id = e.debit_account_id
    /\ cmd.credit_account_id = e.credit_account_id
    /\ IF e.flags.balancing_debit \/ e.flags.balancing_credit
        THEN cmd.amount >= e.amount
        ELSE cmd.amount = e.amount
    /\ cmd.user_data_128 = e.user_data_128
    /\ cmd.user_data_64 = e.user_data_64
    /\ cmd.user_data_32 = e.user_data_32
    /\ cmd.ledger = e.ledger
    /\ cmd.code = e.code
    /\ cmd.flags = e.flags

TransferMismatchReason(cmd, e) ==
  IF cmd.flags # e.flags THEN "exists_with_different_flags"
  ELSE IF cmd.pending_id # e.pending_id THEN "exists_with_different_pending_id"
  ELSE IF cmd.timeout # e.timeout THEN "exists_with_different_timeout"
  ELSE IF cmd.debit_account_id # e.debit_account_id THEN "exists_with_different_debit_account_id"
  ELSE IF cmd.credit_account_id # e.credit_account_id THEN "exists_with_different_credit_account_id"
  ELSE IF cmd.amount # e.amount THEN "exists_with_different_amount"
  ELSE IF cmd.user_data_128 # e.user_data_128 THEN "exists_with_different_user_data_128"
  ELSE IF cmd.user_data_64 # e.user_data_64 THEN "exists_with_different_user_data_64"
  ELSE IF cmd.user_data_32 # e.user_data_32 THEN "exists_with_different_user_data_32"
  ELSE IF cmd.ledger # e.ledger THEN "exists_with_different_ledger"
  ELSE IF cmd.code # e.code THEN "exists_with_different_code"
  ELSE "exists"

DebitsExceedCredits(account, amount) ==
  account.flags.debits_must_not_exceed_credits /\
  account.debits_pending + account.debits_posted + amount > account.credits_posted

CreditsExceedDebits(account, amount) ==
  account.flags.credits_must_not_exceed_debits /\
  account.credits_pending + account.credits_posted + amount > account.debits_posted

AmountForBalancing(cmd, debit, credit) ==
  LET
    requested == cmd.amount
    debit_room == IF debit.credits_posted > debit.debits_pending + debit.debits_posted
      THEN debit.credits_posted - (debit.debits_pending + debit.debits_posted)
      ELSE 0
    credit_room == IF credit.debits_posted > credit.credits_pending + credit.credits_posted
      THEN credit.debits_posted - (credit.credits_pending + credit.credits_posted)
      ELSE 0
    debit_limited == IF cmd.flags.balancing_debit THEN Min2(requested, debit_room) ELSE requested
  IN
    IF cmd.flags.balancing_credit THEN Min2(debit_limited, credit_room) ELSE debit_limited

RegularTransferReason(cmd) ==
  IF cmd.id = 0 THEN "id_must_not_be_zero"
  ELSE IF cmd.id = IntMax THEN "id_must_not_be_int_max"
  ELSE IF cmd.flags.post_pending_transfer /\ cmd.flags.void_pending_transfer
    THEN "flags_are_mutually_exclusive"
  ELSE IF cmd.pending_id # 0 THEN "pending_id_must_be_zero"
  ELSE IF cmd.debit_account_id = 0 THEN "debit_account_id_must_not_be_zero"
  ELSE IF cmd.debit_account_id = IntMax THEN "debit_account_id_must_not_be_int_max"
  ELSE IF cmd.credit_account_id = 0 THEN "credit_account_id_must_not_be_zero"
  ELSE IF cmd.credit_account_id = IntMax THEN "credit_account_id_must_not_be_int_max"
  ELSE IF cmd.debit_account_id = cmd.credit_account_id THEN "accounts_must_be_different"
  ELSE IF ~cmd.flags.pending /\ cmd.timeout # 0 THEN "timeout_reserved_for_pending_transfer"
  ELSE IF ~cmd.flags.pending /\ (cmd.flags.closing_debit \/ cmd.flags.closing_credit)
    THEN "closing_transfer_must_be_pending"
  ELSE IF cmd.ledger = 0 THEN "ledger_must_not_be_zero"
  ELSE IF cmd.code = 0 THEN "code_must_not_be_zero"
  ELSE IF ~cmd.flags.imported /\ cmd.timestamp # 0 THEN "timestamp_must_be_zero"
  ELSE IF cmd.flags.imported /\ cmd.timestamp <= MaxObjectTimestamp
    THEN "imported_event_timestamp_must_not_regress"
  ELSE "none"

PostVoidPrecheckReason(cmd) ==
  IF cmd.flags.post_pending_transfer /\ cmd.flags.void_pending_transfer
    THEN "flags_are_mutually_exclusive"
  ELSE IF cmd.flags.pending \/ cmd.flags.balancing_debit \/ cmd.flags.balancing_credit \/
          cmd.flags.closing_debit \/ cmd.flags.closing_credit
    THEN "flags_are_mutually_exclusive"
  ELSE IF cmd.pending_id = 0 THEN "pending_id_must_not_be_zero"
  ELSE IF cmd.pending_id = IntMax THEN "pending_id_must_not_be_int_max"
  ELSE IF cmd.pending_id = cmd.id THEN "pending_id_must_be_different"
  ELSE IF cmd.timeout # 0 THEN "timeout_reserved_for_pending_transfer"
  ELSE "none"

PostVoidAmount(cmd, pending_transfer) ==
  IF cmd.mode = "void_pending"
    THEN IF cmd.amount = 0 THEN pending_transfer.amount ELSE cmd.amount
    ELSE IF cmd.amount = IntMax THEN pending_transfer.amount ELSE cmd.amount

MarkTransient(set0, transfer_id, reason) ==
  IF reason \in TransientReasons THEN set0 \union {transfer_id} ELSE set0

CreateAccount ==
  /\ Len(create_account_queue) > 0
  /\ LET
       cmd == Head(create_account_queue)
       existing == AccountFor(cmd.id)
       reason == CreateAccountReason(cmd)
     IN
       /\ create_account_queue' = Tail(create_account_queue)
       /\ IF IsPresentAccount(existing) THEN
            /\ outcomes' = Append(
                 outcomes,
                 IF AccountCommandMatchesExisting(cmd, existing)
                   THEN RecordOutcome(cmd.id, "exists", "none")
                   ELSE RecordOutcome(cmd.id, "rejected", ExistingAccountMismatchReason(cmd, existing))
               )
            /\ UNCHANGED <<accounts, transfers, pending, failed_transfer_ids, account_events,
                            create_transfer_queue, clock>>
          ELSE IF reason # "none" THEN
            /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "rejected", reason))
            /\ UNCHANGED <<accounts, transfers, pending, failed_transfer_ids, account_events,
                            create_transfer_queue, clock>>
          ELSE
            /\ cmd.id \in AccountIds
            /\ LET ts == EffectiveTimestamp(cmd) IN
               /\ accounts' = [accounts EXCEPT ![cmd.id] = [
                    id |-> cmd.id,
                    debits_pending |-> 0,
                    debits_posted |-> 0,
                    credits_pending |-> 0,
                    credits_posted |-> 0,
                    user_data_128 |-> cmd.user_data_128,
                    user_data_64 |-> cmd.user_data_64,
                    user_data_32 |-> cmd.user_data_32,
                    ledger |-> cmd.ledger,
                    code |-> cmd.code,
                    flags |-> cmd.flags,
                    timestamp |-> ts
                 ]]
               /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "ok", "none"))
               /\ clock' = Max2(clock, ts)
               /\ UNCHANGED <<transfers, pending, failed_transfer_ids, account_events,
                               create_transfer_queue>>

ProcessTransfer ==
  /\ Len(create_account_queue) = 0
  /\ Len(create_transfer_queue) > 0
  /\ LET
       cmd == Head(create_transfer_queue)
       existing == TransferFor(cmd.id)
     IN
       /\ create_transfer_queue' = Tail(create_transfer_queue)
       /\ IF cmd.id \in failed_transfer_ids THEN
            /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "rejected", "id_already_failed"))
            /\ UNCHANGED <<accounts, transfers, pending, failed_transfer_ids, account_events,
                            create_account_queue, clock>>

          ELSE IF IsPresentTransfer(existing) THEN
            /\ outcomes' = Append(
                 outcomes,
                 IF TransferCommandMatchesExisting(cmd, existing)
                   THEN RecordOutcome(cmd.id, "exists", "none")
                   ELSE RecordOutcome(cmd.id, "rejected", TransferMismatchReason(cmd, existing))
               )
            /\ UNCHANGED <<accounts, transfers, pending, failed_transfer_ids, account_events,
                            create_account_queue, clock>>

          ELSE IF cmd.mode \in {"post_pending", "void_pending"} THEN
            /\ LET
                 pre_reason == PostVoidPrecheckReason(cmd)
               IN
                 IF pre_reason # "none" THEN
                   /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "rejected", pre_reason))
                   /\ failed_transfer_ids' = MarkTransient(failed_transfer_ids, cmd.id, pre_reason)
                   /\ UNCHANGED <<accounts, transfers, pending, account_events,
                                   create_account_queue, clock>>
                 ELSE
                   /\ LET
                        p == TransferFor(cmd.pending_id)
                        ps == PendingFor(cmd.pending_id)
                        amount == PostVoidAmount(cmd, p)
                        debit == AccountFor(p.debit_account_id)
                        credit == AccountFor(p.credit_account_id)
                        runtime_reason ==
                          IF ~IsPresentTransfer(p) THEN "pending_transfer_not_found"
                          ELSE IF p.mode # "pending" THEN "pending_transfer_not_pending"
                          ELSE IF cmd.debit_account_id # 0 /\ cmd.debit_account_id # p.debit_account_id
                            THEN "pending_transfer_has_different_debit_account_id"
                          ELSE IF cmd.credit_account_id # 0 /\ cmd.credit_account_id # p.credit_account_id
                            THEN "pending_transfer_has_different_credit_account_id"
                          ELSE IF cmd.ledger # 0 /\ cmd.ledger # p.ledger
                            THEN "pending_transfer_has_different_ledger"
                          ELSE IF cmd.code # 0 /\ cmd.code # p.code
                            THEN "pending_transfer_has_different_code"
                          ELSE IF ps.status = "posted" THEN "pending_transfer_already_posted"
                          ELSE IF ps.status = "voided" THEN "pending_transfer_already_voided"
                          ELSE IF ps.status = "expired" THEN "pending_transfer_expired"
                          ELSE IF ps.status # "pending" THEN "pending_transfer_not_found"
                          ELSE IF ps.expires_at # 0 /\ ps.expires_at <= clock
                            THEN "pending_transfer_expired"
                          ELSE IF amount > p.amount THEN "exceeds_pending_transfer_amount"
                          ELSE IF cmd.mode = "void_pending" /\ amount < p.amount
                            THEN "pending_transfer_has_different_amount"
                          ELSE IF ~IsPresentAccount(debit) THEN "debit_account_not_found"
                          ELSE IF ~IsPresentAccount(credit) THEN "credit_account_not_found"
                          ELSE IF cmd.mode = "post_pending" /\ debit.flags.closed
                            THEN "debit_account_already_closed"
                          ELSE IF cmd.mode = "post_pending" /\ credit.flags.closed
                            THEN "credit_account_already_closed"
                          ELSE "none"
                      IN
                        IF runtime_reason # "none" THEN
                          /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "rejected", runtime_reason))
                          /\ failed_transfer_ids' = MarkTransient(
                               failed_transfer_ids,
                               cmd.id,
                               runtime_reason
                             )
                          /\ UNCHANGED <<accounts, transfers, pending, account_events,
                                          create_account_queue, clock>>
                        ELSE
                          /\ LET
                               ts == EffectiveTimestamp(cmd)
                               status_next == IF cmd.mode = "post_pending" THEN "posted" ELSE "voided"
                               debit1 ==
                                 IF cmd.mode = "post_pending" THEN
                                   [debit EXCEPT
                                     !.debits_pending = @ - p.amount,
                                     !.debits_posted = @ + amount
                                   ]
                                 ELSE
                                   IF p.flags.closing_debit
                                     THEN [debit EXCEPT !.debits_pending = @ - p.amount, !.flags.closed = FALSE]
                                     ELSE [debit EXCEPT !.debits_pending = @ - p.amount]
                               credit1 ==
                                 IF cmd.mode = "post_pending" THEN
                                   [credit EXCEPT
                                     !.credits_pending = @ - p.amount,
                                     !.credits_posted = @ + amount
                                   ]
                                 ELSE
                                   IF p.flags.closing_credit
                                     THEN [credit EXCEPT !.credits_pending = @ - p.amount, !.flags.closed = FALSE]
                                     ELSE [credit EXCEPT !.credits_pending = @ - p.amount]
                               transfer_record == [
                                 id |-> cmd.id,
                                 debit_account_id |-> p.debit_account_id,
                                 credit_account_id |-> p.credit_account_id,
                                 amount |-> amount,
                                 pending_id |-> cmd.pending_id,
                                 user_data_128 |-> IF cmd.user_data_128 = 0 THEN p.user_data_128 ELSE cmd.user_data_128,
                                 user_data_64 |-> IF cmd.user_data_64 = 0 THEN p.user_data_64 ELSE cmd.user_data_64,
                                 user_data_32 |-> IF cmd.user_data_32 = 0 THEN p.user_data_32 ELSE cmd.user_data_32,
                                 timeout |-> 0,
                                 ledger |-> p.ledger,
                                 code |-> p.code,
                                 flags |-> cmd.flags,
                                 timestamp |-> ts,
                                 mode |-> cmd.mode
                               ]
                             IN
                               /\ accounts' = [accounts EXCEPT
                                    ![p.debit_account_id] = debit1,
                                    ![p.credit_account_id] = credit1
                                  ]
                               /\ transfers' = [transfers EXCEPT ![cmd.id] = transfer_record]
                               /\ pending' = [pending EXCEPT ![cmd.pending_id].status = status_next]
                               /\ account_events' = Append(account_events, [
                                    timestamp |-> ts,
                                    event_type |-> IF cmd.mode = "post_pending"
                                                   THEN "two_phase_posted"
                                                   ELSE "two_phase_voided",
                                    transfer_id |-> cmd.id,
                                    pending_id |-> cmd.pending_id,
                                    debit_account_id |-> p.debit_account_id,
                                    credit_account_id |-> p.credit_account_id,
                                    amount_requested |-> cmd.amount,
                                    amount |-> amount,
                                    ledger |-> p.ledger,
                                    pending_status |-> status_next
                                  ])
                               /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "ok", "none"))
                               /\ failed_transfer_ids' = failed_transfer_ids
                               /\ clock' = Max2(clock, ts)
                               /\ UNCHANGED <<create_account_queue>>

          ELSE
            /\ LET
                 pre_reason == RegularTransferReason(cmd)
               IN
                 IF pre_reason # "none" THEN
                   /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "rejected", pre_reason))
                   /\ failed_transfer_ids' = MarkTransient(failed_transfer_ids, cmd.id, pre_reason)
                   /\ UNCHANGED <<accounts, transfers, pending, account_events,
                                   create_account_queue, clock>>
                 ELSE
                   /\ LET
                        debit == AccountFor(cmd.debit_account_id)
                        credit == AccountFor(cmd.credit_account_id)
                        amount == AmountForBalancing(cmd, debit, credit)
                        runtime_reason ==
                          IF ~IsPresentAccount(debit) THEN "debit_account_not_found"
                          ELSE IF ~IsPresentAccount(credit) THEN "credit_account_not_found"
                          ELSE IF debit.ledger # credit.ledger THEN "accounts_must_have_the_same_ledger"
                          ELSE IF cmd.ledger # debit.ledger
                            THEN "transfer_must_have_the_same_ledger_as_accounts"
                          ELSE IF debit.flags.closed THEN "debit_account_already_closed"
                          ELSE IF credit.flags.closed THEN "credit_account_already_closed"
                          ELSE IF DebitsExceedCredits(debit, amount) THEN "exceeds_credits"
                          ELSE IF CreditsExceedDebits(credit, amount) THEN "exceeds_debits"
                          ELSE "none"
                      IN
                        IF runtime_reason # "none" THEN
                          /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "rejected", runtime_reason))
                          /\ failed_transfer_ids' = MarkTransient(
                               failed_transfer_ids,
                               cmd.id,
                               runtime_reason
                             )
                          /\ UNCHANGED <<accounts, transfers, pending, account_events,
                                          create_account_queue, clock>>
                        ELSE
                          /\ LET
                               ts == EffectiveTimestamp(cmd)
                               debit0 == IF cmd.flags.pending
                                           THEN [debit EXCEPT !.debits_pending = @ + amount]
                                           ELSE [debit EXCEPT !.debits_posted = @ + amount]
                               debit1 == IF cmd.flags.closing_debit
                                           THEN [debit0 EXCEPT !.flags.closed = TRUE]
                                           ELSE debit0
                               credit0 == IF cmd.flags.pending
                                            THEN [credit EXCEPT !.credits_pending = @ + amount]
                                            ELSE [credit EXCEPT !.credits_posted = @ + amount]
                               credit1 == IF cmd.flags.closing_credit
                                            THEN [credit0 EXCEPT !.flags.closed = TRUE]
                                            ELSE credit0
                               transfer_record == [
                                 id |-> cmd.id,
                                 debit_account_id |-> cmd.debit_account_id,
                                 credit_account_id |-> cmd.credit_account_id,
                                 amount |-> amount,
                                 pending_id |-> 0,
                                 user_data_128 |-> cmd.user_data_128,
                                 user_data_64 |-> cmd.user_data_64,
                                 user_data_32 |-> cmd.user_data_32,
                                 timeout |-> cmd.timeout,
                                 ledger |-> cmd.ledger,
                                 code |-> cmd.code,
                                 flags |-> cmd.flags,
                                 timestamp |-> ts,
                                 mode |-> cmd.mode
                               ]
                               pending_update ==
                                 IF cmd.flags.pending
                                   THEN [pending EXCEPT ![cmd.id] = [
                                          status |-> "pending",
                                          expires_at |-> IF cmd.timeout > 0 THEN ts + cmd.timeout ELSE 0
                                        ]]
                                   ELSE pending
                             IN
                               /\ accounts' = [accounts EXCEPT
                                    ![cmd.debit_account_id] = debit1,
                                    ![cmd.credit_account_id] = credit1
                                  ]
                               /\ transfers' = [transfers EXCEPT ![cmd.id] = transfer_record]
                               /\ pending' = pending_update
                               /\ account_events' = Append(account_events, [
                                    timestamp |-> ts,
                                    event_type |-> IF cmd.flags.pending
                                                   THEN "two_phase_pending"
                                                   ELSE "single_phase",
                                    transfer_id |-> cmd.id,
                                    pending_id |-> 0,
                                    debit_account_id |-> cmd.debit_account_id,
                                    credit_account_id |-> cmd.credit_account_id,
                                    amount_requested |-> cmd.amount,
                                    amount |-> amount,
                                    ledger |-> cmd.ledger,
                                    pending_status |-> IF cmd.flags.pending THEN "pending" ELSE "none"
                                  ])
                               /\ outcomes' = Append(outcomes, RecordOutcome(cmd.id, "ok", "none"))
                               /\ failed_transfer_ids' = failed_transfer_ids
                               /\ clock' = Max2(clock, ts)
                               /\ UNCHANGED <<create_account_queue>>

ExpireOnePending ==
  /\ \E tid \in TransferIds:
       /\ pending[tid].status = "pending"
       /\ pending[tid].expires_at # 0
       /\ pending[tid].expires_at <= clock
       /\ LET
            p == transfers[tid]
            debit == AccountFor(p.debit_account_id)
            credit == AccountFor(p.credit_account_id)
            ts == Max2(clock, MaxObjectTimestamp) + 1
            debit1 == IF p.flags.closing_debit
                        THEN [debit EXCEPT !.debits_pending = @ - p.amount, !.flags.closed = FALSE]
                        ELSE [debit EXCEPT !.debits_pending = @ - p.amount]
            credit1 == IF p.flags.closing_credit
                         THEN [credit EXCEPT !.credits_pending = @ - p.amount, !.flags.closed = FALSE]
                         ELSE [credit EXCEPT !.credits_pending = @ - p.amount]
          IN
            /\ accounts' = [accounts EXCEPT
                 ![p.debit_account_id] = debit1,
                 ![p.credit_account_id] = credit1
               ]
            /\ pending' = [pending EXCEPT ![tid].status = "expired"]
            /\ account_events' = Append(account_events, [
                 timestamp |-> ts,
                 event_type |-> "two_phase_expired",
                 transfer_id |-> 0,
                 pending_id |-> tid,
                 debit_account_id |-> p.debit_account_id,
                 credit_account_id |-> p.credit_account_id,
                 amount_requested |-> 0,
                 amount |-> p.amount,
                 ledger |-> p.ledger,
                 pending_status |-> "expired"
               ])
            /\ clock' = ts
            /\ UNCHANGED <<transfers, failed_transfer_ids, outcomes,
                            create_account_queue, create_transfer_queue>>

AdvanceClock ==
  /\ Len(create_account_queue) = 0
  /\ Len(create_transfer_queue) = 0
  /\ clock < MaxClock
  /\ clock' = clock + 1
  /\ UNCHANGED <<accounts, transfers, pending, failed_transfer_ids,
                  account_events, outcomes, create_account_queue, create_transfer_queue>>

Init ==
  /\ accounts = [i \in AccountIds |->
       IF i = 1 THEN [
         id |-> 1,
         debits_pending |-> 0,
         debits_posted |-> 0,
         credits_pending |-> 0,
         credits_posted |-> 100,
         user_data_128 |-> 0,
         user_data_64 |-> 0,
         user_data_32 |-> 0,
         ledger |-> 1,
         code |-> 10,
         flags |-> [
           linked |-> FALSE,
           debits_must_not_exceed_credits |-> TRUE,
           credits_must_not_exceed_debits |-> FALSE,
           history |-> TRUE,
           imported |-> FALSE,
           closed |-> FALSE
         ],
         timestamp |-> 10
       ] ELSE IF i = 2 THEN [
         id |-> 2,
         debits_pending |-> 0,
         debits_posted |-> 100,
         credits_pending |-> 0,
         credits_posted |-> 0,
         user_data_128 |-> 0,
         user_data_64 |-> 0,
         user_data_32 |-> 0,
         ledger |-> 1,
         code |-> 10,
         flags |-> [
           linked |-> FALSE,
           debits_must_not_exceed_credits |-> FALSE,
           credits_must_not_exceed_debits |-> TRUE,
           history |-> TRUE,
           imported |-> FALSE,
           closed |-> FALSE
         ],
         timestamp |-> 11
       ] ELSE NoAccount]

  /\ transfers = [tid \in TransferIds |-> NoTransfer]
  /\ pending = [tid \in TransferIds |-> NoPending]
  /\ failed_transfer_ids = {}
  /\ account_events = <<>>
  /\ outcomes = <<>>

  /\ create_account_queue = <<
       [
         id |-> 1,
         debits_pending |-> 0,
         debits_posted |-> 0,
         credits_pending |-> 0,
         credits_posted |-> 0,
         user_data_128 |-> 0,
         user_data_64 |-> 0,
         user_data_32 |-> 0,
         ledger |-> 1,
         code |-> 10,
         flags |-> [
           linked |-> FALSE,
           debits_must_not_exceed_credits |-> TRUE,
           credits_must_not_exceed_debits |-> FALSE,
           history |-> TRUE,
           imported |-> FALSE,
           closed |-> FALSE
         ],
         timestamp |-> 0
       ]
     >>

  /\ \E pending_amount \in {30, 40, 50, 60},
        post_amount \in {20, 60, IntMax},
        transient_credit_id \in {2, 3},
        trailing_timeout \in {1, 2, 3, 4}:
       create_transfer_queue = <<
         [
           id |-> 101,
           debit_account_id |-> 1,
           credit_account_id |-> 2,
           amount |-> pending_amount,
           pending_id |-> 0,
           user_data_128 |-> 0,
           user_data_64 |-> 0,
           user_data_32 |-> 0,
           timeout |-> 3,
           ledger |-> 1,
           code |-> 10,
           flags |-> [
             linked |-> FALSE,
             pending |-> TRUE,
             post_pending_transfer |-> FALSE,
             void_pending_transfer |-> FALSE,
             balancing_debit |-> FALSE,
             balancing_credit |-> FALSE,
             closing_debit |-> FALSE,
             closing_credit |-> FALSE,
             imported |-> FALSE
           ],
           timestamp |-> 0,
           mode |-> "pending"
         ],
         [
           id |-> 102,
           debit_account_id |-> 0,
           credit_account_id |-> 0,
           amount |-> post_amount,
           pending_id |-> 101,
           user_data_128 |-> 0,
           user_data_64 |-> 0,
           user_data_32 |-> 0,
           timeout |-> 0,
           ledger |-> 0,
           code |-> 0,
           flags |-> [
             linked |-> FALSE,
             pending |-> FALSE,
             post_pending_transfer |-> TRUE,
             void_pending_transfer |-> FALSE,
             balancing_debit |-> FALSE,
             balancing_credit |-> FALSE,
             closing_debit |-> FALSE,
             closing_credit |-> FALSE,
             imported |-> FALSE
           ],
           timestamp |-> 0,
           mode |-> "post_pending"
         ],
         [
           id |-> 103,
           debit_account_id |-> 1,
           credit_account_id |-> transient_credit_id,
           amount |-> 10,
           pending_id |-> 0,
           user_data_128 |-> 0,
           user_data_64 |-> 0,
           user_data_32 |-> 0,
           timeout |-> 0,
           ledger |-> 1,
           code |-> 10,
           flags |-> [
             linked |-> FALSE,
             pending |-> FALSE,
             post_pending_transfer |-> FALSE,
             void_pending_transfer |-> FALSE,
             balancing_debit |-> FALSE,
             balancing_credit |-> FALSE,
             closing_debit |-> FALSE,
             closing_credit |-> FALSE,
             imported |-> FALSE
           ],
           timestamp |-> 0,
           mode |-> "single_phase"
         ],
         [
           id |-> 103,
           debit_account_id |-> 1,
           credit_account_id |-> 2,
           amount |-> 10,
           pending_id |-> 0,
           user_data_128 |-> 0,
           user_data_64 |-> 0,
           user_data_32 |-> 0,
           timeout |-> 0,
           ledger |-> 1,
           code |-> 10,
           flags |-> [
             linked |-> FALSE,
             pending |-> FALSE,
             post_pending_transfer |-> FALSE,
             void_pending_transfer |-> FALSE,
             balancing_debit |-> FALSE,
             balancing_credit |-> FALSE,
             closing_debit |-> FALSE,
             closing_credit |-> FALSE,
             imported |-> FALSE
           ],
           timestamp |-> 0,
           mode |-> "single_phase"
         ],
         [
           id |-> 104,
           debit_account_id |-> 0,
           credit_account_id |-> 0,
           amount |-> 0,
           pending_id |-> 101,
           user_data_128 |-> 0,
           user_data_64 |-> 0,
           user_data_32 |-> 0,
           timeout |-> 0,
           ledger |-> 0,
           code |-> 0,
           flags |-> [
             linked |-> FALSE,
             pending |-> FALSE,
             post_pending_transfer |-> FALSE,
             void_pending_transfer |-> TRUE,
             balancing_debit |-> FALSE,
             balancing_credit |-> FALSE,
             closing_debit |-> FALSE,
             closing_credit |-> FALSE,
             imported |-> FALSE
           ],
           timestamp |-> 0,
           mode |-> "void_pending"
         ],
         [
           id |-> 105,
           debit_account_id |-> 1,
           credit_account_id |-> 2,
           amount |-> 20,
           pending_id |-> 0,
           user_data_128 |-> 0,
           user_data_64 |-> 0,
           user_data_32 |-> 0,
           timeout |-> trailing_timeout,
           ledger |-> 1,
           code |-> 10,
           flags |-> [
             linked |-> FALSE,
             pending |-> TRUE,
             post_pending_transfer |-> FALSE,
             void_pending_transfer |-> FALSE,
             balancing_debit |-> FALSE,
             balancing_credit |-> FALSE,
             closing_debit |-> FALSE,
             closing_credit |-> FALSE,
             imported |-> FALSE
           ],
           timestamp |-> 0,
           mode |-> "pending"
         ]
       >>

  /\ clock = 12

TypeOK ==
  /\ accounts \in [AccountIds -> AccountRec]
  /\ transfers \in [TransferIds -> TransferRec]
  /\ pending \in [TransferIds -> PendingRec]
  /\ failed_transfer_ids \subseteq TransferIds
  /\ account_events \in Seq(AccountEventRec)
  /\ outcomes \in Seq(OutcomeRec)
  /\ create_account_queue \in Seq(AccountCommandRec)
  /\ create_transfer_queue \in Seq(TransferCommandRec)
  /\ clock \in Nat

TotalDebitsPending == accounts[1].debits_pending + accounts[2].debits_pending + accounts[3].debits_pending
TotalCreditsPending == accounts[1].credits_pending + accounts[2].credits_pending + accounts[3].credits_pending
TotalDebitsPosted == accounts[1].debits_posted + accounts[2].debits_posted + accounts[3].debits_posted
TotalCreditsPosted == accounts[1].credits_posted + accounts[2].credits_posted + accounts[3].credits_posted

BalancesConserved ==
  /\ TotalDebitsPending = TotalCreditsPending
  /\ TotalDebitsPosted = TotalCreditsPosted

PendingReferencesPendingTransfer ==
  \A tid \in TransferIds:
    IF pending[tid].status # "none" THEN
      /\ transfers[tid].mode = "pending"
      /\ pending[tid].status \in {"pending", "posted", "voided", "expired"}
    ELSE TRUE

TransientFailedIdsNeverCommit ==
  \A tid \in failed_transfer_ids: ~IsPresentTransfer(transfers[tid])

AccountEventsReferenceConsistentLedger ==
  \A i \in 1..Len(account_events):
    LET ev == account_events[i] IN
      /\ ev.debit_account_id \in AccountIds
      /\ ev.credit_account_id \in AccountIds
      /\ AccountFor(ev.debit_account_id).ledger = AccountFor(ev.credit_account_id).ledger

AccountFlagsMutuallyExclusive ==
  \A aid \in AccountIds:
    ~(accounts[aid].flags.debits_must_not_exceed_credits /\ accounts[aid].flags.credits_must_not_exceed_debits)

TransferModeFlagsConsistent(t) ==
  IF ~IsPresentTransfer(t) THEN TRUE
  ELSE IF t.mode = "single_phase" THEN
    /\ ~t.flags.pending
    /\ ~t.flags.post_pending_transfer
    /\ ~t.flags.void_pending_transfer
    /\ t.pending_id = 0
  ELSE IF t.mode = "pending" THEN
    /\ t.flags.pending
    /\ ~t.flags.post_pending_transfer
    /\ ~t.flags.void_pending_transfer
    /\ t.pending_id = 0
  ELSE IF t.mode = "post_pending" THEN
    /\ ~t.flags.pending
    /\ t.flags.post_pending_transfer
    /\ ~t.flags.void_pending_transfer
    /\ t.pending_id # 0
  ELSE
    /\ ~t.flags.pending
    /\ ~t.flags.post_pending_transfer
    /\ t.flags.void_pending_transfer
    /\ t.pending_id # 0

TransferModesAndFlagsConsistent ==
  \A tid \in TransferIds: TransferModeFlagsConsistent(transfers[tid])

PostVoidTransfersReferencePendingTransfer ==
  \A tid \in TransferIds:
    LET t == transfers[tid] IN
      IF IsPresentTransfer(t) /\ t.mode \in {"post_pending", "void_pending"} THEN
        /\ t.pending_id \in TransferIds
        /\ IsPresentTransfer(transfers[t.pending_id])
        /\ transfers[t.pending_id].mode = "pending"
      ELSE TRUE

PendingRowsReferencePendingTransfers ==
  \A tid \in TransferIds:
    IF pending[tid].status # "none" THEN
      /\ IsPresentTransfer(transfers[tid])
      /\ transfers[tid].mode = "pending"
      /\ transfers[tid].flags.pending
    ELSE TRUE

AlwaysTypeOK ==
  []TypeOK

ClockNeverDecreases ==
  [][clock' >= clock]_vars

AccountQueueEventuallyDrains ==
  (Len(create_account_queue) > 0) ~> (Len(create_account_queue) = 0)

TransferQueueEventuallyDrains ==
  (Len(create_transfer_queue) > 0) ~> (Len(create_transfer_queue) = 0)

PendingTransfersEventuallyResolve ==
  \A tid \in TransferIds:
    (pending[tid].status = "pending")
      ~> (pending[tid].status \in {"posted", "voided", "expired"})

TerminalPendingStatusSticky ==
  \A tid \in TransferIds:
    [][
      (pending[tid].status \in {"posted", "voided", "expired"})
        => (pending'[tid].status = pending[tid].status)
    ]_vars

Next ==
  CreateAccount \/
  ProcessTransfer \/
  ExpireOnePending \/
  AdvanceClock

Spec == Init /\ [][Next]_vars

FairSpec ==
  Spec /\
  WF_vars(CreateAccount) /\
  WF_vars(ProcessTransfer) /\
  WF_vars(ExpireOnePending) /\
  WF_vars(AdvanceClock)

=============================================================================
