#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — деградация сети (потери пакетов, задержки)
# NETDEG-01: 30% потерь пакетов на Raft-трафике
# NETDEG-02: 50% потерь пакетов на Raft-трафике
# NETDEG-03: 2000мс задержки на Raft-трафике
# NETDEG-04: 5000мс задержки на Raft-трафике
# =============================================================================

load 'load_helper'

_run_netdeg_test() {
    local test_id="$1" netem_args="$2" sleep_duration="$3"
    log_step "${test_id}: applying tc netem '$netem_args' on all nodes"
    for node in 1 2 3; do tc_degrade_raft "$node" "$netem_args"; done
    sleep "$sleep_duration"
    log_info "Post-degradation state..."
    for node in 1 2 3; do tc_clear "$node"; done
    wait_for_cluster_running "$FAULT_RAFT_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "NETDEG-01: 30% packet loss on Raft — cluster stays operational" {
    _run_netdeg_test "NETDEG-01" "loss 30%" 30
}

@test "NETDEG-02: 50% packet loss on Raft — may re-elect, cluster recovers" {
    _run_netdeg_test "NETDEG-02" "loss 50%" 40
}

@test "NETDEG-03: 2000ms Raft latency — cluster stable under high latency" {
    _run_netdeg_test "NETDEG-03" "delay 2000ms" 30
}

@test "NETDEG-04: 5000ms Raft latency — leader re-election likely, cluster recovers" {
    _run_netdeg_test "NETDEG-04" "delay 5000ms" 40
}
