# TigerBeetle Allium Specs

This directory contains a modular Allium specification set for TigerBeetle.

## Modules

- `docs/allium/tigerbeetle-system.allium`
  - Root module that ties the subsystem specs into one coherent whole.
- `docs/allium/ledger-state-machine.allium`
  - Account/transfer domain behavior, idempotency, two-phase transfer lifecycle, and expiry.
- `docs/allium/request-and-query-contracts.allium`
  - Request batching semantics, linked-chain behavior, and read/query contracts.
- `docs/allium/client-sessions.allium`
  - Session registration/eviction, one in-flight request rule, retries, and restart semantics.
- `docs/allium/cluster-consensus.allium`
  - VSR normal path, quorum commit, view change, repair, and state sync.

## Intended Reading Order

1. `tigerbeetle-system.allium`
2. `ledger-state-machine.allium`
3. `request-and-query-contracts.allium`
4. `client-sessions.allium`
5. `cluster-consensus.allium`

## Notes

- These specs intentionally model externally observable behavior and protocol contracts.
- Implementation details such as exact on-disk formats and data-structure internals are out of scope.
