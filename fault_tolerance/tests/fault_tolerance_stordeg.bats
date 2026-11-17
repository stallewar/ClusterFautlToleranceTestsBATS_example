#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — деградация хранилища
# STORDEG-01: >100мс задержки на трафике хранилища
# STORDEG-02: заполнение STORAGE_PATH с помощью dd
# STORDEG-03: заполнение локального /tmp с помощью dd
# =============================================================================

load 'load_helper'

@test "STORDEG-01: 150ms latency on storage interface — cluster tolerates slow storage" {
    log_step "STORDEG-01: 150ms storage delay on all nodes"
    for node in 1 2 3; do tc_degrade_storage "$node" "delay 150ms"; done
    sleep 30
    log_info "Post-degradation state..."
    for node in 1 2 3; do tc_clear "$node"; done
    wait_for_cluster_running "$FAULT_STORAGE_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "STORDEG-02: Fill STORAGE_PATH with dd — storage heartbeat disrupted" {
    log_step "STORDEG-02: fill storage path on all nodes"
    for node in 1 2 3; do storage_fill_start "$node"; done
    sleep 40
    log_info "Post-fill state..."
    for node in 1 2 3; do storage_fill_stop "$node"; done
    wait_for_cluster_running "$FAULT_CLUSTER_STORAGE_WAIT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "STORDEG-03: Fill /tmp with dd — local disk pressure on all nodes" {
    log_step "STORDEG-03: fill /tmp on all nodes"
    for node in 1 2 3; do local_disk_fill_start "$node"; done
    sleep 30
    log_info "Post-fill state..."
    for node in 1 2 3; do local_disk_fill_stop "$node"; done
    wait_for_cluster_running "$FAULT_PROCESS_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}
