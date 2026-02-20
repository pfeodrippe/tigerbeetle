---- MODULE ClusterConsensus ----
EXTENDS Naturals, Sequences, FiniteSets

(***************************************************************************)
(* Distilled from code/docs:                                               *)
(* - docs/internals/vsr.md (normal, view-change, sync, repair protocols)   *)
(* - src/vsr.zig command and quorum structure                               *)
(***************************************************************************)

CONSTANT MaxClock, MaxEvents, MaxQueueLen, MaxCommittedOps

ReplicaIds == 1..3
OpIds == 1..6
Views == 0..3
BlockIds == {42, 43}

ReplicaRoleSet == {"primary", "backup"}
ReplicaStatusSet == {"normal", "view_change", "syncing"}
PrepareStatusSet == {"none", "prepared", "committed"}
ViewRoundStatusSet == {"none", "collecting_dvc", "repairing", "starting_view"}
SyncStatusSet == {"none", "installing_checkpoint", "repairing_replies", "syncing_forest", "completed"}

ClusterRec == [
  cluster_id : Nat,
  replica_count : Nat,
  replication_quorum : Nat,
  view_change_quorum : Nat,
  latest_committed_op : Nat,
  latest_checkpoint_id : Nat
]

ReplicaRec == [
  replica_id : Nat,
  role : ReplicaRoleSet,
  status : ReplicaStatusSet,
  view : Nat,
  commit_op : Nat,
  op_head : Nat,
  checkpoint_id : Nat,
  active : BOOLEAN
]

ClientRequestRec == [request_id : Nat, client_session_id : Nat, operation : STRING]
PrepareRec == [op : Nat, request_id : Nat, primary_id : Nat, view : Nat, checkpoint_id : Nat, status : PrepareStatusSet]
NoticeRec == [op : Nat, view : Nat]
SignalRec == [replica_id : Nat]

ViewRoundRec == [active : BOOLEAN, target_view : Nat, new_primary_id : Nat, status : ViewRoundStatusSet]

SyncNeedRec == [replica_id : Nat, checkpoint_id : Nat, sync_op_min : Nat, sync_op_max : Nat]
SyncRec == [status : SyncStatusSet, target_checkpoint_id : Nat, sync_op_min : Nat, sync_op_max : Nat]

GridRepairRec == [block_address : Nat, repaired_at : Nat]
MismatchRec == [replica_id : Nat, observed_checkpoint_id : Nat]
DeterminismRec == [replica_id : Nat, expected_checkpoint_id : Nat, observed_checkpoint_id : Nat, timestamp : Nat]

EventRec == [kind : STRING, subject : Nat, timestamp : Nat]

NoPrepare == [op |-> 0, request_id |-> 0, primary_id |-> 0, view |-> 0, checkpoint_id |-> 0, status |-> "none"]
NoRound == [active |-> FALSE, target_view |-> 0, new_primary_id |-> 0, status |-> "none"]
NoSync == [status |-> "none", target_checkpoint_id |-> 0, sync_op_min |-> 0, sync_op_max |-> 0]

VARIABLES
  cluster,
  replicas,
  client_requests,
  prepares,
  prepare_acks,
  commit_notices,
  start_view_change_signals,
  svc_votes,
  view_change_round,
  dvc_quorum_observed,
  repair_completed_views,
  state_sync_needs,
  state_sync,
  sync_ready_for_forest,
  next_checkpoint_committed,
  grid_repairs,
  matching_grid_blocks,
  checkpoint_mismatches,
  determinism_violations,
  cluster_events,
  clock

vars == <<
  cluster,
  replicas,
  client_requests,
  prepares,
  prepare_acks,
  commit_notices,
  start_view_change_signals,
  svc_votes,
  view_change_round,
  dvc_quorum_observed,
  repair_completed_views,
  state_sync_needs,
  state_sync,
  sync_ready_for_forest,
  next_checkpoint_committed,
  grid_repairs,
  matching_grid_blocks,
  checkpoint_mismatches,
  determinism_violations,
  cluster_events,
  clock
>>

Max2(a, b) == IF a >= b THEN a ELSE b

PrimaryId == CHOOSE rid \in ReplicaIds: replicas[rid].role = "primary"

MaxReplicaOpHead == Max2(replicas[1].op_head, Max2(replicas[2].op_head, replicas[3].op_head))

PrepareValue(op) == IF prepares[op].status # "none" THEN op ELSE 0
MaxPreparedOp == Max2(PrepareValue(1), Max2(PrepareValue(2), Max2(PrepareValue(3), Max2(PrepareValue(4), Max2(PrepareValue(5), PrepareValue(6))))))

NextOp == Max2(cluster.latest_committed_op, Max2(MaxReplicaOpHead, MaxPreparedOp)) + 1

PrecedingCommitted(op) ==
  \A i \in 1..(op - 1): prepares[i].status \in {"none", "committed"}

ViewPrimary(target_view) == 1 + (target_view % cluster.replica_count)

PrepareCreate ==
  /\ Len(client_requests) > 0
  /\ PrimaryId \in ReplicaIds
  /\ replicas[PrimaryId].active
  /\ replicas[PrimaryId].status = "normal"
  /\ NextOp \in OpIds
  /\ LET
       req == Head(client_requests)
       now == clock + 1
       op == NextOp
     IN
       /\ client_requests' = Tail(client_requests)
       /\ prepares' = [prepares EXCEPT ![op] = [
            op |-> op,
            request_id |-> req.request_id,
            primary_id |-> PrimaryId,
            view |-> replicas[PrimaryId].view,
            checkpoint_id |-> replicas[PrimaryId].checkpoint_id,
            status |-> "prepared"
          ]]
       /\ prepare_acks' = [prepare_acks EXCEPT ![op] = {PrimaryId}]
       /\ replicas' = [replicas EXCEPT ![PrimaryId].op_head = op]
       /\ cluster_events' = Append(cluster_events, [kind |-> "prepare_created", subject |-> op, timestamp |-> now])
       /\ clock' = now
       /\ UNCHANGED <<cluster, commit_notices, start_view_change_signals, svc_votes,
                       view_change_round, dvc_quorum_observed, repair_completed_views,
                       state_sync_needs, state_sync, sync_ready_for_forest,
                       next_checkpoint_committed, grid_repairs, matching_grid_blocks,
                       checkpoint_mismatches, determinism_violations>>

ReplicaAckPrepare ==
  /\ LET candidates ==
       {<<op, rid>> \in OpIds \X ReplicaIds :
          prepares[op].status = "prepared" /\ replicas[rid].active /\ rid \notin prepare_acks[op]}
     IN
       /\ candidates # {}
       /\ LET
            pair == CHOOSE p \in candidates: TRUE
            op == pair[1]
            rid == pair[2]
            now == clock + 1
          IN
            /\ prepare_acks' = [prepare_acks EXCEPT ![op] = @ \cup {rid}]
            /\ cluster_events' = Append(cluster_events, [kind |-> "prepare_acked", subject |-> op, timestamp |-> now])
            /\ clock' = now
            /\ UNCHANGED <<cluster, replicas, client_requests, prepares, commit_notices,
                            start_view_change_signals, svc_votes, view_change_round,
                            dvc_quorum_observed, repair_completed_views, state_sync_needs,
                            state_sync, sync_ready_for_forest, next_checkpoint_committed,
                            grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                            determinism_violations>>

PrimaryCommitAfterQuorum ==
  /\ LET candidates ==
       {op \in OpIds :
          prepares[op].status = "prepared" /\
          Cardinality(prepare_acks[op]) >= cluster.replication_quorum /\
          PrecedingCommitted(op)}
     IN
       /\ candidates # {}
       /\ LET
            op == CHOOSE c \in candidates: TRUE
            p == prepares[op]
            now == clock + 1
          IN
            /\ prepares' = [prepares EXCEPT ![op].status = "committed"]
            /\ cluster' = [cluster EXCEPT !.latest_committed_op = op]
            /\ replicas' = [replicas EXCEPT ![p.primary_id].commit_op = op]
            /\ commit_notices' = Append(commit_notices, [op |-> op, view |-> p.view])
            /\ cluster_events' = Append(cluster_events, [kind |-> "prepare_committed", subject |-> op, timestamp |-> now])
            /\ clock' = now
            /\ UNCHANGED <<client_requests, prepare_acks, start_view_change_signals,
                            svc_votes, view_change_round, dvc_quorum_observed,
                            repair_completed_views, state_sync_needs, state_sync,
                            sync_ready_for_forest, next_checkpoint_committed, grid_repairs,
                            matching_grid_blocks, checkpoint_mismatches, determinism_violations>>

BackupAdvanceCommit ==
  /\ Len(commit_notices) > 0
  /\ LET
       n == Head(commit_notices)
       now == clock + 1
     IN
       /\ commit_notices' = Tail(commit_notices)
       /\ replicas' = [rid \in ReplicaIds |->
            IF replicas[rid].role = "backup" /\ replicas[rid].active /\ replicas[rid].commit_op < n.op
              THEN [replicas[rid] EXCEPT !.commit_op = n.op]
              ELSE replicas[rid]
          ]
       /\ cluster_events' = Append(cluster_events, [kind |-> "commit_notice_applied", subject |-> n.op, timestamp |-> now])
       /\ clock' = now
       /\ UNCHANGED <<cluster, client_requests, prepares, prepare_acks,
                       start_view_change_signals, svc_votes, view_change_round,
                       dvc_quorum_observed, repair_completed_views, state_sync_needs,
                       state_sync, sync_ready_for_forest, next_checkpoint_committed,
                       grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                       determinism_violations>>

TriggerStartViewChange ==
  /\ Len(start_view_change_signals) > 0
  /\ LET
       sig == Head(start_view_change_signals)
       r == replicas[sig.replica_id]
       now == clock + 1
       target_view == r.view + 1
     IN
       /\ start_view_change_signals' = Tail(start_view_change_signals)
       /\ IF r.role = "backup" /\ r.status \in {"normal", "view_change"} THEN
            /\ replicas' = [replicas EXCEPT ![sig.replica_id].status = "view_change"]
            /\ svc_votes' = [svc_votes EXCEPT ![target_view] = @ \cup {sig.replica_id}]
            /\ cluster_events' = Append(cluster_events, [kind |-> "svc_broadcast", subject |-> target_view, timestamp |-> now])
            /\ UNCHANGED <<cluster, client_requests, prepares, prepare_acks, commit_notices,
                            view_change_round, dvc_quorum_observed, repair_completed_views,
                            state_sync_needs, state_sync, sync_ready_for_forest,
                            next_checkpoint_committed, grid_repairs, matching_grid_blocks,
                            checkpoint_mismatches, determinism_violations>>
          ELSE
            /\ UNCHANGED <<cluster, replicas, client_requests, prepares, prepare_acks,
                            commit_notices, svc_votes, view_change_round,
                            dvc_quorum_observed, repair_completed_views, state_sync_needs,
                            state_sync, sync_ready_for_forest, next_checkpoint_committed,
                            grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                            determinism_violations, cluster_events>>
       /\ clock' = now

EnterViewChangeAfterQuorum ==
  /\ LET candidates ==
       {v \in Views :
         Cardinality(svc_votes[v]) >= cluster.view_change_quorum /\
         (~view_change_round.active \/ v > view_change_round.target_view)}
     IN
       /\ candidates # {}
       /\ LET
            target_view == CHOOSE v \in candidates: TRUE
            new_primary == ViewPrimary(target_view)
            now == clock + 1
          IN
            /\ view_change_round' = [
                 active |-> TRUE,
                 target_view |-> target_view,
                 new_primary_id |-> new_primary,
                 status |-> "collecting_dvc"
               ]
            /\ replicas' = [rid \in ReplicaIds |->
                 IF replicas[rid].active
                   THEN [replicas[rid] EXCEPT !.view = target_view, !.status = "view_change"]
                   ELSE replicas[rid]
               ]
            /\ cluster_events' = Append(cluster_events, [kind |-> "view_change_started", subject |-> target_view, timestamp |-> now])
            /\ clock' = now
            /\ UNCHANGED <<cluster, client_requests, prepares, prepare_acks, commit_notices,
                            start_view_change_signals, svc_votes, dvc_quorum_observed,
                            repair_completed_views, state_sync_needs, state_sync,
                            sync_ready_for_forest, next_checkpoint_committed, grid_repairs,
                            matching_grid_blocks, checkpoint_mismatches,
                            determinism_violations>>

RepairAfterDVC ==
  /\ view_change_round.active
  /\ view_change_round.status = "collecting_dvc"
  /\ view_change_round.target_view \in dvc_quorum_observed
  /\ LET now == clock + 1 IN
     /\ view_change_round' = [view_change_round EXCEPT !.status = "repairing"]
     /\ cluster_events' = Append(cluster_events, [kind |-> "repair_started", subject |-> view_change_round.target_view, timestamp |-> now])
     /\ clock' = now
     /\ UNCHANGED <<cluster, replicas, client_requests, prepares, prepare_acks,
                     commit_notices, start_view_change_signals, svc_votes,
                     dvc_quorum_observed, repair_completed_views, state_sync_needs,
                     state_sync, sync_ready_for_forest, next_checkpoint_committed,
                     grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                     determinism_violations>>

StartNewView ==
  /\ view_change_round.active
  /\ view_change_round.status = "repairing"
  /\ view_change_round.target_view \in repair_completed_views
  /\ LET
       np == view_change_round.new_primary_id
       now == clock + 1
     IN
       /\ view_change_round' = [view_change_round EXCEPT !.status = "starting_view"]
       /\ replicas' = [rid \in ReplicaIds |->
            IF rid = np
              THEN [replicas[rid] EXCEPT !.role = "primary", !.status = "normal"]
              ELSE [replicas[rid] EXCEPT !.role = "backup", !.status = "normal"]
          ]
       /\ cluster_events' = Append(cluster_events, [kind |-> "start_view", subject |-> view_change_round.target_view, timestamp |-> now])
       /\ clock' = now
       /\ UNCHANGED <<cluster, client_requests, prepares, prepare_acks, commit_notices,
                       start_view_change_signals, svc_votes, dvc_quorum_observed,
                       repair_completed_views, state_sync_needs, state_sync,
                       sync_ready_for_forest, next_checkpoint_committed, grid_repairs,
                       matching_grid_blocks, checkpoint_mismatches,
                       determinism_violations>>

TriggerStateSync ==
  /\ Len(state_sync_needs) > 0
  /\ LET
       need == Head(state_sync_needs)
       now == clock + 1
     IN
       /\ state_sync_needs' = Tail(state_sync_needs)
       /\ replicas' = [replicas EXCEPT ![need.replica_id].status = "syncing"]
       /\ state_sync' = [state_sync EXCEPT ![need.replica_id] = [
            status |-> "installing_checkpoint",
            target_checkpoint_id |-> need.checkpoint_id,
            sync_op_min |-> need.sync_op_min,
            sync_op_max |-> need.sync_op_max
          ]]
       /\ cluster_events' = Append(cluster_events, [kind |-> "state_sync_started", subject |-> need.replica_id, timestamp |-> now])
       /\ clock' = now
       /\ UNCHANGED <<cluster, client_requests, prepares, prepare_acks, commit_notices,
                       start_view_change_signals, svc_votes, view_change_round,
                       dvc_quorum_observed, repair_completed_views,
                       sync_ready_for_forest, next_checkpoint_committed,
                       grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                       determinism_violations>>

StateSyncRepairReplies ==
  /\ LET candidates == {rid \in ReplicaIds : state_sync[rid].status = "installing_checkpoint"} IN
     /\ candidates # {}
     /\ LET
          rid == CHOOSE c \in candidates: TRUE
          now == clock + 1
        IN
          /\ state_sync' = [state_sync EXCEPT ![rid].status = "repairing_replies"]
          /\ cluster_events' = Append(cluster_events, [kind |-> "state_sync_replies", subject |-> rid, timestamp |-> now])
          /\ clock' = now
          /\ UNCHANGED <<cluster, replicas, client_requests, prepares, prepare_acks,
                          commit_notices, start_view_change_signals, svc_votes,
                          view_change_round, dvc_quorum_observed, repair_completed_views,
                          state_sync_needs, sync_ready_for_forest, next_checkpoint_committed,
                          grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                          determinism_violations>>

StateSyncForest ==
  /\ LET candidates ==
       {rid \in ReplicaIds : state_sync[rid].status = "repairing_replies" /\ rid \in sync_ready_for_forest}
     IN
     /\ candidates # {}
     /\ LET
          rid == CHOOSE c \in candidates: TRUE
          now == clock + 1
        IN
          /\ state_sync' = [state_sync EXCEPT ![rid].status = "syncing_forest"]
          /\ cluster_events' = Append(cluster_events, [kind |-> "state_sync_forest", subject |-> rid, timestamp |-> now])
          /\ clock' = now
          /\ UNCHANGED <<cluster, replicas, client_requests, prepares, prepare_acks,
                          commit_notices, start_view_change_signals, svc_votes,
                          view_change_round, dvc_quorum_observed, repair_completed_views,
                          state_sync_needs, sync_ready_for_forest, next_checkpoint_committed,
                          grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                          determinism_violations>>

StateSyncComplete ==
  /\ LET candidates ==
       {rid \in ReplicaIds : state_sync[rid].status = "syncing_forest" /\ rid \in next_checkpoint_committed}
     IN
     /\ candidates # {}
     /\ LET
          rid == CHOOSE c \in candidates: TRUE
          now == clock + 1
        IN
          /\ state_sync' = [state_sync EXCEPT ![rid].status = "completed"]
          /\ replicas' = [replicas EXCEPT ![rid].status = "normal"]
          /\ cluster_events' = Append(cluster_events, [kind |-> "state_sync_completed", subject |-> rid, timestamp |-> now])
          /\ clock' = now
          /\ UNCHANGED <<cluster, client_requests, prepares, prepare_acks,
                          commit_notices, start_view_change_signals, svc_votes,
                          view_change_round, dvc_quorum_observed, repair_completed_views,
                          state_sync_needs, sync_ready_for_forest, next_checkpoint_committed,
                          grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                          determinism_violations>>

RepairGridBlock ==
  /\ LET candidates ==
       {b \in BlockIds : grid_repairs[b].repaired_at = 0 /\ b \in matching_grid_blocks}
     IN
     /\ candidates # {}
     /\ LET
          b == CHOOSE c \in candidates: TRUE
          now == clock + 1
        IN
          /\ grid_repairs' = [grid_repairs EXCEPT ![b].repaired_at = now]
          /\ cluster_events' = Append(cluster_events, [kind |-> "grid_repaired", subject |-> b, timestamp |-> now])
          /\ clock' = now
          /\ UNCHANGED <<cluster, replicas, client_requests, prepares, prepare_acks,
                          commit_notices, start_view_change_signals, svc_votes,
                          view_change_round, dvc_quorum_observed, repair_completed_views,
                          state_sync_needs, state_sync, sync_ready_for_forest,
                          next_checkpoint_committed, matching_grid_blocks,
                          checkpoint_mismatches, determinism_violations>>

RecordDeterminismMismatch ==
  /\ Len(checkpoint_mismatches) > 0
  /\ LET
       mm == Head(checkpoint_mismatches)
       now == clock + 1
     IN
       /\ checkpoint_mismatches' = Tail(checkpoint_mismatches)
       /\ determinism_violations' = Append(determinism_violations, [
            replica_id |-> mm.replica_id,
            expected_checkpoint_id |-> replicas[mm.replica_id].checkpoint_id,
            observed_checkpoint_id |-> mm.observed_checkpoint_id,
            timestamp |-> now
          ])
       /\ cluster_events' = Append(cluster_events, [kind |-> "determinism_violation", subject |-> mm.replica_id, timestamp |-> now])
       /\ clock' = now
       /\ UNCHANGED <<cluster, replicas, client_requests, prepares, prepare_acks,
                       commit_notices, start_view_change_signals, svc_votes,
                       view_change_round, dvc_quorum_observed, repair_completed_views,
                       state_sync_needs, state_sync, sync_ready_for_forest,
                       next_checkpoint_committed, grid_repairs, matching_grid_blocks>>

AdvanceClock ==
  /\ Len(client_requests) = 0
  /\ Len(commit_notices) = 0
  /\ Len(start_view_change_signals) = 0
  /\ Len(state_sync_needs) = 0
  /\ Len(checkpoint_mismatches) = 0
  /\ clock < MaxClock
  /\ clock' = clock + 1
  /\ UNCHANGED <<cluster, replicas, client_requests, prepares, prepare_acks, commit_notices,
                  start_view_change_signals, svc_votes, view_change_round,
                  dvc_quorum_observed, repair_completed_views, state_sync_needs,
                  state_sync, sync_ready_for_forest, next_checkpoint_committed,
                  grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                  determinism_violations, cluster_events>>

Init ==
  /\ cluster = [
       cluster_id |-> 0,
       replica_count |-> 3,
       replication_quorum |-> 2,
       view_change_quorum |-> 2,
       latest_committed_op |-> 0,
       latest_checkpoint_id |-> 1
     ]
  /\ replicas = [rid \in ReplicaIds |->
       IF rid = 1 THEN [
         replica_id |-> 1,
         role |-> "primary",
         status |-> "normal",
         view |-> 0,
         commit_op |-> 0,
         op_head |-> 0,
         checkpoint_id |-> 1,
         active |-> TRUE
       ] ELSE [
         replica_id |-> rid,
         role |-> "backup",
         status |-> "normal",
         view |-> 0,
         commit_op |-> 0,
         op_head |-> 0,
         checkpoint_id |-> 1,
         active |-> TRUE
       ]]

  /\ \E request_present_1 \in BOOLEAN,
        request_present_2 \in BOOLEAN,
        signal_from_2 \in BOOLEAN,
        signal_from_3 \in BOOLEAN,
        dvc_ready \in BOOLEAN,
        repair_ready \in BOOLEAN,
        sync_needed \in BOOLEAN,
        sync_ready \in BOOLEAN,
        checkpoint_ready \in BOOLEAN,
        mismatch_present \in BOOLEAN:

       /\ client_requests =
            IF request_present_1 /\ request_present_2 THEN
              <<
                [request_id |-> 9001, client_session_id |-> 77, operation |-> "create_transfers"],
                [request_id |-> 9002, client_session_id |-> 78, operation |-> "create_accounts"]
              >>
            ELSE IF request_present_1 THEN
              <<[request_id |-> 9001, client_session_id |-> 77, operation |-> "create_transfers"]>>
            ELSE IF request_present_2 THEN
              <<[request_id |-> 9002, client_session_id |-> 78, operation |-> "create_accounts"]>>
            ELSE <<>>

       /\ start_view_change_signals =
            IF signal_from_2 /\ signal_from_3 THEN <<[replica_id |-> 2], [replica_id |-> 3]>>
            ELSE IF signal_from_2 THEN <<[replica_id |-> 2]>>
            ELSE IF signal_from_3 THEN <<[replica_id |-> 3]>>
            ELSE <<>>

       /\ dvc_quorum_observed = IF dvc_ready THEN {1} ELSE {}
       /\ repair_completed_views = IF repair_ready THEN {1} ELSE {}

       /\ state_sync_needs =
            IF sync_needed
              THEN <<[replica_id |-> 3, checkpoint_id |-> 2, sync_op_min |-> 10, sync_op_max |-> 20]>>
              ELSE <<>>
       /\ sync_ready_for_forest = IF sync_ready THEN {3} ELSE {}
       /\ next_checkpoint_committed = IF checkpoint_ready THEN {3} ELSE {}

       /\ matching_grid_blocks = {42}

       /\ checkpoint_mismatches =
            IF mismatch_present
              THEN <<[replica_id |-> 2, observed_checkpoint_id |-> 999]>>
              ELSE <<>>

  /\ prepares = [op \in OpIds |-> NoPrepare]
  /\ prepare_acks = [op \in OpIds |-> {}]
  /\ commit_notices = <<>>
  /\ svc_votes = [v \in Views |-> {}]
  /\ view_change_round = NoRound
  /\ state_sync = [rid \in ReplicaIds |-> NoSync]
  /\ grid_repairs = [b \in BlockIds |-> [block_address |-> b, repaired_at |-> 0]]
  /\ determinism_violations = <<>>
  /\ cluster_events = <<>>
  /\ clock = 0

TypeOK ==
  /\ cluster \in ClusterRec
  /\ replicas \in [ReplicaIds -> ReplicaRec]
  /\ client_requests \in Seq(ClientRequestRec)
  /\ prepares \in [OpIds -> PrepareRec]
  /\ prepare_acks \in [OpIds -> SUBSET ReplicaIds]
  /\ commit_notices \in Seq(NoticeRec)
  /\ start_view_change_signals \in Seq(SignalRec)
  /\ svc_votes \in [Views -> SUBSET ReplicaIds]
  /\ view_change_round \in ViewRoundRec
  /\ dvc_quorum_observed \subseteq Views
  /\ repair_completed_views \subseteq Views
  /\ state_sync_needs \in Seq(SyncNeedRec)
  /\ state_sync \in [ReplicaIds -> SyncRec]
  /\ sync_ready_for_forest \subseteq ReplicaIds
  /\ next_checkpoint_committed \subseteq ReplicaIds
  /\ grid_repairs \in [BlockIds -> GridRepairRec]
  /\ matching_grid_blocks \subseteq BlockIds
  /\ checkpoint_mismatches \in Seq(MismatchRec)
  /\ determinism_violations \in Seq(DeterminismRec)
  /\ cluster_events \in Seq(EventRec)
  /\ clock \in Nat

ReplicationQuorumBounded ==
  cluster.replication_quorum <= cluster.replica_count

CommittedPreparesHaveQuorumAcks ==
  \A op \in OpIds:
    IF prepares[op].status = "committed"
      THEN Cardinality(prepare_acks[op]) >= cluster.replication_quorum
      ELSE TRUE

ClusterCommitDominatesReplicas ==
  \A rid \in ReplicaIds: replicas[rid].commit_op <= cluster.latest_committed_op

CompletedSyncLeavesSyncingStatus ==
  \A rid \in ReplicaIds:
    IF state_sync[rid].status = "completed"
      THEN replicas[rid].status # "syncing"
      ELSE TRUE

StateConstraint ==
  /\ clock <= MaxClock
  /\ Len(cluster_events) <= MaxEvents
  /\ Len(client_requests) <= MaxQueueLen
  /\ Len(commit_notices) <= MaxQueueLen
  /\ Len(start_view_change_signals) <= MaxQueueLen
  /\ Len(state_sync_needs) <= MaxQueueLen
  /\ Len(checkpoint_mismatches) <= MaxQueueLen
  /\ Cardinality({op \in OpIds : prepares[op].status = "committed"}) <= MaxCommittedOps

AlwaysTypeOK ==
  []TypeOK

ClockNeverDecreases ==
  [][clock' >= clock]_vars

CommitNoticesEventuallyApplied ==
  (Len(commit_notices) > 0)
    ~> (Len(commit_notices) = 0)

StateSyncNeedsEventuallyConsumed ==
  (Len(state_sync_needs) > 0)
    ~> (Len(state_sync_needs) = 0)

MismatchQueueEventuallyClears ==
  (Len(checkpoint_mismatches) > 0)
    ~> (Len(checkpoint_mismatches) = 0)

Next ==
  PrepareCreate \/
  ReplicaAckPrepare \/
  PrimaryCommitAfterQuorum \/
  BackupAdvanceCommit \/
  TriggerStartViewChange \/
  EnterViewChangeAfterQuorum \/
  RepairAfterDVC \/
  StartNewView \/
  TriggerStateSync \/
  StateSyncRepairReplies \/
  StateSyncForest \/
  StateSyncComplete \/
  RepairGridBlock \/
  RecordDeterminismMismatch \/
  AdvanceClock

Spec == Init /\ [][Next]_vars

FairSpec ==
  Spec /\
  WF_vars(BackupAdvanceCommit) /\
  WF_vars(TriggerStateSync) /\
  WF_vars(RecordDeterminismMismatch) /\
  WF_vars(AdvanceClock)

=============================================================================
