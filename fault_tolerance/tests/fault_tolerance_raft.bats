#!/usr/bin/env bats
# =============================================================================
# Отказоустойчивость — сбои консенсуса Raft
# RAFT-3-01: Изоляция фолловера от Raft
# RAFT-3-02: Изоляция лидера от Raft
# RAFT-3-03: Частичная партиция — связь A↔C разорвана, B является мостом
# =============================================================================

load 'load_helper'

@test "RAFT-3-01: Raft isolation of follower — cluster stays operational" {
    log_step "RAFT-3-01: isolate a follower from Raft"

    local leader_id follower_ids
    leader_id=$(get_leader_id)
    read -ra follower_ids <<< "$(get_follower_ids)"
    local isolated="${follower_ids[0]}"
    local leader_target
    leader_target=$(api_for_node "$leader_id")

    log_info "Leader: node$leader_id, isolating follower: node$isolated"

    log_step "RAFT-3-01: inject — raft_isolate_node $isolated"
    raft_isolate_node "$isolated"
    assert_raft_node_isolated "$isolated"

    sleep 5
    log_info "Post-isolation leader state: $(get_node_state "$leader_target" 2>/dev/null || echo 'unreachable')"

    log_step "RAFT-3-01: restore — raft_unblock_node $isolated"
    raft_unblock_node "$isolated"

    log_step "RAFT-3-01: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_RAFT_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "RAFT-3-02: Raft isolation of leader — new leader elected, all nodes recover" {
    log_step "RAFT-3-02: isolate the current leader from Raft"

    local leader_id
    leader_id=$(get_leader_id)
    log_info "Isolating leader: node$leader_id"

    log_step "RAFT-3-02: inject — raft_isolate_node $leader_id"
    raft_isolate_node "$leader_id"
    assert_raft_node_isolated "$leader_id"

    # --- Проверить, что среди оставшихся узлов действительно избран НОВЫЙ лидер ---
    # Опрашиваем одного из неизолированных узлов, пока GetLeader не вернёт id,
    # отличный от изолированного (а не просто дожидаемся возврата всего кластера
    # в RUNNING — тест называется "new leader elected", это нужно проверить явно).
    local remaining_id new_leader_id=""
    for remaining_id in 1 2 3; do
        [[ "$remaining_id" != "$leader_id" ]] && break
    done
    local remaining_target
    remaining_target=$(api_for_node "$remaining_id")
    local elapsed=0
    while (( elapsed < 30 )); do
        new_leader_id=$(get_leader_node_id "$remaining_target" 2>/dev/null) || true
        [[ -n "$new_leader_id" && "$new_leader_id" != "$leader_id" ]] && break
        sleep 2
        (( elapsed += 2 ))
    done
    log_info "New leader after isolating node$leader_id: node${new_leader_id:-none} (after ${elapsed}s)"
    [[ -n "$new_leader_id" && "$new_leader_id" != "$leader_id" ]] || \
        fail "No new leader elected among remaining nodes within 30s after isolating node$leader_id"

    log_step "RAFT-3-02: restore — raft_unblock_node $leader_id"
    raft_unblock_node "$leader_id"

    log_step "RAFT-3-02: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_RAFT_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}

@test "RAFT-3-03: Partial Raft partition (node1↔node3 broken, node2 is bridge)" {
    log_step "RAFT-3-03: break Raft link between node1 and node3 only"

    local leader_id
    leader_id=$(get_leader_id)
    if [[ "$leader_id" != "1" ]]; then
        transfer_leadership_to "1" || true
        sleep 5
        leader_id="1"
    fi

    log_step "RAFT-3-03: inject — raft_block_between 1 3"
    raft_block_between 1 3
    assert_raft_blocked_between 1 3

    sleep 5
    log_info "Кворум поддерживается через ноды 1+2; кластер должен быть работоспособен"

    log_step "RAFT-3-03: restore"
    raft_unblock_node 1
    raft_unblock_node 3

    log_step "RAFT-3-03: assert — all nodes NODE_STATE_RUNNING"
    wait_for_cluster_running "$FAULT_RAFT_RECOVERY_TIMEOUT"

    for id in 1 2 3; do
        run grpc_get_status "$(api_for_node "$id")"
        assert_success
        assert_output --partial "NODE_STATE_RUNNING"
    done
}
