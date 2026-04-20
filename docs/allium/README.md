# TigerBeetle Allium Specs

This directory contains a modular Allium specification set for TigerBeetle.
Each module is aligned to a model-checked TLA+ module in `docs/tla`.

## Modules

- `docs/allium/tigerbeetle-system.allium`
  - Root module that ties the subsystem specs into one coherent whole.
- `docs/allium/ledger-state-machine.allium`
  - Account/transfer domain behavior, idempotency, two-phase transfer lifecycle, and expiry.
  - TLA counterpart: `docs/tla/LedgerStateMachine.tla`.
- `docs/allium/request-and-query-contracts.allium`
  - Request batching semantics, linked-chain behavior, and read/query contracts.
  - TLA counterpart: `docs/tla/RequestQueryContracts.tla`.
- `docs/allium/client-sessions.allium`
  - Session registration/eviction, one in-flight request rule, retries, and restart semantics.
  - TLA counterpart: `docs/tla/ClientSessions.tla`.
- `docs/allium/cluster-consensus.allium`
  - VSR normal path, quorum commit, view change, repair, and state sync.
  - TLA counterpart: `docs/tla/ClusterConsensus.tla`.

## Intended Reading Order

1. `tigerbeetle-system.allium`
2. `ledger-state-machine.allium`
3. `request-and-query-contracts.allium`
4. `client-sessions.allium`
5. `cluster-consensus.allium`

## Notes

- These specs intentionally model externally observable behavior and protocol contracts.
- Implementation details such as exact on-disk formats and data-structure internals are out of scope.
- The `Model-Checked Guarantees` section in each module lists the safety/liveness checks enforced by TLC in the corresponding `.cfg`.
