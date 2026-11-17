#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — сбои Host Controller
# HC-01: systemctl stop host-agent на фолловере
# HC-02: systemctl stop host-agent на лидере [no-dual-run]
# HC-03: kill -9 host-agentd (systemd автоматически перезапускает)
# HC-04: остановка HC + блокировка Raft на одном фолловере
# =============================================================================

load 'load_helper'

# Хелпер для тестов на фолловере, где процесс перезапускается автоматически (например, kill9).
# HC-01 исключён — он использует service_stop, которому для восстановления требуется явный вызов service_start
# перед wait_for_service_state, что делает его структурно отличным от остальных.
_run_hc_follower_test() {
    local test_id="$1" service="$2" inject_fn="$3" process_name="$4" pre_wait_sleep="${5:-0}"
    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"
    log_step "${test_id}: inject on follower node${target_node}"
    if [[ "$inject_fn" == "process_kill9" ]]; then
        process_kill9 "$target_node" "$process_name"
    else
        "$inject_fn" "$target_node" "$service"
    fi
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

@test "HC-01: Stop host-agent on follower — cluster stays operational" {
    log_step "HC-01: stop host-agent on follower"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"

    log_step "HC-01: inject — service_stop host-agent on node$target_node"
    service_stop "$target_node" "host-agent"

    sleep 20
    log_info "Post-fault state: $(get_node_state "$(api_for_node "$leader_id")" 2>/dev/null)"

    log_step "HC-01: restore — service_start host-agent on node$target_node"
    service_start "$target_node" "host-agent"
    wait_for_service_state "$target_node" "host-agent" "active" 30

    log_step "HC-01: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_PROCESS_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "HC-02: Stop host-agent on leader — new leader, VM not dual-run [no-dual-run]" {
    log_step "HC-02: stop host-agent on leader"

    local vm_id="test-vm-hc02-$(date +%s%3N)"
    local leader_id
    leader_id=$(get_leader_id)
    local leader_target
    leader_target=$(api_for_node "$leader_id")

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

    log_step "HC-02: inject — service_stop host-agent on leader node$leader_id"
    service_stop "$leader_id" "host-agent"

    poll_no_dual_run "$vm_id" 25
    log_info "Post-fault state..."

    log_step "HC-02: restore — service_start host-agent on node$leader_id"
    service_start "$leader_id" "host-agent"
    wait_for_service_state "$leader_id" "host-agent" "active" 30

    log_step "HC-02: assert — cluster recovered"
    wait_for_cluster_running "$FAULT_PROCESS_RECOVERY_TIMEOUT"
}

@test "HC-03: kill -9 host-agentd — systemd restarts, cluster recovers" {
    _run_hc_follower_test "HC-03" "host-agent" "process_kill9" "host-agentd" 10
}

@test "HC-04: Stop HC + Raft block on follower — combined fault, recovery" {
    log_step "HC-04: stop HC and isolate Raft on same follower"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local target_node="${follower_ids[0]}"

    log_step "HC-04: inject — service_stop host-agent + raft_isolate_node $target_node"
    service_stop "$target_node" "host-agent"
    raft_isolate_node "$target_node"
    assert_raft_node_isolated "$target_node"

    sleep 25
    log_info "Post-fault state..."

    log_step "HC-04: restore"
    raft_unblock_node "$target_node"
    service_start "$target_node" "host-agent"
    wait_for_service_state "$target_node" "host-agent" "active" 30

    log_step "HC-04: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_PROCESS_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}
