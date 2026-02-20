---- MODULE ClientSessions ----
EXTENDS Naturals, Sequences, FiniteSets

(***************************************************************************)
(* Distilled from code/docs:                                               *)
(* - docs/reference/sessions.md                                            *)
(* - src/vsr/client_sessions.zig (deterministic eviction by oldest commit) *)
(***************************************************************************)

CONSTANTS ClientsMax, MaxClock

SessionIds == 1..7
SessionStatusSet == {"none", "active", "evicted", "terminated"}
SessionEventKindSet == {
  "registered",
  "evicted",
  "request_submitted",
  "reply_received",
  "request_retried",
  "terminated"
}
SessionErrorSet == {"session_evicted", "in_flight_request_exists"}

SessionRec == [
  session_id : Nat,
  client_id : Nat,
  status : SessionStatusSet,
  registered_at : Nat,
  last_committed_at : Nat,
  in_flight_request_id : Nat,
  last_reply_checksum : Nat
]

RegistrationReq == [client_id : Nat]
SubmissionReq == [session_id : Nat, request_id : Nat]
ReplyReq == [session_id : Nat, request_id : Nat, reply_checksum : Nat]
RetryReq == [session_id : Nat, request_id : Nat]
RestartReq == [previous_session_id : Nat, new_client_id : Nat]

SessionEventRec == [session_id : Nat, kind : SessionEventKindSet, request_id : Nat, timestamp : Nat]
SessionErrorRec == [session_id : Nat, request_id : Nat, error : SessionErrorSet, timestamp : Nat]
RequestRefRec == [session_id : Nat, request_id : Nat]

NoSession == [
  session_id |-> 0,
  client_id |-> 0,
  status |-> "none",
  registered_at |-> 0,
  last_committed_at |-> 0,
  in_flight_request_id |-> 0,
  last_reply_checksum |-> 0
]

VARIABLES
  sessions,
  next_session_id,
  registration_queue,
  submission_queue,
  cluster_reply_queue,
  uncertain_delivery_queue,
  restart_queue,
  session_events,
  session_errors,
  forwarded_requests,
  retried_requests,
  clock

vars == <<
  sessions,
  next_session_id,
  registration_queue,
  submission_queue,
  cluster_reply_queue,
  uncertain_delivery_queue,
  restart_queue,
  session_events,
  session_errors,
  forwarded_requests,
  retried_requests,
  clock
>>

SessionFor(sid) == IF sid \in SessionIds THEN sessions[sid] ELSE NoSession

ActiveSessionIds == {sid \in SessionIds : sessions[sid].status = "active"}
ActiveSessionCount == Cardinality(ActiveSessionIds)

OlderOrEqual(s1, s2) ==
  LET a == sessions[s1]
      b == sessions[s2]
  IN
    IF a.last_committed_at < b.last_committed_at THEN TRUE
    ELSE IF a.last_committed_at > b.last_committed_at THEN FALSE
    ELSE IF a.registered_at < b.registered_at THEN TRUE
    ELSE IF a.registered_at > b.registered_at THEN FALSE
    ELSE s1 <= s2

LeastRecentlyCommittedActiveSessionId ==
  IF ActiveSessionIds = {} THEN 0
  ELSE CHOOSE sid \in ActiveSessionIds:
         \A other \in ActiveSessionIds: OlderOrEqual(sid, other)

RegisterSession ==
  /\ Len(registration_queue) > 0
  /\ next_session_id \in SessionIds
  /\ LET
       req == Head(registration_queue)
       now == clock + 1
       need_evict == ActiveSessionCount >= ClientsMax
       evict_id == IF need_evict THEN LeastRecentlyCommittedActiveSessionId ELSE 0
       sessions1 == IF need_evict
                    THEN [sessions EXCEPT ![evict_id].status = "evicted", ![evict_id].in_flight_request_id = 0]
                    ELSE sessions
       evict_events == IF need_evict
                        THEN <<[
                          session_id |-> evict_id,
                          kind |-> "evicted",
                          request_id |-> 0,
                          timestamp |-> now
                        ]>>
                        ELSE <<>>
       new_session == [
         session_id |-> next_session_id,
         client_id |-> req.client_id,
         status |-> "active",
         registered_at |-> now,
         last_committed_at |-> 0,
         in_flight_request_id |-> 0,
         last_reply_checksum |-> 0
       ]
     IN
       /\ sessions' = [sessions1 EXCEPT ![next_session_id] = new_session]
       /\ next_session_id' = next_session_id + 1
       /\ registration_queue' = Tail(registration_queue)
       /\ session_events' = session_events \o evict_events \o <<[
            session_id |-> next_session_id,
            kind |-> "registered",
            request_id |-> 0,
            timestamp |-> now
          ]>>
       /\ clock' = now
       /\ UNCHANGED <<submission_queue, cluster_reply_queue, uncertain_delivery_queue,
                       restart_queue, session_errors, forwarded_requests, retried_requests>>

SubmitRequest ==
  /\ Len(registration_queue) = 0
  /\ Len(submission_queue) > 0
  /\ LET
       sub == Head(submission_queue)
       now == clock + 1
       s == SessionFor(sub.session_id)
     IN
       /\ submission_queue' = Tail(submission_queue)
       /\ clock' = now
       /\ IF s.status # "active" THEN
            /\ session_errors' = Append(session_errors, [
                 session_id |-> sub.session_id,
                 request_id |-> sub.request_id,
                 error |-> "session_evicted",
                 timestamp |-> now
               ])
            /\ UNCHANGED <<sessions, session_events, forwarded_requests, retried_requests,
                            next_session_id, registration_queue, cluster_reply_queue,
                            uncertain_delivery_queue, restart_queue>>
          ELSE IF s.in_flight_request_id # 0 THEN
            /\ session_errors' = Append(session_errors, [
                 session_id |-> sub.session_id,
                 request_id |-> sub.request_id,
                 error |-> "in_flight_request_exists",
                 timestamp |-> now
               ])
            /\ UNCHANGED <<sessions, session_events, forwarded_requests, retried_requests,
                            next_session_id, registration_queue, cluster_reply_queue,
                            uncertain_delivery_queue, restart_queue>>
          ELSE
            /\ sessions' = [sessions EXCEPT ![sub.session_id].in_flight_request_id = sub.request_id]
            /\ session_events' = Append(session_events, [
                 session_id |-> sub.session_id,
                 kind |-> "request_submitted",
                 request_id |-> sub.request_id,
                 timestamp |-> now
               ])
            /\ forwarded_requests' = Append(forwarded_requests, [
                 session_id |-> sub.session_id,
                 request_id |-> sub.request_id
               ])
            /\ UNCHANGED <<session_errors, retried_requests,
                            next_session_id, registration_queue, cluster_reply_queue,
                            uncertain_delivery_queue, restart_queue>>

ReceiveReply ==
  /\ Len(registration_queue) = 0
  /\ Len(submission_queue) = 0
  /\ Len(cluster_reply_queue) > 0
  /\ LET
       r == Head(cluster_reply_queue)
       now == clock + 1
       s == SessionFor(r.session_id)
     IN
       /\ cluster_reply_queue' = Tail(cluster_reply_queue)
       /\ clock' = now
       /\ IF s.status = "active" /\ s.in_flight_request_id = r.request_id THEN
            /\ sessions' = [sessions EXCEPT
                 ![r.session_id].in_flight_request_id = 0,
                 ![r.session_id].last_reply_checksum = r.reply_checksum,
                 ![r.session_id].last_committed_at = now
               ]
            /\ session_events' = Append(session_events, [
                 session_id |-> r.session_id,
                 kind |-> "reply_received",
                 request_id |-> r.request_id,
                 timestamp |-> now
               ])
            /\ UNCHANGED <<next_session_id, registration_queue, submission_queue,
                            uncertain_delivery_queue, restart_queue, session_errors,
                            forwarded_requests, retried_requests>>
          ELSE
            /\ UNCHANGED <<sessions, session_events, next_session_id, registration_queue,
                            submission_queue, uncertain_delivery_queue, restart_queue,
                            session_errors, forwarded_requests, retried_requests>>

RetryRequest ==
  /\ Len(registration_queue) = 0
  /\ Len(submission_queue) = 0
  /\ Len(cluster_reply_queue) = 0
  /\ Len(uncertain_delivery_queue) > 0
  /\ LET
       u == Head(uncertain_delivery_queue)
       now == clock + 1
       s == SessionFor(u.session_id)
     IN
       /\ uncertain_delivery_queue' = Tail(uncertain_delivery_queue)
       /\ clock' = now
       /\ IF s.status = "active" /\ s.in_flight_request_id = u.request_id THEN
            /\ session_events' = Append(session_events, [
                 session_id |-> u.session_id,
                 kind |-> "request_retried",
                 request_id |-> u.request_id,
                 timestamp |-> now
               ])
            /\ retried_requests' = Append(retried_requests, [
                 session_id |-> u.session_id,
                 request_id |-> u.request_id
               ])
            /\ UNCHANGED <<sessions, next_session_id, registration_queue, submission_queue,
                            cluster_reply_queue, restart_queue, session_errors,
                            forwarded_requests>>
          ELSE
            /\ UNCHANGED <<sessions, session_events, retried_requests, next_session_id,
                            registration_queue, submission_queue, cluster_reply_queue,
                            restart_queue, session_errors, forwarded_requests>>

RestartSession ==
  /\ Len(registration_queue) = 0
  /\ Len(submission_queue) = 0
  /\ Len(cluster_reply_queue) = 0
  /\ Len(uncertain_delivery_queue) = 0
  /\ Len(restart_queue) > 0
  /\ LET
       ev == Head(restart_queue)
       now == clock + 1
       old == SessionFor(ev.previous_session_id)
       has_old == old.status # "none"
       sessions1 == IF has_old
                     THEN [sessions EXCEPT
                            ![ev.previous_session_id].status = "terminated",
                            ![ev.previous_session_id].in_flight_request_id = 0]
                     ELSE sessions
       term_events == IF has_old
                       THEN <<[
                         session_id |-> ev.previous_session_id,
                         kind |-> "terminated",
                         request_id |-> 0,
                         timestamp |-> now
                       ]>>
                       ELSE <<>>
     IN
       /\ sessions' = sessions1
       /\ restart_queue' = Tail(restart_queue)
       /\ registration_queue' = Append(registration_queue, [client_id |-> ev.new_client_id])
       /\ session_events' = session_events \o term_events
       /\ clock' = now
       /\ UNCHANGED <<next_session_id, submission_queue, cluster_reply_queue,
                       uncertain_delivery_queue, session_errors,
                       forwarded_requests, retried_requests>>

AdvanceClock ==
  /\ Len(registration_queue) = 0
  /\ Len(submission_queue) = 0
  /\ Len(cluster_reply_queue) = 0
  /\ Len(uncertain_delivery_queue) = 0
  /\ Len(restart_queue) = 0
  /\ clock < MaxClock
  /\ clock' = clock + 1
  /\ UNCHANGED <<sessions, next_session_id, registration_queue, submission_queue,
                  cluster_reply_queue, uncertain_delivery_queue, restart_queue,
                  session_events, session_errors, forwarded_requests, retried_requests>>

Init ==
  /\ sessions = [sid \in SessionIds |-> NoSession]
  /\ next_session_id = 1
  /\ \E reg_client_1 \in {1001, 1002},
        reg_client_2 \in {1003, 1004},
        reg_client_3 \in {1005, 1006},
        reg_client_4 \in {1007, 1008},
        submit_sid_1 \in {1, 2},
        submit_sid_2 \in {1, 2},
        reply_sid \in {1, 2},
        uncertain_sid \in {1, 2},
        restart_prev_sid \in {1, 2},
        restart_new_client \in {2001, 2002}:
       /\ registration_queue = <<
            [client_id |-> reg_client_1],
            [client_id |-> reg_client_2],
            [client_id |-> reg_client_3],
            [client_id |-> reg_client_4]
          >>
       /\ submission_queue = <<
            [session_id |-> submit_sid_1, request_id |-> 88],
            [session_id |-> submit_sid_2, request_id |-> 89]
          >>
       /\ cluster_reply_queue = <<
            [session_id |-> reply_sid, request_id |-> 88, reply_checksum |-> 9001]
          >>
       /\ uncertain_delivery_queue = <<
            [session_id |-> uncertain_sid, request_id |-> 88]
          >>
       /\ restart_queue = <<
            [previous_session_id |-> restart_prev_sid, new_client_id |-> restart_new_client]
          >>
  /\ session_events = <<>>
  /\ session_errors = <<>>
  /\ forwarded_requests = <<>>
  /\ retried_requests = <<>>
  /\ clock = 0

TypeOK ==
  /\ sessions \in [SessionIds -> SessionRec]
  /\ next_session_id \in Nat
  /\ registration_queue \in Seq(RegistrationReq)
  /\ submission_queue \in Seq(SubmissionReq)
  /\ cluster_reply_queue \in Seq(ReplyReq)
  /\ uncertain_delivery_queue \in Seq(RetryReq)
  /\ restart_queue \in Seq(RestartReq)
  /\ session_events \in Seq(SessionEventRec)
  /\ session_errors \in Seq(SessionErrorRec)
  /\ forwarded_requests \in Seq(RequestRefRec)
  /\ retried_requests \in Seq(RequestRefRec)
  /\ clock \in Nat

ActiveSessionCountBounded ==
  ActiveSessionCount <= ClientsMax

NonActiveSessionsHaveNoInflight ==
  \A sid \in SessionIds:
    IF sessions[sid].status = "active" THEN TRUE
    ELSE sessions[sid].in_flight_request_id = 0

AtMostOneInflightPerActiveSession ==
  \A sid \in SessionIds:
    IF sessions[sid].status = "active"
      THEN sessions[sid].in_flight_request_id \in Nat
      ELSE TRUE

AlwaysTypeOK ==
  []TypeOK

ClockNeverDecreases ==
  [][clock' >= clock]_vars

EventuallyNoQueuedSessionWork ==
  <>(
    /\ Len(registration_queue) = 0
    /\ Len(submission_queue) = 0
    /\ Len(cluster_reply_queue) = 0
    /\ Len(uncertain_delivery_queue) = 0
    /\ Len(restart_queue) = 0
  )

ReplyQueueEventuallyConsumed ==
  (Len(cluster_reply_queue) > 0) ~> (Len(cluster_reply_queue) = 0)

RestartQueueEventuallyConsumed ==
  (Len(restart_queue) > 0) ~> (Len(restart_queue) = 0)

Next ==
  RegisterSession \/
  SubmitRequest \/
  ReceiveReply \/
  RetryRequest \/
  RestartSession \/
  AdvanceClock

Spec == Init /\ [][Next]_vars

FairSpec ==
  Spec /\
  WF_vars(RegisterSession) /\
  WF_vars(SubmitRequest) /\
  WF_vars(ReceiveReply) /\
  WF_vars(RetryRequest) /\
  WF_vars(RestartSession) /\
  WF_vars(AdvanceClock)

=============================================================================
