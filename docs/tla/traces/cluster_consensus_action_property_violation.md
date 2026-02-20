# ClusterConsensus Action-Property Counterexample (Historical, Pre-Fix)

## Metadata

- Spec: `docs/tla/ClusterConsensus.tla`
- Config: `docs/tla/ClusterConsensus.cfg`
- Failed property (old formula): `NewPrepareAcksAreEligible` (`docs/tla/ClusterConsensus.tla:675`)
- Run date: `2026-02-20`
- Runtime: `06min 19s`
- States: `595,317 generated`, `587,309 distinct`

## Counterexample Steps

1. `State 1` (`Init`)
- Replicas start in view `0`, replica `1` is primary.
- `client_requests` has one request (`9001`).
- `start_view_change_signals` has signals from backups `2` and `3`.

2. `State 2` (`TriggerStartViewChange`)
- Backup `2` enters `view_change`.
- SVC votes for target view `1` become `{2}`.

3. `State 3` (`TriggerStartViewChange`)
- Backup `3` also enters `view_change`.
- SVC votes for target view `1` become `{2, 3}` (quorum).

4. `State 4` (`EnterViewChangeAfterQuorum`)
- All replicas move to view `1`, status `view_change`.
- `view_change_round = collecting_dvc`.

5. `State 5` (`RepairAfterDVC`)
- `view_change_round = repairing`.

6. `State 6` (`StartNewView`)
- Replica `2` becomes primary for view `1`.
- All replicas become `normal`.

7. `State 7` (`PrepareCreate`)
- Primary `2` creates `prepare op=1` in view `1`.
- `prepare_acks[1]` changes from `{}` to `{2}` in the same transition.

## Why The Property Fails

`NewPrepareAcksAreEligible` checks each newly added ack in `prepare_acks'[op] \\ prepare_acks[op]` using `AckEligible(op, rid)`.

`AckEligible(op, rid)` reads `prepares[op]` from the pre-state. In this trace, the same transition both:

- creates `prepares[1] = prepared` (post-state), and
- inserts ack `{2}`.

So the check evaluates eligibility against the old `prepares[1] = none`, which makes the property fail even though the transition is intended by the model.

## Fix Applied

The property was updated to validate newly added acks against post-state (`prepares'` and `replicas'`) in `docs/tla/ClusterConsensus.tla`.
