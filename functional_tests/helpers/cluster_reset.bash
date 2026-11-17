#!/usr/bin/env bash
# =============================================================================
# Вспомогательный модуль сброса кластера
# Сбрасывает все три узла в NODE_STATE_UNINITIALIZED через принудительный сброс.
#
# Зависит от: grpc_helpers.bash (get_target_for_node, get_node_state,
#             CLUSTER_API_NODE*, PROTO_ROOT), logging.bash
# =============================================================================

# ---------------------------------------------------------------------------
# _cluster_reset
#   Отправляет Reset{force:true} каждому узлу и ожидает, пока все достигнут
#   NODE_STATE_UNINITIALIZED.
# ---------------------------------------------------------------------------
_cluster_reset() {
    log_step "Resetting all nodes to UNINITIALIZED..."

    for target in "$CLUSTER_API_NODE01" "$CLUSTER_API_NODE02" "$CLUSTER_API_NODE03"; do
        log_step "  Resetting $target..."
        grpcurl -plaintext \
            -import-path "$PROTO_ROOT" \
            -proto "${PROTO_ROOT}/cluster/init/v1/init_service.proto" \
            -d '{"force": true}' \
            "$target" \
            cluster.init.v1.InitService.Reset 2>/dev/null || true
    done

    local i
    for i in 1 2 3; do
        local target
        target=$(get_target_for_node "$i") || return 1
        log_step "  Waiting for node$i to reach UNINITIALIZED..."
        wait_for_node_state "$target" "NODE_STATE_UNINITIALIZED" 15 2 || {
            log_error "Node $i did not reach UNINITIALIZED within 15s"
            return 1
        }
    done

    log_info "All nodes reset to UNINITIALIZED"
}
