---- MODULE ClusterConsensusOneWayPartitionBug ----
EXTENDS ClusterConsensus

\* One-way partition bug-hunt profile:
\* - primary can emit prepares
\* - prepare acks from backups never arrive at primary
\* - backups never trigger view-change signals
\* This captures the known risk where the primary keeps running without quorum progress.

OneWayPartitionState ==
  /\ start_view_change_signals = <<>>
  /\ \A v \in Views: svc_votes[v] = {}
  /\ ~view_change_round.active
  /\ dvc_quorum_observed = {}
  /\ repair_completed_views = {}
  /\ Len(state_sync_needs) = 0
  /\ Len(checkpoint_mismatches) = 0
  /\ sync_ready_for_forest = {}
  /\ next_checkpoint_committed = {}
  /\ \A rid \in ReplicaIds: state_sync[rid].status = "none"
  /\ \A op \in OpIds:
      IF prepares[op].status = "prepared"
        THEN prepare_acks[op] = {prepares[op].primary_id}
        ELSE prepare_acks[op] = {}

OneWayInit ==
  /\ Init
  /\ OneWayPartitionState
  /\ Len(client_requests) = 1

PrepareCreateOneWay == PrepareCreate /\ OneWayPartitionState'
ReplicaAckPrepareOneWay == ReplicaAckPrepare /\ OneWayPartitionState'
PrimaryCommitAfterQuorumOneWay == PrimaryCommitAfterQuorum /\ OneWayPartitionState'
BackupAdvanceCommitOneWay == BackupAdvanceCommit /\ OneWayPartitionState'
TriggerStartViewChangeOneWay == TriggerStartViewChange /\ OneWayPartitionState'
EnterViewChangeAfterQuorumOneWay == EnterViewChangeAfterQuorum /\ OneWayPartitionState'
RepairAfterDVCOneWay == RepairAfterDVC /\ OneWayPartitionState'
StartNewViewOneWay == StartNewView /\ OneWayPartitionState'
TriggerStateSyncOneWay == TriggerStateSync /\ OneWayPartitionState'
StateSyncRepairRepliesOneWay == StateSyncRepairReplies /\ OneWayPartitionState'
StateSyncForestOneWay == StateSyncForest /\ OneWayPartitionState'
StateSyncCompleteOneWay == StateSyncComplete /\ OneWayPartitionState'
RepairGridBlockOneWay == RepairGridBlock /\ OneWayPartitionState'
RecordDeterminismMismatchOneWay == RecordDeterminismMismatch /\ OneWayPartitionState'
AdvanceClockOneWay == AdvanceClock /\ OneWayPartitionState'

OneWayNext ==
  PrepareCreateOneWay \/
  ReplicaAckPrepareOneWay \/
  PrimaryCommitAfterQuorumOneWay \/
  BackupAdvanceCommitOneWay \/
  TriggerStartViewChangeOneWay \/
  EnterViewChangeAfterQuorumOneWay \/
  RepairAfterDVCOneWay \/
  StartNewViewOneWay \/
  TriggerStateSyncOneWay \/
  StateSyncRepairRepliesOneWay \/
  StateSyncForestOneWay \/
  StateSyncCompleteOneWay \/
  RepairGridBlockOneWay \/
  RecordDeterminismMismatchOneWay \/
  AdvanceClockOneWay

OneWaySpec ==
  OneWayInit /\ [][OneWayNext]_vars

OneWayFairSpec ==
  OneWaySpec /\
  WF_vars(PrepareCreateOneWay) /\
  WF_vars(AdvanceClockOneWay)

PreparedWithoutQuorum ==
  \E op \in OpIds:
    /\ prepares[op].status = "prepared"
    /\ Cardinality(prepare_acks[op]) < cluster.replication_quorum

PrimaryStillNormal ==
  /\ PrimaryId \in ReplicaIds
  /\ replicas[PrimaryId].active
  /\ replicas[PrimaryId].status = "normal"

ViewChangeOrStandDownObserved ==
  \/ \E rid \in ReplicaIds: replicas[rid].status = "view_change"
  \/ ~PrimaryStillNormal

PreparedWithoutQuorumEventuallyForcesStandDown ==
  (PreparedWithoutQuorum /\ PrimaryStillNormal)
    ~> ViewChangeOrStandDownObserved

=============================================================================
