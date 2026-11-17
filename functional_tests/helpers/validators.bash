#!/usr/bin/env bash
# =============================================================================
# Вспомогательные функции валидации для функциональных тестов CLUSTER_API
# Все функции используют jq для анализа JSON-ответов и сообщают PASS/FAIL
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/logging.bash"

# ---------------------------------------------------------------------------
# validate_field_equals <json> <jq_path> <expected_value> <check_name>
#   Универсальный валидатор поля.
#   Возвращает 0 (PASS) если поле совпадает с ожидаемым, 1 (FAIL) иначе.
# ---------------------------------------------------------------------------
validate_field_equals() {
    local json="$1"
    local jq_path="$2"
    local expected="$3"
    local check_name="$4"

    local actual
    actual=$(echo "$json" | jq -r "$jq_path" 2>/dev/null)

    if [[ "$actual" == "$expected" ]]; then
        log_check "$check_name: '$actual' == '$expected'" "PASS"
        return 0
    else
        log_check "$check_name: '$actual' != '$expected'" "FAIL"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_field_not_empty <json> <jq_path> <check_name>
#   Проверяет, что поле существует и не является пустым/null.
# ---------------------------------------------------------------------------
validate_field_not_empty() {
    local json="$1"
    local jq_path="$2"
    local check_name="$3"

    local actual
    actual=$(echo "$json" | jq -r "$jq_path" 2>/dev/null)

    if [[ -n "$actual" && "$actual" != "null" ]]; then
        log_check "$check_name: '$actual' is not empty" "PASS"
        return 0
    else
        log_check "$check_name: field is empty or null" "FAIL"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_json_valid <json> <check_name>
#   Проверяет, что строка является корректным JSON.
# ---------------------------------------------------------------------------
validate_json_valid() {
    local json="$1"
    local check_name="$2"

    if echo "$json" | jq empty 2>/dev/null; then
        log_check "$check_name: valid JSON" "PASS"
        return 0
    else
        log_check "$check_name: invalid JSON" "FAIL"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_not_error <response> <check_name>
#   Проверяет, что ответ не содержит признаков ошибки gRPC.
# ---------------------------------------------------------------------------
validate_not_error() {
    local response="$1"
    local check_name="$2"

    if echo "$response" | grep -qi "error\|failed\|unable\|cannot"; then
        # Различаем ответ с ошибкой и ответ, в котором слово "error"
        # встречается в безошибочном контексте
        if echo "$response" | jq empty 2>/dev/null; then
            local error_field
            error_field=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
            if [[ -n "$error_field" ]]; then
                log_check "$check_name: response contains error: $error_field" "FAIL"
                return 1
            fi
        else
            # Не является корректным JSON и содержит ключевые слова ошибки — вероятно, ошибка grpcurl
            log_check "$check_name: response appears to be an error" "FAIL"
            return 1
        fi
    fi

    log_check "$check_name: no error in response" "PASS"
    return 0
}

# ===========================================================================
# Предметно-ориентированные валидаторы
# ===========================================================================

# ---------------------------------------------------------------------------
# validate_node_state <json> <expected_state>
#   Проверяет GetStatusResponse.state
# ---------------------------------------------------------------------------
validate_node_state() {
    local json="$1"
    local expected_state="$2"
    validate_field_equals "$json" '.state' "$expected_state" "NodeState is $expected_state"
}

# ---------------------------------------------------------------------------
# validate_node_id <json> <expected_id>
#   Проверяет GetStatusResponse.nodeId
# ---------------------------------------------------------------------------
validate_node_id() {
    local json="$1"
    local expected_id="$2"
    validate_field_equals "$json" '.nodeId' "$expected_id" "NodeId is $expected_id"
}

# ---------------------------------------------------------------------------
# validate_cluster_instance_id <json> <expected_id>
#   Проверяет GetStatusResponse.clusterInstanceId (UUID, генерируется сервером
#   при Bootstrap — proto: cluster/init/v1/init_service.proto)
# ---------------------------------------------------------------------------
validate_cluster_instance_id() {
    local json="$1"
    local expected_id="$2"
    validate_field_equals "$json" '.clusterInstanceId' "$expected_id" "ClusterInstanceId is $expected_id"
}

# ---------------------------------------------------------------------------
# validate_peer_alive <json> <expected_node_id>
#   Проверяет, что пир с указанным node_id имеет статус PEER_STATUS_ALIVE
# ---------------------------------------------------------------------------
validate_peer_alive() {
    local json="$1"
    local expected_node_id="$2"

    local status
    status=$(echo "$json" | jq -r \
        ".peers[] | select(.nodeId | tostring == \"$expected_node_id\") | .status" 2>/dev/null)

    if [[ "$status" == "PEER_STATUS_ALIVE" ]]; then
        log_check "Peer $expected_node_id status is PEER_STATUS_ALIVE" "PASS"
        return 0
    else
        log_check "Peer $expected_node_id status is '$status' (expected PEER_STATUS_ALIVE)" "FAIL"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_vm_status <json> <vm_id> <expected_status>
#   Проверяет, что ВМ с указанным ID имеет ожидаемый статус в ListVmsResponse
# ---------------------------------------------------------------------------
validate_vm_status() {
    local json="$1"
    local vm_id="$2"
    local expected_status="$3"

    local actual_status
    actual_status=$(echo "$json" | jq -r \
        ".vms[] | select(.id.id == \"$vm_id\") | .status" 2>/dev/null)

    if [[ "$actual_status" == "$expected_status" ]]; then
        log_check "VM $vm_id status is $expected_status" "PASS"
        return 0
    else
        log_check "VM $vm_id status is '$actual_status' (expected $expected_status)" "FAIL"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_task_exists <json> <task_type> <entity_id>
#   Проверяет, что задача с указанным типом и entity_id существует в GetTasksResponse
# ---------------------------------------------------------------------------
validate_task_exists() {
    local json="$1"
    local task_type="$2"
    local entity_id="$3"

    local found
    found=$(echo "$json" | jq \
        "[.tasks[] | select(.taskType == \"$task_type\" and .entityId == \"$entity_id\")] | length" 2>/dev/null)

    if [[ "$found" -gt 0 ]]; then
        log_check "Task found: type=$task_type, entity=$entity_id" "PASS"
        return 0
    else
        log_check "Task not found: type=$task_type, entity=$entity_id" "FAIL"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# validate_upgrade_mode <json> <expected_bool>
#   Проверяет GetUpgradeStatusResponse.upgradeMode
# ---------------------------------------------------------------------------
validate_upgrade_mode() {
    local json="$1"
    local expected_bool="$2"
    validate_field_equals "$json" '.upgradeMode' "$expected_bool" "UpgradeMode is $expected_bool"
}

# ---------------------------------------------------------------------------
# validate_global_config_field <json> <field_path> <expected_value>
#   Проверяет поле в GetGlobalConfigResponse.global
#   field_path задаётся относительно .global, например "hostMonitor.checkInterval"
# ---------------------------------------------------------------------------
validate_global_config_field() {
    local json="$1"
    local field_path="$2"
    local expected_value="$3"
    local check_name="GlobalConfig.$field_path"
    validate_field_equals "$json" ".global.${field_path}" "$expected_value" "$check_name"
}
