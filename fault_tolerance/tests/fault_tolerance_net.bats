#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — полная сетевая изоляция
# NET-3-01: Полная изоляция фолловера (кворум поддерживается через 2 оставшиеся ноды)
# NET-3-02: Полная изоляция лидера [no-dual-run]
# NET-3-03: Изоляция 2 нод — кворум потерян, кластер недоступен до восстановления
# =============================================================================

load 'load_helper'

@test "NET-3-01: Full network isolation of follower — quorum held, self-fencing, recovery" {
    log_step "NET-3-01: full isolation of a follower"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local isolated="${follower_ids[0]}"

    log_step "NET-3-01: inject — net_isolate_node node$isolated"
    net_isolate_node "$isolated"
    assert_net_isolated "$isolated"

    sleep 25
    log_info "Post-isolation state..."

    log_step "NET-3-01: restore — net_unblock_all node$isolated"
    net_unblock_all "$isolated"

    log_step "NET-3-01: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_NET_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "NET-3-02: Full network isolation of leader — new leader elected, no dual-run [no-dual-run]" {
    log_step "NET-3-02: full isolation of leader"

    local vm_id="test-vm-net02-$(date +%s%3N)"
    local leader_id
    leader_id=$(get_leader_id)
    local leader_target
    leader_target=$(api_for_node "$leader_id")

    run grpc_start_vm "$leader_target" "$(build_start_vm_request "$vm_id")"
    assert_success
    sleep 10

    log_step "NET-3-02: inject — net_isolate_node node$leader_id"
    net_isolate_node "$leader_id"
    assert_net_isolated "$leader_id"

    poll_no_dual_run "$vm_id" 25
    log_info "Post-isolation state..."

    log_step "NET-3-02: restore — net_unblock_all node$leader_id"
    net_unblock_all "$leader_id"

    log_step "NET-3-02: assert — cluster recovered"
    wait_for_cluster_running "$FAULT_NET_RECOVERY_TIMEOUT"
}

@test "NET-3-03: Isolate 2 nodes — quorum lost; recover after restore" {
    log_step "NET-3-03: isolate both followers, break quorum"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"

    for fid in "${follower_ids[@]}"; do
        net_isolate_node "$fid"
    done
    for fid in "${follower_ids[@]}"; do assert_net_isolated "$fid"; done

    sleep 20
    log_info "Нет кворума — ожидается, что gRPC-вызовы будут завершаться ошибкой (ожидаемое поведение)"

    log_step "NET-3-03: restore — net_unblock_all on both followers"
    for fid in "${follower_ids[@]}"; do
        net_unblock_all "$fid"
    done

    log_step "NET-3-03: assert — all nodes NODE_STATE_RUNNING after restore"
    wait_for_cluster_running "$FAULT_NET_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}
