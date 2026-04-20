---- MODULE ClusterConsensusOneWayPartitionMitigated ----
EXTENDS ClusterConsensusOneWayPartitionBug

PrimaryStandDownAfterStall ==
  /\ PreparedWithoutQuorum
  /\ PrimaryStillNormal
  /\ LET pid == PrimaryId IN
       /\ replicas' = [replicas EXCEPT ![pid].status = "view_change"]
       /\ UNCHANGED <<cluster, client_requests, prepares, prepare_acks, commit_notices,
                       start_view_change_signals, svc_votes, view_change_round,
                       dvc_quorum_observed, repair_completed_views, state_sync_needs,
                       state_sync, sync_ready_for_forest, next_checkpoint_committed,
                       grid_repairs, matching_grid_blocks, checkpoint_mismatches,
                       determinism_violations, cluster_events, clock>>

MitigatedNext ==
  OneWayNext \/
  (PrimaryStandDownAfterStall /\ OneWayPartitionState')

MitigatedSpec ==
  OneWayInit /\ [][MitigatedNext]_vars

MitigatedFairSpec ==
  MitigatedSpec /\
  WF_vars(PrepareCreateOneWay) /\
  WF_vars(AdvanceClockOneWay) /\
  WF_vars(PrimaryStandDownAfterStall)

=============================================================================
