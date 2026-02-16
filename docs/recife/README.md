# TigerBeetle Recife Specs

This directory contains a modular Recife model suite for TigerBeetle.

## Modules

- `docs/recife/src/tigerbeetle/recife/ledger_state_machine.clj`
  - Account/transfer state machine, idempotency outcomes, pending lifecycle, expiry.
- `docs/recife/src/tigerbeetle/recife/request_and_query_contracts.clj`
  - Request/batch envelope behavior, linked chains, imported-mode rules, reply shapes.
- `docs/recife/src/tigerbeetle/recife/client_sessions.clj`
  - Session registration/eviction, in-flight discipline, retry and restart behavior.
- `docs/recife/src/tigerbeetle/recife/cluster_consensus.clj`
  - Prepare/ack/commit flow, view-change progression, sync and repair lifecycle.
- `docs/recife/src/tigerbeetle/recife/tigerbeetle_system.clj`
  - System composition that merges the modules above into one executable model set.
- `docs/recife/src/tigerbeetle/recife/runner.clj`
  - Entrypoint that runs each module and the composed system.

## Run

```bash
cd docs/recife
clojure -M -m tigerbeetle.recife.runner
```

## Notes

- These models focus on observable behavioral contracts.
- They intentionally abstract away low-level storage and binary protocol encoding details.
