#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — сбои синхронизации времени
#
# Поведенческие заметки (internal-docs "Состояния ноды"):
#   - Raft использует логические тики, а не системные часы → чистое расхождение часов низкорисково
#   - В сочетании с изоляцией Raft: временные метки HB хранилища выглядят устаревшими
#     для лидера → активируется путь storageFencingGracePeriod
#
# TIME-01: +10с на фолловере (ниже порога, фенсинг не ожидается)
# TIME-02: -30с на фолловере + блокировка Raft (устаревший HB → фенсинг возможен)
# TIME-03: +30с на фолловере + блокировка Raft (HB лидера выглядит свежим для фолловера)
# TIME-04: -30с на лидере + блокировка Raft (HB лидера выглядит устаревшим для фолловеров)
# TIME-05: -45с на всех нодах одновременно (синхронизировано, кластер стабилен)
# TIME-06: +45с на всех нодах одновременно (синхронизировано, кластер стабилен)
# =============================================================================

load 'load_helper'

_run_time_raft_test() {
    local test_id="$1" offset_expr="$2" sleep_duration="$3"
    log_step "${test_id}: time offset '$offset_expr' + Raft block on follower"
    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"
    set_time_offset "$target_node" "$offset_expr"
    raft_isolate_node "$target_node"
    assert_raft_node_isolated "$target_node"
    sleep "$sleep_duration"
    log_info "Post-fault state..."
    raft_unblock_node "$target_node"
    restore_ntp "$target_node"
    wait_for_cluster_running "$FAULT_NET_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "TIME-01: +10s on follower — no fencing triggered (sub-threshold)" {
    log_step "TIME-01: +10s offset on follower"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"

    set_time_offset "$target_node" "+10 seconds"
    sleep 20
    log_info "Post-offset: leader state: $(get_node_state "$(api_for_node "$leader_id")" 2>/dev/null)"

    restore_ntp "$target_node"

    wait_for_cluster_running "$FAULT_RAFT_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "TIME-02: -30s on follower + Raft block — stale HB detected, fencing, recovery" {
    _run_time_raft_test "TIME-02" "-30 seconds" 45
}

@test "TIME-03: +30s on follower + Raft block — leader HB appears fresh to follower" {
    _run_time_raft_test "TIME-03" "+30 seconds" 40
}

@test "TIME-04: -30s on leader + Raft block — leader HB appears stale to followers" {
    log_step "TIME-04: -30s + Raft block on leader"

    local leader_id
    leader_id=$(get_leader_id)

    set_time_offset "$leader_id" "-30 seconds"
    raft_isolate_node "$leader_id"
    assert_raft_node_isolated "$leader_id"

    sleep 40
    log_info "Post-fault state..."

    raft_unblock_node "$leader_id"
    restore_ntp "$leader_id"

    wait_for_cluster_running "$FAULT_NET_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "TIME-05: -45s on all nodes (NTP off) — synchronized skew, cluster stable" {
    log_step "TIME-05: -45s on all nodes simultaneously"

    for node in 1 2 3; do set_time_offset "$node" "-45 seconds"; done
    sleep 30
    log_info "Post-offset state (all synchronized to past)..."
    for node in 1 2 3; do restore_ntp "$node"; done

    wait_for_cluster_running "$FAULT_RAFT_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "TIME-06: +45s on all nodes (NTP off) — synchronized skew, cluster stable" {
    log_step "TIME-06: +45s on all nodes simultaneously"

    for node in 1 2 3; do set_time_offset "$node" "+45 seconds"; done
    sleep 30
    log_info "Post-offset state..."
    for node in 1 2 3; do restore_ntp "$node"; done

    wait_for_cluster_running "$FAULT_RAFT_RECOVERY_TIMEOUT"
    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success; assert_output --partial "NODE_STATE_RUNNING"
    done
}
