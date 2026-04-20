---- MODULE RequestQueryContracts ----
EXTENDS Naturals, Sequences, FiniteSets

(***************************************************************************)
(* Distilled from code/docs:                                               *)
(* - docs/coding/requests.md                                               *)
(* - docs/coding/linked-events.md                                          *)
(* - docs/reference/requests/*.md                                          *)
(* - docs/reference/account-filter.md, docs/reference/query-filter.md      *)
(***************************************************************************)

CONSTANT IntMax

CreateOps == {"create_accounts", "create_transfers"}
ReadOps == {
  "lookup_accounts",
  "lookup_transfers",
  "get_account_transfers",
  "get_account_balances",
  "query_accounts",
  "query_transfers"
}
AllOps == CreateOps \union ReadOps

ShapeSet == {
  "none",
  "create_accounts_results",
  "create_transfers_results",
  "lookup_accounts_rows",
  "lookup_transfers_rows",
  "get_account_transfers_rows",
  "get_account_balances_rows",
  "query_accounts_rows",
  "query_transfers_rows"
}

RequestIds == {1, 2, 3, 4, 5, 6}

CreateEventRec == [id : Nat, imported : BOOLEAN, linked : BOOLEAN]
AccountFilterRec == [account_id : Nat, limit : Nat, timestamp_min : Nat, timestamp_max : Nat]
QueryFilterRec == [limit : Nat, timestamp_min : Nat, timestamp_max : Nat]

RequestRec == [
  request_id : Nat,
  operation : STRING,
  account_events : Seq(CreateEventRec),
  transfer_events : Seq(CreateEventRec),
  account_filter : AccountFilterRec,
  query_filter : QueryFilterRec,
  account_has_history : BOOLEAN
]

EventResultRec == [request_id : Nat, event_index : Nat, result : STRING, reason : STRING]
ReplyRec == [request_id : Nat, operation : STRING, shape : ShapeSet, row_count : Nat, reply_checksum : STRING]

NoRequest == [
  request_id |-> 0,
  operation |-> "none",
  account_events |-> <<>>,
  transfer_events |-> <<>>,
  account_filter |-> [account_id |-> 0, limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
  query_filter |-> [limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
  account_has_history |-> FALSE
]

NoReply == [request_id |-> 0, operation |-> "none", shape |-> "none", row_count |-> 0, reply_checksum |-> "none"]

VARIABLES
  incoming_requests,
  resolved_requests,
  event_results,
  replies,
  materialized_row_count,
  clock

vars == <<incoming_requests, resolved_requests, event_results, replies, materialized_row_count, clock>>

OperationShape(op) ==
  CASE op = "create_accounts" -> "create_accounts_results"
    [] op = "create_transfers" -> "create_transfers_results"
    [] op = "lookup_accounts" -> "lookup_accounts_rows"
    [] op = "lookup_transfers" -> "lookup_transfers_rows"
    [] op = "get_account_transfers" -> "get_account_transfers_rows"
    [] op = "get_account_balances" -> "get_account_balances_rows"
    [] op = "query_accounts" -> "query_accounts_rows"
    [] op = "query_transfers" -> "query_transfers_rows"
    [] OTHER -> "none"

ReplyChecksum(request_id, row_count) ==
  IF row_count = 0
    THEN "reply-empty"
    ELSE "reply-nonempty"

Min2(a, b) == IF a <= b THEN a ELSE b

BatchImportedConsistent(events) ==
  Len(events) = 0 \/ \A i \in 1..Len(events): events[i].imported = events[1].imported

OpenLinkedChain(events) == Len(events) > 0 /\ events[Len(events)].linked

RECURSIVE SuffixLinkedStart(_, _)
SuffixLinkedStart(events, i) ==
  IF i = 0 THEN 1
  ELSE IF events[i].linked THEN SuffixLinkedStart(events, i - 1) ELSE i + 1

ImportedMismatchReason(events) ==
  IF events[1].imported THEN "imported_event_expected" ELSE "imported_event_not_expected"

ResolveCreateBatch(request_id, events) ==
  IF ~BatchImportedConsistent(events) THEN
    [i \in 1..Len(events) |-> [
      request_id |-> request_id,
      event_index |-> i,
      result |-> "rejected",
      reason |-> ImportedMismatchReason(events)
    ]]
  ELSE IF OpenLinkedChain(events) THEN
    LET start == SuffixLinkedStart(events, Len(events)) IN
      [k \in 1..(Len(events) - start + 1) |->
        LET idx == start + k - 1 IN
        [
          request_id |-> request_id,
          event_index |-> idx,
          result |-> IF idx = Len(events) THEN "linked_event_chain_open" ELSE "linked_event_failed",
          reason |-> IF idx = Len(events) THEN "linked_event_chain_open" ELSE "linked_event_failed"
        ]
      ]
  ELSE
    [i \in 1..Len(events) |-> [
      request_id |-> request_id,
      event_index |-> i,
      result |-> "ok",
      reason |-> "none"
    ]]

AccountFilterValid(f) ==
  /\ f.account_id # 0
  /\ f.account_id # IntMax
  /\ f.limit # 0
  /\ f.timestamp_max >= f.timestamp_min

QueryFilterValid(f) ==
  /\ f.limit # 0
  /\ f.timestamp_max >= f.timestamp_min

ResolveReadReply(request) ==
  LET
    op == request.operation
    valid ==
      CASE op = "lookup_accounts" -> TRUE
        [] op = "lookup_transfers" -> TRUE
        [] op = "get_account_transfers" -> AccountFilterValid(request.account_filter)
        [] op = "get_account_balances" -> AccountFilterValid(request.account_filter) /\ request.account_has_history
        [] op = "query_accounts" -> QueryFilterValid(request.query_filter)
        [] op = "query_transfers" -> QueryFilterValid(request.query_filter)
        [] OTHER -> FALSE
    available == IF op \in ReadOps THEN materialized_row_count[op] ELSE 0
    requested_limit ==
      IF op \in {"get_account_transfers", "get_account_balances"}
        THEN request.account_filter.limit
      ELSE IF op \in {"query_accounts", "query_transfers"}
        THEN request.query_filter.limit
      ELSE available
    row_count == IF valid THEN Min2(available, requested_limit) ELSE 0
  IN
    [
      request_id |-> request.request_id,
      operation |-> op,
      shape |-> OperationShape(op),
      row_count |-> row_count,
      reply_checksum |-> ReplyChecksum(request.request_id, row_count)
    ]

CreateEvents(request) ==
  IF request.operation = "create_accounts"
    THEN request.account_events
    ELSE request.transfer_events

ResultCountForRequest(request_id) ==
  Cardinality({i \in 1..Len(event_results) : event_results[i].request_id = request_id})

ResultExists(request_id, event_index) ==
  \E i \in 1..Len(event_results):
    /\ event_results[i].request_id = request_id
    /\ event_results[i].event_index = event_index

ResultFor(request_id, event_index) ==
  LET i == CHOOSE j \in 1..Len(event_results):
             /\ event_results[j].request_id = request_id
             /\ event_results[j].event_index = event_index
  IN event_results[i]

ExpectedCreateResultCount(request) ==
  Len(ResolveCreateBatch(request.request_id, CreateEvents(request)))

ResolveNextRequest ==
  /\ Len(incoming_requests) > 0
  /\ LET
       request == Head(incoming_requests)
       op == request.operation
     IN
       /\ incoming_requests' = Tail(incoming_requests)
       /\ clock' = clock + 1
       /\ resolved_requests' = [resolved_requests EXCEPT ![request.request_id] = request]
       /\ IF op = "create_accounts" THEN
            /\ LET results == ResolveCreateBatch(request.request_id, request.account_events) IN
               /\ event_results' = event_results \o results
               /\ replies' = [replies EXCEPT ![request.request_id] = [
                    request_id |-> request.request_id,
                    operation |-> op,
                    shape |-> OperationShape(op),
                    row_count |-> Len(results),
                    reply_checksum |-> ReplyChecksum(request.request_id, Len(results))
                  ]]
               /\ UNCHANGED <<materialized_row_count>>
          ELSE IF op = "create_transfers" THEN
            /\ LET results == ResolveCreateBatch(request.request_id, request.transfer_events) IN
               /\ event_results' = event_results \o results
               /\ replies' = [replies EXCEPT ![request.request_id] = [
                    request_id |-> request.request_id,
                    operation |-> op,
                    shape |-> OperationShape(op),
                    row_count |-> Len(results),
                    reply_checksum |-> ReplyChecksum(request.request_id, Len(results))
                  ]]
               /\ UNCHANGED <<materialized_row_count>>
          ELSE IF op \in ReadOps THEN
            /\ event_results' = event_results
            /\ replies' = [replies EXCEPT ![request.request_id] = ResolveReadReply(request)]
            /\ UNCHANGED <<materialized_row_count>>
          ELSE
            /\ event_results' = event_results
            /\ replies' = [replies EXCEPT ![request.request_id] = [
                 request_id |-> request.request_id,
                 operation |-> op,
                 shape |-> OperationShape(op),
                 row_count |-> 0,
                 reply_checksum |-> ReplyChecksum(request.request_id, 0)
               ]]
            /\ UNCHANGED <<materialized_row_count>>

Init ==
  /\ \E create_account_second_imported \in BOOLEAN,
        transfer_first_linked \in BOOLEAN,
        transfer_second_linked \in BOOLEAN,
        lookup_op \in {"lookup_accounts", "lookup_transfers"},
        balances_history_enabled \in BOOLEAN,
        balances_limit \in {0, 10},
        query5_limit \in {0, 2, 5},
        query6_op \in {"query_accounts", "query_transfers", "unknown_query_op"},
        query6_limit \in {1, 3}:
       incoming_requests = <<
         [
           request_id |-> 1,
           operation |-> "create_accounts",
           account_events |-> <<
             [id |-> 11, imported |-> TRUE, linked |-> FALSE],
             [id |-> 12, imported |-> create_account_second_imported, linked |-> FALSE]
           >>,
           transfer_events |-> <<>>,
           account_filter |-> [account_id |-> 0, limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           query_filter |-> [limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           account_has_history |-> FALSE
         ],
         [
           request_id |-> 2,
           operation |-> "create_transfers",
           account_events |-> <<>>,
           transfer_events |-> <<
             [id |-> 21, imported |-> FALSE, linked |-> transfer_first_linked],
             [id |-> 22, imported |-> FALSE, linked |-> transfer_second_linked]
           >>,
           account_filter |-> [account_id |-> 0, limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           query_filter |-> [limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           account_has_history |-> FALSE
         ],
         [
           request_id |-> 3,
           operation |-> lookup_op,
           account_events |-> <<>>,
           transfer_events |-> <<>>,
           account_filter |-> [account_id |-> 0, limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           query_filter |-> [limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           account_has_history |-> FALSE
         ],
         [
           request_id |-> 4,
           operation |-> "get_account_balances",
           account_events |-> <<>>,
           transfer_events |-> <<>>,
           account_filter |-> [account_id |-> 1, limit |-> balances_limit, timestamp_min |-> 1, timestamp_max |-> 10],
           query_filter |-> [limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           account_has_history |-> balances_history_enabled
         ],
         [
           request_id |-> 5,
           operation |-> "query_accounts",
           account_events |-> <<>>,
           transfer_events |-> <<>>,
           account_filter |-> [account_id |-> 0, limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           query_filter |-> [limit |-> query5_limit, timestamp_min |-> 1, timestamp_max |-> 100],
           account_has_history |-> FALSE
         ],
         [
           request_id |-> 6,
           operation |-> query6_op,
           account_events |-> <<>>,
           transfer_events |-> <<>>,
           account_filter |-> [account_id |-> 0, limit |-> 0, timestamp_min |-> 0, timestamp_max |-> 0],
           query_filter |-> [limit |-> query6_limit, timestamp_min |-> 1, timestamp_max |-> 100],
           account_has_history |-> FALSE
         ]
       >>

  /\ resolved_requests = [rid \in RequestIds |-> NoRequest]
  /\ event_results = <<>>
  /\ replies = [rid \in RequestIds |-> NoReply]
  /\ materialized_row_count = [op \in ReadOps |->
       CASE op = "lookup_accounts" -> 2
         [] op = "lookup_transfers" -> 2
         [] op = "get_account_transfers" -> 4
         [] op = "get_account_balances" -> 3
         [] op = "query_accounts" -> 5
         [] op = "query_transfers" -> 5
         [] OTHER -> 0]
  /\ clock = 0

TypeOK ==
  /\ incoming_requests \in Seq(RequestRec)
  /\ resolved_requests \in [RequestIds -> RequestRec]
  /\ event_results \in Seq(EventResultRec)
  /\ replies \in [RequestIds -> ReplyRec]
  /\ materialized_row_count \in [ReadOps -> Nat]
  /\ clock \in Nat

ReplyShapeMatchesOperation ==
  \A rid \in RequestIds:
    IF replies[rid].request_id # 0 THEN
      replies[rid].shape = OperationShape(replies[rid].operation)
    ELSE TRUE

EventResultIndexesUniquePerRequest ==
  \A i, j \in 1..Len(event_results):
    (i # j /\ event_results[i].request_id = event_results[j].request_id)
      => event_results[i].event_index # event_results[j].event_index

InvalidFiltersProduceEmptyReplies ==
  \A rid \in RequestIds:
    LET req == resolved_requests[rid] IN
      IF req.request_id = 0 THEN TRUE
      ELSE IF req.operation = "get_account_transfers" THEN
        AccountFilterValid(req.account_filter) \/ replies[rid].row_count = 0
      ELSE IF req.operation = "get_account_balances" THEN
        (AccountFilterValid(req.account_filter) /\ req.account_has_history) \/ replies[rid].row_count = 0
      ELSE IF req.operation = "query_accounts" THEN
        QueryFilterValid(req.query_filter) \/ replies[rid].row_count = 0
      ELSE IF req.operation = "query_transfers" THEN
        QueryFilterValid(req.query_filter) \/ replies[rid].row_count = 0
      ELSE TRUE

CreateReplyRowsMatchExpectedResolution ==
  \A rid \in RequestIds:
    LET req == resolved_requests[rid] IN
      IF req.request_id = 0 THEN TRUE
      ELSE IF req.operation \in CreateOps THEN
        replies[rid].row_count = ExpectedCreateResultCount(req)
      ELSE TRUE

CreateReplyRowsMatchEventResults ==
  \A rid \in RequestIds:
    LET req == resolved_requests[rid] IN
      IF req.request_id = 0 THEN TRUE
      ELSE IF req.operation \in CreateOps THEN
        ResultCountForRequest(rid) = replies[rid].row_count
      ELSE
        ResultCountForRequest(rid) = 0

ReadReplyRowsBoundedByMaterializedRows ==
  \A rid \in RequestIds:
    LET rep == replies[rid] IN
      IF rep.request_id # 0 /\ rep.operation \in ReadOps THEN
        rep.row_count <= materialized_row_count[rep.operation]
      ELSE TRUE

UnknownOperationRepliesAreEmpty ==
  \A rid \in RequestIds:
    LET rep == replies[rid] IN
      IF rep.request_id # 0 /\ ~(rep.operation \in AllOps) THEN
        /\ rep.shape = "none"
        /\ rep.row_count = 0
      ELSE TRUE

ImportedMismatchRejectsWholeCreateBatch ==
  \A rid \in RequestIds:
    LET req == resolved_requests[rid] IN
      IF req.request_id = 0 \/ ~(req.operation \in CreateOps) THEN TRUE
      ELSE
        LET events == CreateEvents(req) IN
          IF BatchImportedConsistent(events) THEN TRUE
          ELSE
            /\ \A idx \in 1..Len(events):
                 /\ ResultExists(rid, idx)
                 /\ LET r == ResultFor(rid, idx) IN
                      /\ r.result = "rejected"
                      /\ r.reason = ImportedMismatchReason(events)

OpenLinkedChainProducesTailFailureResults ==
  \A rid \in RequestIds:
    LET req == resolved_requests[rid] IN
      IF req.request_id = 0 \/ ~(req.operation \in CreateOps) THEN TRUE
      ELSE
        LET events == CreateEvents(req) IN
          IF ~BatchImportedConsistent(events) \/ ~OpenLinkedChain(events) THEN TRUE
          ELSE
            LET start == SuffixLinkedStart(events, Len(events)) IN
              \A idx \in start..Len(events):
                /\ ResultExists(rid, idx)
                /\ LET r == ResultFor(rid, idx) IN
                     IF idx = Len(events) THEN
                       /\ r.result = "linked_event_chain_open"
                       /\ r.reason = "linked_event_chain_open"
                     ELSE
                       /\ r.result = "linked_event_failed"
                       /\ r.reason = "linked_event_failed"

AlwaysTypeOK ==
  []TypeOK

ClockNeverDecreases ==
  [][clock' >= clock]_vars

IncomingRequestQueueEventuallyDrains ==
  (Len(incoming_requests) > 0) ~> (Len(incoming_requests) = 0)

EachRequestEventuallyResolved ==
  \A rid \in RequestIds:
    (resolved_requests[rid].request_id = 0)
      ~> (resolved_requests[rid].request_id = rid)

EachRequestEventuallyGetsReply ==
  \A rid \in RequestIds:
    (replies[rid].request_id = 0)
      ~> (replies[rid].request_id = rid)

Next == ResolveNextRequest

Spec == Init /\ [][Next]_vars

FairSpec ==
  Spec /\
  WF_vars(ResolveNextRequest)

=============================================================================
