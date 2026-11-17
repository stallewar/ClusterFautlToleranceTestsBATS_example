#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — комбинированные сбои
# COMBO-01: Изоляция Raft → затем блокировка хранилища на том же фолловере
# COMBO-02: Блокировка хранилища → затем изоляция Raft на том же фолловере
# COMBO-03: Изоляция Raft фолловера + блокировка хранилища лидера одновременно [no-dual-run]
# =============================================================================

load 'load_helper'

@test "COMBO-01: Raft isolation then storage block on same follower" {
    log_step "COMBO-01: sequential faults — Raft first, then storage"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"

    log_step "COMBO-01: inject phase 1 — raft_isolate_node node$target_node"
    raft_isolate_node "$target_node"
    assert_raft_node_isolated "$target_node"
    sleep 10

    log_step "COMBO-01: inject phase 2 — storage_block node$target_node"
    storage_block "$target_node"
    assert_storage_blocked "$target_node"
    sleep 30

    log_step "COMBO-01: restore"
    raft_unblock_node "$target_node"
    storage_unblock "$target_node"

    log_step "COMBO-01: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_NET_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "COMBO-02: Storage block then Raft isolation on same follower" {
    log_step "COMBO-02: sequential faults — storage first, then Raft"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"

    log_step "COMBO-02: inject phase 1 — storage_block node$target_node"
    storage_block "$target_node"
    assert_storage_blocked "$target_node"
    sleep 10

    log_step "COMBO-02: inject phase 2 — raft_isolate_node node$target_node"
    raft_isolate_node "$target_node"
    assert_raft_node_isolated "$target_node"
    sleep 30

    log_step "COMBO-02: restore"
    storage_unblock "$target_node"
    raft_unblock_node "$target_node"

    log_step "COMBO-02: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_NET_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "COMBO-03: Raft-isolate follower + storage-block leader — cascading failure [no-dual-run]" {
    log_step "COMBO-03: simultaneous — follower Raft + leader storage"

    local vm_id="test-vm-combo03-$(date +%s%3N)"
    local leader_id
    leader_id=$(get_leader_id)
    local leader_target
    leader_target=$(api_for_node "$leader_id")
    read -ra follower_ids <<< "$(get_follower_ids)"
    local isolated_follower="${follower_ids[0]}"

    run grpc_start_vm "$leader_target" "$(build_start_vm_request "$vm_id")"
    assert_success
    sleep 10

    log_step "COMBO-03: inject — raft_isolate follower node$isolated_follower"
    raft_isolate_node "$isolated_follower"
    assert_raft_node_isolated "$isolated_follower"
    sleep 5

    log_step "COMBO-03: inject — storage_block leader node$leader_id"
    storage_block "$leader_id"
    assert_storage_blocked "$leader_id"

    poll_no_dual_run "$vm_id" 40

    log_step "COMBO-03: restore"
    raft_unblock_node "$isolated_follower"
    storage_unblock "$leader_id"

    log_step "COMBO-03: assert — cluster recovered"
    wait_for_cluster_running "$FAULT_NET_RECOVERY_TIMEOUT"
}
