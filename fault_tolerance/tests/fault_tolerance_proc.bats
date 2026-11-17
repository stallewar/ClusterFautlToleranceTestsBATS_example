#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — сбои процесса cluster-service
# PROC-01: kill -9 cluster-service на фолловере
# PROC-02: kill -9 cluster-service на лидере [no-dual-run]
# PROC-03: systemctl restart cluster-service на фолловере
# PROC-04: остановка CS >fenceTimeout (30.5с) на фолловере — фенсинг срабатывает
# =============================================================================

load 'load_helper'

_run_proc_follower_test() {
    local test_id="$1" service="$2" inject_fn="$3" pre_wait_sleep="${4:-0}"
    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"
    log_step "${test_id}: inject on follower node${target_node}"
    "$inject_fn" "$target_node" "$service"
    [[ "$pre_wait_sleep" -gt 0 ]] && sleep "$pre_wait_sleep"
    wait_for_service_state "$target_node" "$service" "active" 30
    log_step "${test_id}: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_PROCESS_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "PROC-01: kill -9 cluster-service on follower — restarts and rejoins" {
    _run_proc_follower_test "PROC-01" "cluster-service" "process_kill9" 5
}

@test "PROC-02: kill -9 cluster-service on leader — new leader, no dual-run [no-dual-run]" {
    log_step "PROC-02: kill CS on leader"

    local vm_id="test-vm-proc02-$(date +%s%3N)"
    local leader_id
    leader_id=$(get_leader_id)
    local leader_target
    leader_target=$(api_for_node "$leader_id")

    run grpc_start_vm "$leader_target" "$(build_start_vm_request "$vm_id")"
    assert_success
    sleep 10

    log_step "PROC-02: inject — process_kill9 cluster-service on node$leader_id"
    process_kill9 "$leader_id" "cluster-service"
    poll_no_dual_run "$vm_id" 35
    wait_for_service_state "$leader_id" "cluster-service" "active" 30

    log_step "PROC-02: assert — cluster recovered"
    wait_for_cluster_running "$FAULT_PROCESS_RECOVERY_TIMEOUT"
}

@test "PROC-03: systemctl restart cluster-service on follower — seamless rejoin" {
    _run_proc_follower_test "PROC-03" "cluster-service" "service_restart" 0
}

@test "PROC-04: Stop CS on follower beyond fenceTimeout — fencing triggered, node re-joins" {
    log_step "PROC-04: stop CS on follower, wait >fenceTimeout (30.5s)"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"

    log_step "PROC-04: inject — service_stop cluster-service on node$target_node"
    service_stop "$target_node" "cluster-service"

    log_step "PROC-04: waiting 45s for fenceTimeout to expire..."
    sleep 45
    log_info "Фенсинг должен был произойти; перезапускаем CS..."

    log_step "PROC-04: restore — service_start cluster-service on node$target_node"
    service_start "$target_node" "cluster-service"
    wait_for_service_state "$target_node" "cluster-service" "active" 30

    log_step "PROC-04: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_PROCESS_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}
