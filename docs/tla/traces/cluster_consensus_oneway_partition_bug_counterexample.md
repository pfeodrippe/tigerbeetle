# ClusterConsensusOneWayPartitionBug Temporal Counterexample

## Metadata

- Spec: `docs/tla/ClusterConsensusOneWayPartitionBug.tla`
- Config: `docs/tla/ClusterConsensusOneWayPartitionBug.cfg`
- Failed property: `PreparedWithoutQuorumEventuallyForcesStandDown`
- Run date: `2026-02-20`
- Runtime: `01s`
- States: `44 generated`, `44 distinct`

## Counterexample Steps

1. `State 1` (`OneWayInit`)
- One request is present.
- Primary is replica `1`.
- View-change signaling and sync channels are empty by construction.

2. `State 2` (`RepairGridBlockOneWay`)
- Unrelated repair event executes.

3. `State 3` (`PrepareCreateOneWay`)
- Primary creates `prepare op=1`.
- `prepare_acks[1] = {1}` (self-ack only), below quorum `2`.
- `PreparedWithoutQuorum` becomes true.

4. `State 4` (`AdvanceClockOneWay`)
- Primary remains `normal`.
- No view change or stand-down occurs.

5. `State 5` (`AdvanceClockOneWay`)
- Same condition persists.

6. `State 6` (`AdvanceClockOneWay`)
- Same condition persists.

7. `State 7` (`Stuttering`)
- System stutters with prepared-without-quorum state and normal primary.

## Why The Property Fails

The one-way partition profile intentionally blocks quorum progress and view-change signaling. This allows a behavior where:

- a prepare remains below quorum indefinitely, and
- the primary never leaves `normal`.

That directly violates `PreparedWithoutQuorumEventuallyForcesStandDown`. This counterexample is expected for the bug profile and is the reason `ClusterConsensusOneWayPartitionMitigated` exists.
