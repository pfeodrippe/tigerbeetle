# TLA+ Model Checking Notes

## Where This Was Tested

- Repository path: `/Users/pfeodrippe/dev/tigerbeetle`
- Specs path: `/Users/pfeodrippe/dev/tigerbeetle/docs/tla`
- Machine context (from TLC logs): `Mac OS X 15.1 aarch64`, `Oracle Corporation 23 x86_64`
- TLC run profile: breadth-first, `1 worker`, `-deadlock`, `-lncheck final`, `-cleanup`

## How It Was Run

From repo root:

```bash
CP=$(clojure -Sdeps '{:deps {pfeodrippe/tla-edn {:mvn/version "0.32.0"}}}' -Spath)
java -cp "$CP" tlc2.TLC \
  -deadlock \
  -lncheck final \
  -workers 1 \
  -cleanup \
  -config docs/tla/<Model>.cfg \
  docs/tla/<Model>.tla
```

## Latest Timings

Measured on **2026-02-20** with the command above.

| Model | Result | Duration | States Generated | Distinct States | Trace |
|---|---|---|---:|---:|---|
| `ClientSessions` | PASS | `06s` | 15,104 | 14,592 | `-` |
| `LedgerStateMachine` | PASS | `05s` | 8,352 | 8,352 | `-` |
| `RequestQueryContracts` | PASS | `08s` | 8,064 | 8,064 | `-` |
| `ClusterConsensus` | PASS (post-fix regression profile) | `03min 20s` | 559,824 | 180,640 | `-` |
| `ClusterConsensusOneWayPartitionBug` | FAIL (expected bug profile counterexample) | `01s` | 44 | 44 | `docs/tla/traces/cluster_consensus_oneway_partition_bug_counterexample.md` |
| `ClusterConsensusOneWayPartitionMitigated` | PASS | `01s` | 120 | 84 | `-` |

## Counterexample Traces

- `docs/tla/traces/cluster_consensus_oneway_partition_bug_counterexample.md`

## Historical Notes

- `docs/tla/traces/cluster_consensus_action_property_violation.md` is a pre-fix false-positive trace.
- Root cause was the old `NewPrepareAcksAreEligible` formula reading eligibility from pre-state during `PrepareCreate`.
- The property was fixed to evaluate newly added acks against post-state in `docs/tla/ClusterConsensus.tla`.
