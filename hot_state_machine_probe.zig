const constants = @import("src/constants.zig");
const tigerbeetle_main = @import("src/tigerbeetle/main.zig");

const StateMachine = tigerbeetle_main.StateMachine;
const Operation = StateMachine.Operation;

fn stateMachineForestOptionsReadProbe() u32 {
    const options = tigerbeetle_main.StateMachine.forest_options(.{
        .batch_size_limit = 4096,
        .lsm_forest_compaction_block_count = 1,
        .lsm_forest_node_count = 1,
        .cache_entries_accounts = 7,
        .cache_entries_transfers = 11,
        .cache_entries_transfers_pending = 13,
        .log_trace = false,
        .aof_recovery = false,
    });
    return options.accounts.prefetch_entries_for_read_max;
}

fn stateMachineForestOptionsCacheProbe() u32 {
    const options = tigerbeetle_main.StateMachine.forest_options(.{
        .batch_size_limit = 4096,
        .lsm_forest_compaction_block_count = 1,
        .lsm_forest_node_count = 1,
        .cache_entries_accounts = 7,
        .cache_entries_transfers = 11,
        .cache_entries_transfers_pending = 13,
        .log_trace = false,
        .aof_recovery = false,
    });
    return options.accounts.cache_entries_max;
}

fn stateMachineCommitAssocProbe() usize {
    _ = constants.message_body_size_max;
    return StateMachine.commit(undefined, 1, 1, 1, .pulse, null, null);
}

fn stateMachineExecuteMultiBatchAssocProbe() usize {
    _ = constants.message_body_size_max;
    return StateMachine.execute_multi_batch(undefined, 1, Operation.create_accounts, null, null);
}
