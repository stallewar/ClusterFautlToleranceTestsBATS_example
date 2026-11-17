#!/usr/bin/env bash
# =============================================================================
# gRPC-вспомогательные функции для функциональных тестов CLUSTER_API
# Обёртка над grpcurl: разрешение proto-файлов, маршрутизация через SSH-туннели, логирование
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/logging.bash"

# ---------------------------------------------------------------------------
# CLUSTER_API_NODE01/02/03 и PROTO_ROOT определены в setup_file.bash (единственный
# источник истины). Этот файл использует их; повторная декларация здесь отсутствует.
# ---------------------------------------------------------------------------
# _grpc_exec <method> <target> <request_json> <proto_file>
#   Внутренняя функция: выполняет вызов grpcurl с указанным proto-файлом
#   Вывод: JSON-ответ в stdout
#   Возвращает: 0 при успехе, ненулевое значение при ошибке gRPC
# ---------------------------------------------------------------------------
_grpc_exec() {
    local method="$1"
    local target="$2"
    local request_json="${3:-{\}}"  # без экранирования "'{}'" стал бы буквальными кавычками в JSON
    local proto_file="$4"

    grpcurl -plaintext \
        -import-path "$PROTO_ROOT" \
        -proto "${PROTO_ROOT}/${proto_file}" \
        -d "$request_json" \
        "$target" \
        "$method" 2>&1
}

# ---------------------------------------------------------------------------
# grpc_call <service> <method> <target> <request_json>
#   Высокоуровневый gRPC-вызов с автоматическим разрешением proto и логированием
#   Выводит: JSON-ответ при успехе, сообщение об ошибке при сбое
#   Возвращает: 0 при успехе, 1 при сбое
# ---------------------------------------------------------------------------
grpc_call() {
    local service="$1" # например: cluster.init.v1.InitService
    local method="$2"  # например: GetStatus
    local target="$3"  # например: localhost:17331
    local request_json="${4:-'{}'}"

    local full_method="${service}/${method}"
    local proto_file
    proto_file="$(_resolve_proto "$service")"

    if [[ -z "$proto_file" ]]; then
        log_error "Cannot resolve proto for service: $service" >&2
        return 1
    fi

    log_step "Calling ${full_method} on ${target}" >&2
    log_req "$request_json" >&2

    local response
    local exit_code=0
    response=$(_grpc_exec "$full_method" "$target" "$request_json" "$proto_file") || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "gRPC call failed (exit=$exit_code): $response" >&2
        echo "$response"
        return 1
    fi

    log_resp "$response" >&2
    echo "$response"
    return 0
}

# ---------------------------------------------------------------------------
# _resolve_proto <service>
#   Отображает имя gRPC-сервиса на путь к его .proto-файлу (относительно PROTO_ROOT)
# ---------------------------------------------------------------------------
_resolve_proto() {
    local service="$1"
    case "$service" in
    cluster.init.v1.InitService)
        echo "cluster/init/v1/init_service.proto"
        ;;
    cluster.nodes.v1.NodesService)
        echo "cluster/nodes/v1/nodes_service.proto"
        ;;
    cluster.virt.v1.VirtService)
        echo "cluster/virt/v1/virt_service.proto"
        ;;
    cluster.task.v1.TaskService)
        echo "cluster/task/v1/task_service.proto"
        ;;
    cluster.upgrade.v1.UpgradeService)
        echo "cluster/upgrade/v1/upgrade_service.proto"
        ;;
    *)
        log_error "Unknown service: $service"
        return 1
        ;;
    esac
}

# ===========================================================================
# Удобные обёртки по сервисам
# ===========================================================================

# --- InitService ---

grpc_get_status() {
    local target="${1:-$CLUSTER_API_NODE01}"
    grpc_call "cluster.init.v1.InitService" "GetStatus" "$target" '{}'
}

grpc_bootstrap() {
    local target="$1"
    local request_json="$2"
    grpc_call "cluster.init.v1.InitService" "Bootstrap" "$target" "$request_json"
}

grpc_join() {
    local target="$1"
    local request_json="$2"
    grpc_call "cluster.init.v1.InitService" "Join" "$target" "$request_json"
}

grpc_reset() {
    local target="$1"
    local force="${2:-false}"
    grpc_call "cluster.init.v1.InitService" "Reset" "$target" "{\"force\": ${force}}"
}

grpc_get_global_config() {
    local target="${1:-$CLUSTER_API_NODE01}"
    grpc_call "cluster.init.v1.InitService" "GetGlobalConfig" "$target" '{}'
}

grpc_update_global_config() {
    local target="$1"
    local request_json="$2"
    grpc_call "cluster.init.v1.InitService" "UpdateGlobalConfig" "$target" "$request_json"
}

# ---------------------------------------------------------------------------
# grpc_update_global_config_field <target> <jq_path> <jq_value_expr>
#   UpdateGlobalConfig ЗАМЕНЯЕТ весь GlobalConfig, а не мёржит его частично
#   (подтверждено живым прогоном 2026-08-10: partial-payload вызов ловит
#   "storageheartbeat: BasePath cannot be empty", т.к. немерженные поля
#   становятся proto3-дефолтами/пустыми). Эта обёртка сначала читает текущий
#   полный конфиг через GetGlobalConfig, точечно правит его через jq и
#   отправляет обратно ПОЛНОСТЬЮ — единственный безопасный способ поменять
#   одно поле GlobalConfig.
#   <jq_value_expr> — jq-выражение ПРАВОЙ части присваивания (не строка со значением),
#   например: grpc_update_global_config_field "$t" '.global.taskManager.maxTasks' '5'
# ---------------------------------------------------------------------------
grpc_update_global_config_field() {
    local target="$1"
    local jq_path="$2"
    local jq_value_expr="$3"

    local current
    current=$(grpc_get_global_config "$target" 2>/dev/null) || return 1
    echo "$current" | jq empty 2>/dev/null || return 1

    local updated
    updated=$(echo "$current" | jq "${jq_path} = ${jq_value_expr}") || return 1

    grpc_update_global_config "$target" "$updated"
}

# ---------------------------------------------------------------------------
# wait_for_global_config_field <target> <jq_path> <expected_value> <max_retries> <interval>
#   Опрашивает GetGlobalConfig до появления ожидаемого значения вместо
#   фиксированного sleep (см. docs/test-review-2026-04-16.md L-5).
#   <jq_path> — относительно .global, например 'taskManager.maxTasks'.
# ---------------------------------------------------------------------------
wait_for_global_config_field() {
    local target="$1"
    local jq_path="$2"
    local expected_value="$3"
    local max_retries="${4:-10}"
    local interval="${5:-1}"

    local i=0
    while [[ $i -lt $max_retries ]]; do
        local actual
        actual=$(grpc_get_global_config "$target" 2>/dev/null | jq -r ".global.${jq_path}" 2>/dev/null)
        if [[ "$actual" == "$expected_value" ]]; then
            log_step "GlobalConfig.$jq_path reached $expected_value after $((i * interval))s"
            return 0
        fi
        sleep "$interval"
        i=$((i + 1))
    done

    log_error "GlobalConfig.$jq_path did not reach $expected_value within $((max_retries * interval))s (last: $actual)"
    return 1
}

# --- NodesService ---

grpc_get_leader() {
    local target="${1:-$CLUSTER_API_NODE01}"
    grpc_call "cluster.nodes.v1.NodesService" "GetLeader" "$target" '{}'
}

grpc_list_peers() {
    local target="${1:-$CLUSTER_API_NODE01}"
    grpc_call "cluster.nodes.v1.NodesService" "ListPeers" "$target" '{}'
}

grpc_transfer_leadership() {
    local target="$1"
    local target_node_id="$2"
    grpc_call "cluster.nodes.v1.NodesService" "TransferLeadership" "$target" "{\"targetNodeId\": ${target_node_id}}"
}

grpc_add_node() {
    local target="$1"
    local node_id="$2"
    local node_address="$3"
    grpc_call "cluster.nodes.v1.NodesService" "AddNode" "$target" \
        "{\"nodeId\": ${node_id}, \"nodeAddress\": \"${node_address}\"}"
}

grpc_remove_node() {
    local target="$1"
    local node_id="$2"
    grpc_call "cluster.nodes.v1.NodesService" "RemoveNode" "$target" \
        "{\"nodeId\": ${node_id}}"
}

# --- VirtService ---

grpc_list_vms() {
    local target="${1:-$CLUSTER_API_NODE01}"
    grpc_call "cluster.virt.v1.VirtService" "ListVms" "$target" '{}'
}

_grpc_exec_virt() {
    local method="$1"
    local target="$2"
    local request_json="${3:-{\}}"  # без экранирования "'{}'" стал бы буквальными кавычками в JSON

    grpcurl -plaintext \
        -import-path "$PROTO_ROOT" \
        -proto "${PROTO_ROOT}/cluster/virt/v1/virt_service.proto" \
        -proto "${PROTO_ROOT}/services/virt/v2/virt_service.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/task_id.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/vm_id.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/image.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/vm_state_store.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/virt_agent.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/disk_id.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/storage_id.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/net_id.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/ovs.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/image_id.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/image_format.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/secure.proto" \
        -proto "${PROTO_ROOT}/services/common/v1/token.proto" \
        -d "$request_json" \
        "$target" \
        "$method" 2>&1
}

grpc_start_vm() {
    local target="$1"
    local request_json="$2"
    local full_method="cluster.virt.v1.VirtService/StartVm"

    log_step "Calling ${full_method} on ${target}" >&2
    log_req "$request_json" >&2

    local response
    local exit_code=0
    response=$(_grpc_exec_virt "$full_method" "$target" "$request_json") || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "gRPC call failed (exit=$exit_code): $response" >&2
        echo "$response"
        return 1
    fi

    log_resp "$response" >&2
    echo "$response"
    return 0
}

grpc_stop_vm() {
    local target="$1"
    local request_json="$2"
    local full_method="cluster.virt.v1.VirtService/StopVm"

    log_step "Calling ${full_method} on ${target}" >&2
    log_req "$request_json" >&2

    local response
    local exit_code=0
    response=$(_grpc_exec_virt "$full_method" "$target" "$request_json") || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "gRPC call failed (exit=$exit_code): $response" >&2
        echo "$response"
        return 1
    fi

    log_resp "$response" >&2
    echo "$response"
    return 0
}

# --- TaskService ---

grpc_get_tasks() {
    local target="${1:-$CLUSTER_API_NODE01}"
    local since="${2:-0}"
    grpc_call "cluster.task.v1.TaskService" "GetTasks" "$target" "{\"since\": ${since}}"
}

# --- UpgradeService ---

grpc_get_upgrade_status() {
    local target="${1:-$CLUSTER_API_NODE01}"
    grpc_call "cluster.upgrade.v1.UpgradeService" "GetUpgradeStatus" "$target" '{}'
}

grpc_enable_upgrade_mode() {
    local target="$1"
    local reason="${2:-functional-test}"
    grpc_call "cluster.upgrade.v1.UpgradeService" "EnableUpgradeMode" "$target" "{\"reason\": \"${reason}\"}"
}

grpc_disable_upgrade_mode() {
    local target="${1:-$CLUSTER_API_NODE01}"
    grpc_call "cluster.upgrade.v1.UpgradeService" "DisableUpgradeMode" "$target" '{}'
}

# ===========================================================================
# Вспомогательные функции для состояния кластера
# ===========================================================================

# ---------------------------------------------------------------------------
# get_node_state <target>
#   Возвращает строку NodeState (например, NODE_STATE_RUNNING) или пустую строку при ошибке
#   Вызывает grpcurl напрямую, чтобы не засорять вывод лога
# ---------------------------------------------------------------------------
get_node_state() {
    local target="$1"
    local response
    response=$(grpcurl -plaintext \
        -import-path "$PROTO_ROOT" \
        -proto "${PROTO_ROOT}/cluster/init/v1/init_service.proto" \
        -d '{}' \
        "$target" \
        cluster.init.v1.InitService.GetStatus 2>/dev/null) || return 1
    echo "$response" | jq -r '.state // empty' 2>/dev/null
}

# ---------------------------------------------------------------------------
# ensure_node_uninitialized <target>
#   Проверяет, что целевой узел находится в состоянии NODE_STATE_UNINITIALIZED.
#
#   setup() пересобирает кластер (bootstrap + join всех узлов) перед КАЖДЫМ
#   тестом, поэтому это предусловие не может быть получено побочным эффектом
#   другого теста в сьюте — вызывающий тест должен сам сделать reset/wait для
#   нужной ноды непосредственно перед вызовом (см. I-2, I-7, I-9) и обрабатывать
#   отказ через `|| return 1`: если условие не выполнилось после собственного
#   reset/wait теста, это реальный сбой инфраструктуры, а не отсутствующее
#   предусловие.
# ---------------------------------------------------------------------------
ensure_node_uninitialized() {
    local target="$1"
    local state
    state=$(get_node_state "$target") || {
        log_error "Cannot get status of $target"
        return 1
    }
    if [[ "$state" != "NODE_STATE_UNINITIALIZED" ]]; then
        log_error "Node $target is not uninitialized (state=$state)"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# wait_for_node_state <target> <expected_state> <max_retries> <interval>
#   Опрашивает GetStatus до достижения узлом ожидаемого состояния или таймаута.
# ---------------------------------------------------------------------------
wait_for_node_state() {
    local target="$1"
    local expected_state="$2"
    local max_retries="${3:-30}"
    local interval="${4:-2}"

    local i=0
    while [[ $i -lt $max_retries ]]; do
        local state
        state=$(get_node_state "$target") || true
        if [[ "$state" == "$expected_state" ]]; then
            log_step "Node $target reached state $expected_state after $((i * interval))s"
            return 0
        fi
        log_step "Node $target state=$state (want $expected_state, attempt $((i + 1))/$max_retries), waiting ${interval}s..."
        sleep "$interval"
        i=$((i + 1))
    done

    log_error "Node $target did not reach state $expected_state within $((max_retries * interval))s (last state: $state)"
    return 1
}

# ---------------------------------------------------------------------------
# get_leader_node_id
#   Возвращает node_id текущего лидера кластера или пустую строку при ошибке
#   Вызывает grpcurl напрямую, чтобы не засорять вывод лога
# ---------------------------------------------------------------------------
get_leader_node_id() {
    local target="${1:-$CLUSTER_API_NODE01}"
    local response
    response=$(grpcurl -plaintext \
        -import-path "$PROTO_ROOT" \
        -proto "${PROTO_ROOT}/cluster/nodes/v1/nodes_service.proto" \
        -d '{}' \
        "$target" \
        cluster.nodes.v1.NodesService.GetLeader 2>/dev/null) || return 1
    echo "$response" | jq -r '.nodeId // empty' 2>/dev/null
}

# ---------------------------------------------------------------------------
# wait_for_leader_node_id <expected_id> <max_retries> <interval>
#   Опрашивает GetLeader до тех пор, пока лидер не совпадёт с expected_id
# ---------------------------------------------------------------------------
wait_for_leader_node_id() {
    local expected_id="$1"
    local max_retries="${2:-30}"
    local interval="${3:-2}"

    local i=0
    while [[ $i -lt $max_retries ]]; do
        local leader_id
        leader_id=$(get_leader_node_id) || true
        if [[ "$leader_id" == "$expected_id" ]]; then
            log_step "Leader is now node $expected_id after $((i * interval))s"
            return 0
        fi
        log_step "Leader=$leader_id (expected $expected_id), attempt $((i + 1))/$max_retries, waiting ${interval}s..."
        sleep "$interval"
        i=$((i + 1))
    done

    log_error "Leader did not become node $expected_id within $((max_retries * interval))s"
    return 1
}

# ---------------------------------------------------------------------------
# transfer_leadership_to <node_id>
#   Передаёт лидерство указанному узлу и ожидает подтверждения
# ---------------------------------------------------------------------------
transfer_leadership_to() {
    local node_id="$1"
    local leader_target
    leader_target=$(get_leader_target)

    log_step "Transferring leadership to node $node_id from $leader_target"
    grpc_transfer_leadership "$leader_target" "$node_id" || return 1
    wait_for_leader_node_id "$node_id" 30 2
}

# ---------------------------------------------------------------------------
# get_leader_target
#   Возвращает адрес SSH-туннеля (localhost:port) для текущего лидера кластера
# ---------------------------------------------------------------------------
get_leader_target() {
    local leader_id
    leader_id=$(get_leader_node_id) || return 1
    case "$leader_id" in
    1) echo "$CLUSTER_API_NODE01" ;;
    2) echo "$CLUSTER_API_NODE02" ;;
    3) echo "$CLUSTER_API_NODE03" ;;
    *)
        log_error "Unknown leader node_id: $leader_id"
        return 1
        ;;
    esac
}

# ---------------------------------------------------------------------------
# get_target_for_node <node_id>
#   Возвращает адрес SSH-туннеля для указанного node_id
# ---------------------------------------------------------------------------
get_target_for_node() {
    local node_id="$1"
    case "$node_id" in
    1) echo "$CLUSTER_API_NODE01" ;;
    2) echo "$CLUSTER_API_NODE02" ;;
    3) echo "$CLUSTER_API_NODE03" ;;
    *)
        log_error "Unknown node_id: $node_id"
        return 1
        ;;
    esac
}

# ===========================================================================
# Вспомогательные функции жизненного цикла VM
# ===========================================================================

# ---------------------------------------------------------------------------
# build_start_vm_request <vm_id> <task_id>
#   Формирует JSON StartVmRequest с обёрткой google.proto-repo.Any
#   Минимальная конфигурация: 1 vCPU, 512 МБ ОЗУ, сеть по умолчанию, без дисков
# ---------------------------------------------------------------------------
build_start_vm_request() {
    local vm_id="$1"
    local task_id="${2:-$vm_id}"

    cat <<EOF
{
  "request": {
    "@type": "type.googleapis.com/services.virt.v2.StartVmRequest",
    "taskId": {"id": "${task_id}"},
    "arg": {
      "id": {"id": "${vm_id}"},
      "eTemplate": "DEFAULT",
      "computingArg": {
        "limitMemoryKb": 524288,
        "guaranteedMemoryKb": 262144,
        "limitVcpuCount": 1,
        "guaranteedVcpuCount": 0.5
      },
      "networkAdapters": [
        {
          "defaultBridge": {"macAddress": ""},
          "model": "VIRTIO"
        }
      ],
      "serviceSettings": {
        "listenAddr": "0.0.0.0",
        "port": 10000,
        "password": "testpass123"
      },
      "cgroupName": "test",
      "enableBootMenu": false
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# build_stop_vm_request <vm_id> <task_id>
#   Формирует JSON StopVmRequest с обёрткой google.proto-repo.Any
# ---------------------------------------------------------------------------
build_stop_vm_request() {
    local vm_id="$1"
    local task_id="${2:-$vm_id}"
    local force_stop="${3:-false}"

    cat <<EOF
{
  "request": {
    "@type": "type.googleapis.com/services.virt.v2.StopVmRequest",
    "taskId": {"id": "${task_id}"},
    "arg": {
      "id": {"id": "${vm_id}"},
      "forceStop": ${force_stop}
    }
  }
}
EOF
}

# ---------------------------------------------------------------------------
# stop_all_test_vms
#   Останавливает все VM, идентификаторы которых начинаются с "test-", на кластере
# ---------------------------------------------------------------------------
stop_all_test_vms() {
    local target="${1:-$CLUSTER_API_NODE01}"
    local list_response
    list_response=$(grpc_list_vms "$target" 2>/dev/null) || return 0 # Если запрос списка не удался — останавливать нечего

    local vm_ids
    vm_ids=$(echo "$list_response" | jq -r '.vms[]?.id?.id // empty' 2>/dev/null) || return 0

    for vm_id in $vm_ids; do
        if [[ "$vm_id" == test-* ]]; then
            log_step "Stopping test VM: $vm_id"
            local stop_req
            stop_req=$(build_stop_vm_request "$vm_id" "cleanup-${vm_id}")
            grpc_stop_vm "$target" "$stop_req" 2>/dev/null || true
        fi
    done
}

# ---------------------------------------------------------------------------
# disable_upgrade_if_enabled <target>
#   Отключает режим обновления, если он в данный момент включён
# ---------------------------------------------------------------------------
disable_upgrade_if_enabled() {
    local target="${1:-$CLUSTER_API_NODE01}"
    local status_response
    status_response=$(grpc_get_upgrade_status "$target" 2>/dev/null) || return 0

    local upgrade_mode
    upgrade_mode=$(echo "$status_response" | jq -r '.upgradeMode // empty' 2>/dev/null) || return 0

    if [[ "$upgrade_mode" == "true" ]]; then
        log_step "Upgrade mode is enabled, disabling..."
        local leader_target
        leader_target=$(get_leader_target) || return 0
        grpc_disable_upgrade_mode "$leader_target" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# reset_leader_to_node01
#   Гарантирует, что лидером является node01. При необходимости выполняет передачу лидерства.
# ---------------------------------------------------------------------------
reset_leader_to_node01() {
    local leader_id
    leader_id=$(get_leader_node_id) || return 0

    if [[ "$leader_id" != "1" ]]; then
        log_step "Leader is node $leader_id, transferring to node01"
        local leader_target
        leader_target=$(get_leader_target) || return 0
        grpc_transfer_leadership "$leader_target" 1 2>/dev/null || true
        wait_for_leader_node_id 1 30 2 || true
    fi
}
