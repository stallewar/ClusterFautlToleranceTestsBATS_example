#!/usr/bin/env bash
# =============================================================================
# Вспомогательный модуль начальной загрузки кластера
# Инициализирует node01 и подключает node02 + node03, формируя кластер из 3 узлов.
# По завершении гарантирует, что лидером является node01.
#
# Зависит от: grpc_helpers.bash (wait_for_node_state, get_leader_node_id,
#             get_target_for_node, wait_for_leader_node_id, CLUSTER_API_NODE*,
#             PROTO_ROOT), logging.bash
# Переменные кластера: NODE0*_RAFT_IP, NODE0*_HC, RAFT_PORT, CLUSTER_API_PORT, STORAGE_HB
#
# cluster_instance_id — UUID кластера, генерируется сервером при Bootstrap
# (proto: cluster/init/v1/init_service.proto, GlobalConfig.cluster_instance_id).
# Клиент его не задаёт; _cluster_bootstrap читает его из BootstrapResponse и
# передаёт в _join_node как обязательное поле JoinRequest.cluster_instance_id.
# =============================================================================

# ---------------------------------------------------------------------------
# build_local_config <node_id> <raft_ip> <hc_addr> [log_level]
#   Строит LocalConfig — общую "local"-часть BootstrapRequest/JoinRequest.
# ---------------------------------------------------------------------------
build_local_config() {
    local node_id="$1"
    local raft_ip="$2"
    local hc_addr="$3"
    local log_level="${4:-debug}"

    jq -n \
        --argjson node_id "$node_id" \
        --arg raft_ip "$raft_ip" \
        --arg hc_addr "$hc_addr" \
        --arg log_level "$log_level" \
        --argjson raft_port "$RAFT_PORT" \
        --argjson api_port "$CLUSTER_API_PORT" \
        '{
            "nodeId": $node_id,
            "raftIp": $raft_ip,
            "raftPort": $raft_port,
            "apiHost": "0.0.0.0",
            "apiPort": $api_port,
            "tlsDisabled": true,
            "hcAddress": $hc_addr,
            "logger": {"level": $log_level}
        }'
}

# ---------------------------------------------------------------------------
# build_global_config [raft_overrides_json]
#   Строит GlobalConfig со стандартными (известно-валидными) значениями всех
#   полей — единственное место, где эти значения заданы (устраняет дублирование
#   одного и того же bootstrap-конфига в 6+ местах, см. docs/test-review-2026-04-16.md L-3).
#   raft_overrides_json (опционально) — jq-объект, точечно замещающий поля внутри
#   .raft (например '{"electionTick": 50}'); остальные разделы GlobalConfig не
#   параметризуются, так как ни один тест их пока не переопределяет.
# ---------------------------------------------------------------------------
build_global_config() {
    local raft_overrides="${1:-{\}}"

    jq -n \
        --arg storage_hb "$STORAGE_HB" \
        --argjson hc_port "$HC_PORT" \
        --argjson raft_overrides "$raft_overrides" \
        '{
            "raft": ({"proposeTimeout": "0.500s", "transportTimeout": "1s", "electionTick": 15} * $raft_overrides),
            "hostMonitor": {
                "checkInterval": "1s",
                "missedHeartbeats": 3,
                "hcPort": $hc_port,
                "pingTimeout": "0.500s",
                "selfFencingTimeout": "15s",
                "stopVmsTimeout": "3s",
                "fenceTimeout": "30.500s",
                "storageFencingGracePeriod": "25s",
                "clusterWideStorageFailureTimeout": "60s"
            },
            "storageHeartbeat": {
                "basePath": $storage_hb,
                "leaderHeartbeatInterval": "1s",
                "vmStatusInterval": "5s",
                "staleLeaderTimeout": "5s",
                "staleVmStatusTimeout": "15s"
            },
            "taskManager": {
                "maxTasks": 1000,
                "cleanupInterval": "60s",
                "tasksCheckInterval": "5s"
            },
            "selfDiagnostics": {
                "checkInterval": "5s"
            }
        }'
}

# ---------------------------------------------------------------------------
# _cluster_bootstrap
#   1. Инициализировать node01
#   2. Подключить node02
#   3. Подключить node03
#   4. Проверить кворум из 3 голосующих узлов
#   5. Передать лидерство node01 при необходимости
# ---------------------------------------------------------------------------
_cluster_bootstrap() {
    log_step "Bootstrap started"

    # --- Шаг 1: Инициализация node01 ---
    log_step "Bootstrapping node01..."
    local bootstrap_config
    bootstrap_config=$(jq -n \
        --argjson local "$(build_local_config 1 "$NODE01_RAFT_IP" "$NODE01_HC" "info")" \
        --argjson global "$(build_global_config)" \
        '{"local": $local, "global": $global}')

    local bootstrap_resp
    local bootstrap_exit=0
    bootstrap_resp=$(grpcurl -plaintext \
        -import-path "$PROTO_ROOT" \
        -proto "${PROTO_ROOT}/cluster/init/v1/init_service.proto" \
        -d "$bootstrap_config" \
        "$CLUSTER_API_NODE01" \
        cluster.init.v1.InitService.Bootstrap 2>&1) || bootstrap_exit=$?

    if [[ $bootstrap_exit -ne 0 ]]; then
        log_error "Bootstrap failed (exit=$bootstrap_exit): $bootstrap_resp"
        return 1
    fi
    if [[ -z "$bootstrap_resp" ]]; then
        log_error "Bootstrap failed: empty response from $CLUSTER_API_NODE01"
        return 1
    fi
    if ! echo "$bootstrap_resp" | jq empty 2>/dev/null; then
        log_error "Bootstrap failed: non-JSON response: $bootstrap_resp"
        return 1
    fi

    local node_id
    node_id=$(echo "$bootstrap_resp" | jq -r '.nodeId' 2>/dev/null)
    if [[ "$node_id" != "1" ]]; then
        log_error "Bootstrap returned nodeId=$node_id (expected 1): $bootstrap_resp"
        return 1
    fi

    # cluster_instance_id генерируется сервером и обязателен для Join (см. заголовок файла)
    _BOOTSTRAP_CLUSTER_INSTANCE_ID=$(echo "$bootstrap_resp" | jq -r '.clusterInstanceId // empty' 2>/dev/null)
    if [[ -z "$_BOOTSTRAP_CLUSTER_INSTANCE_ID" ]]; then
        log_error "Bootstrap response missing clusterInstanceId: $bootstrap_resp"
        return 1
    fi
    log_info "Bootstrap OK -- nodeId=$node_id, clusterInstanceId=$_BOOTSTRAP_CLUSTER_INSTANCE_ID"

    wait_for_node_state "$CLUSTER_API_NODE01" "NODE_STATE_RUNNING" 30 2 || return 1

    # --- Шаг 2: Подключение node02 ---
    log_step "Joining node02..."
    _join_node 2 "$NODE02_RAFT_IP" "$NODE02_HC" "$_BOOTSTRAP_CLUSTER_INSTANCE_ID" || return 1
    log_info "Node02 joined OK"

    # --- Шаг 3: Подключение node03 ---
    log_step "Joining node03..."
    _join_node 3 "$NODE03_RAFT_IP" "$NODE03_HC" "$_BOOTSTRAP_CLUSTER_INSTANCE_ID" || return 1
    log_info "Node03 joined OK"

    # --- Шаг 4: Проверка кворума ---
    sleep 5
    local peers_resp voter_count
    peers_resp=$(grpcurl -plaintext \
        -import-path "$PROTO_ROOT" \
        -proto "${PROTO_ROOT}/cluster/nodes/v1/nodes_service.proto" \
        -d '{}' \
        "$CLUSTER_API_NODE01" \
        cluster.nodes.v1.NodesService.ListPeers 2>/dev/null)
    voter_count=$(echo "$peers_resp" | jq '.peers | length' 2>/dev/null)
    log_info "Cluster voters: $voter_count"

    if [[ "$voter_count" -lt 3 ]]; then
        log_warn "Expected 3 voters, got $voter_count -- waiting..."
        sleep 10
        peers_resp=$(grpcurl -plaintext \
            -import-path "$PROTO_ROOT" \
            -proto "${PROTO_ROOT}/cluster/nodes/v1/nodes_service.proto" \
            -d '{}' \
            "$CLUSTER_API_NODE01" \
            cluster.nodes.v1.NodesService.ListPeers 2>/dev/null)
        voter_count=$(echo "$peers_resp" | jq '.peers | length' 2>/dev/null)
        log_info "Cluster voters after wait: $voter_count"
    fi

    # --- Шаг 5: Обеспечение лидерства на node01 ---
    local leader_id
    leader_id=$(get_leader_node_id "$CLUSTER_API_NODE01") || true
    if [[ "$leader_id" != "1" && -n "$leader_id" ]]; then
        log_info "Transferring leadership to node01 (current leader: $leader_id)"
        local leader_target
        leader_target=$(get_target_for_node "$leader_id") || true
        if [[ -n "$leader_target" ]]; then
            grpcurl -plaintext \
                -import-path "$PROTO_ROOT" \
                -proto "${PROTO_ROOT}/cluster/nodes/v1/nodes_service.proto" \
                -d '{"targetNodeId": 1}' \
                "$leader_target" \
                cluster.nodes.v1.NodesService.TransferLeadership 2>/dev/null || true
            wait_for_leader_node_id 1 30 2 || log_warn "Leader did not return to node01"
        fi
    fi

    log_info "Bootstrap complete -- 3-node cluster is operational"
}

# ---------------------------------------------------------------------------
# _join_node <node_id> <raft_ip> <hc_addr> <cluster_instance_id> — подключает узел к кластеру
# ---------------------------------------------------------------------------
_join_node() {
    local node_id="$1"
    local raft_ip="$2"
    local hc_addr="$3"
    local cluster_instance_id="$4"

    local target
    target=$(get_target_for_node "$node_id") || return 1

    local join_config
    join_config=$(jq -n \
        --argjson local "$(build_local_config "$node_id" "$raft_ip" "$hc_addr" "info")" \
        --arg cluster_instance_id "$cluster_instance_id" \
        --arg leader_addr "${NODE01_RAFT_IP}:${RAFT_PORT}" \
        '{
            "local": $local,
            "leaderAddress": $leader_addr,
            "clusterInstanceId": $cluster_instance_id
        }')

    local join_resp
    local join_exit=0
    join_resp=$(grpcurl -plaintext \
        -import-path "$PROTO_ROOT" \
        -proto "${PROTO_ROOT}/cluster/init/v1/init_service.proto" \
        -d "$join_config" \
        "$target" \
        cluster.init.v1.InitService.Join 2>&1) || join_exit=$?

    if [[ $join_exit -ne 0 ]]; then
        log_error "Join failed for node $node_id ($target): $join_resp"
        return 1
    fi

    wait_for_node_state "$target" "NODE_STATE_RUNNING" 30 3 || return 1
}
