#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — сбои хранилища
# STOR-01: Фолловер теряет iSCSI-хранилище → фенсинг → восстановление
# STOR-02: Лидер теряет хранилище → передаёт лидерство → фенсинг [no-dual-run]
# STOR-05: Все 3 ноды теряют хранилище → кластер ждёт → восстановление после разблокировки
# STOR-06: STOR-05 + хранилище возвращается сначала на B+C [no-dual-run]
# STOR-07: STOR-05 + хранилище возвращается только на одном фолловере
# =============================================================================

load 'load_helper'

@test "STOR-01: Follower loses storage — fencing triggered, cluster recovers" {
    log_step "STOR-01: block storage on a follower"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local isolated="${follower_ids[0]}"

    log_info "Leader: node$leader_id, blocking storage on follower: node$isolated"

    log_step "STOR-01: inject — storage_block node$isolated"
    storage_block "$isolated"
    assert_storage_blocked "$isolated"

    log_step "STOR-01: waiting 40s for fencing cycle..."
    sleep 40
    log_info "Post-fault state: $(get_node_state "$(api_for_node "$leader_id")" 2>/dev/null || echo 'unreachable')"

    log_step "STOR-01: restore — storage_unblock node$isolated"
    storage_unblock "$isolated"

    log_step "STOR-01: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_STORAGE_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "STOR-02: Leader loses storage — transfers leadership, fences, recovers [no-dual-run]" {
    log_step "STOR-02: block storage on leader; VM must not dual-run"

    local vm_id="test-vm-stor02-$(date +%s%3N)"
    local leader_id
    leader_id=$(get_leader_id)
    local leader_target
    leader_target=$(api_for_node "$leader_id")

    log_step "STOR-02: start VM $vm_id on leader"
    run grpc_start_vm "$leader_target" "$(build_start_vm_request "$vm_id")"
    assert_success

    local attempts=0
    while (( attempts < 30 )); do
        local vm_status
        vm_status=$(grpc_list_vms "$leader_target" 2>/dev/null \
            | jq -r --arg v "$vm_id" '.vms[]? | select(.id.id==$v) | .status' 2>/dev/null)
        [[ "$vm_status" == "VM_STATUS_RUNNING" ]] && break
        sleep 2; (( attempts++ ))
    done
    log_info "VM $vm_id status before fault: $vm_status"

    log_step "STOR-02: inject — storage_block leader node$leader_id"
    storage_block "$leader_id"
    assert_storage_blocked "$leader_id"

    poll_no_dual_run "$vm_id" 45
    log_info "Post-fault state: $(get_node_state "$leader_target" 2>/dev/null || echo 'unreachable')"

    log_step "STOR-02: restore — storage_unblock node$leader_id"
    storage_unblock "$leader_id"

    log_step "STOR-02: assert — cluster recovered"
    wait_for_cluster_running "$FAULT_STORAGE_RECOVERY_TIMEOUT"
}

@test "STOR-05: All 3 nodes lose storage — cluster waits, recovers after unblock" {
    log_step "STOR-05: block storage simultaneously on all nodes"

    for node in 1 2 3; do
        storage_block "$node"
    done
    for node in 1 2 3; do assert_storage_blocked "$node"; done

    sleep 35
    log_info "Post-fault state (all storage blocked)..."

    log_step "STOR-05: restore — unblock storage on all nodes"
    for node in 1 2 3; do
        storage_unblock "$node"
    done

    log_step "STOR-05: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_CLUSTER_STORAGE_WAIT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "STOR-06: All nodes lose storage, B+C recover first — leadership transfers [no-dual-run]" {
    log_step "STOR-06: all storage blocked, then restored on followers B+C"

    local vm_id="test-vm-stor06-$(date +%s%3N)"
    local leader_id
    leader_id=$(get_leader_id)
    local leader_target
    leader_target=$(api_for_node "$leader_id")
    read -ra follower_ids <<< "$(get_follower_ids)"

    run grpc_start_vm "$leader_target" "$(build_start_vm_request "$vm_id")"
    assert_success

    local attempts=0
    while (( attempts < 30 )); do
        local vm_status
        vm_status=$(grpc_list_vms "$leader_target" 2>/dev/null \
            | jq -r --arg v "$vm_id" '.vms[]? | select(.id.id==$v) | .status' 2>/dev/null)
        [[ "$vm_status" == "VM_STATUS_RUNNING" ]] && break
        sleep 2; (( attempts++ ))
    done
    log_info "VM $vm_id status before fault: $vm_status"

    for node in 1 2 3; do
        storage_block "$node"
    done
    for node in 1 2 3; do assert_storage_blocked "$node"; done
    sleep 15

    for fid in "${follower_ids[@]}"; do
        storage_unblock "$fid"
    done

    poll_no_dual_run "$vm_id" 45
    log_info "Post-restore state (leader still blocked)..."
    storage_unblock "$leader_id"

    log_step "STOR-06: assert — cluster recovered"
    wait_for_cluster_running "$FAULT_CLUSTER_STORAGE_WAIT"
}

@test "STOR-07: All nodes lose storage, only one follower recovers" {
    log_step "STOR-07: all blocked, only one follower gets storage back"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local recovering="${follower_ids[0]}"

    for node in 1 2 3; do
        storage_block "$node"
    done
    for node in 1 2 3; do assert_storage_blocked "$node"; done
    sleep 15

    storage_unblock "$recovering"
    sleep 50
    log_info "Only node$recovering has storage..."

    for node in 1 2 3; do
        storage_unblock "$node" || true
    done

    log_step "STOR-07: assert — cluster recovers"
    wait_for_cluster_running "$FAULT_CLUSTER_STORAGE_WAIT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}
