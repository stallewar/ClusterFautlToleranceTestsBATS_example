#!/usr/bin/env bash
# =============================================================================
# Глобальный setup/teardown для функциональных тестов API
#
# Жизненный цикл:
#   setup_file  — один раз перед всеми тестами: проверка предварительных условий
#   setup       — перед каждым тестом: полный сброс кластера + начальная загрузка (чистое состояние)
#   teardown    — после каждого теста: только логирование (состояние кластера сохраняется)
#   teardown_file — один раз после всех тестов: логирование итогового состояния кластера
# =============================================================================

# Загрузка конфигурации окружения
_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_setup_dir}/.env" ]]; then
    source "${_setup_dir}/.env"
fi

# Конфигурация кластера (значения берутся из .env; запасные значения для безопасности)
NODE01_RAFT_IP="${NODE01_RAFT_IP:-xxx.xxx.xxx.11}"
NODE02_RAFT_IP="${NODE02_RAFT_IP:-xxx.xxx.xxx.12}"
NODE03_RAFT_IP="${NODE03_RAFT_IP:-xxx.xxx.xxx.13}"
NODE01_HC="${NODE01_HC:-xxx.xxx.xxx.11}"
NODE02_HC="${NODE02_HC:-xxx.xxx.xxx.12}"
NODE03_HC="${NODE03_HC:-xxx.xxx.xxx.13}"
RAFT_PORT="${RAFT_PORT:-16330}"
API_PORT="${API_PORT:-16331}"
HC_PORT="${HC_PORT:-16321}"
STORAGE_HB="${STORAGE_HB:-/mnt/storage-system/sharedfs.XXXXXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXXXX}"
PROTO_ROOT="${PROTO_ROOT:-../proto-repo}"
export PROTO_ROOT
# Целевые адреса SSH-туннелей (LocalForward в ~/.ssh/config: 1733x → xxx.xxx.xxx.1x:16331)
API_NODE01="${API_NODE01:-localhost:17331}"
API_NODE02="${API_NODE02:-localhost:17332}"
API_NODE03="${API_NODE03:-localhost:17333}"
CLUSTER_API_NODE01="${CLUSTER_API_NODE01:-localhost:17331}"
CLUSTER_API_NODE02="${CLUSTER_API_NODE02:-localhost:17332}"
CLUSTER_API_NODE03="${CLUSTER_API_NODE03:-localhost:17333}"

# Подключение вспомогательных модулей
source "${_setup_dir}/helpers/grpc_helpers.bash"
source "${_setup_dir}/helpers/validators.bash"
source "${_setup_dir}/helpers/cluster_reset.bash"
source "${_setup_dir}/helpers/cluster_bootstrap.bash"

# ---------------------------------------------------------------------------
# setup_file -- выполняется один раз перед всеми тестами набора
# ---------------------------------------------------------------------------
setup_file() {
    log_file_suite_start
    _check_prerequisites || {
        log_error "Prerequisites check failed"
        return 1
    }
    log_info "SETUP_FILE: prerequisites OK"
}

# ---------------------------------------------------------------------------
# teardown_file -- выполняется один раз после всех тестов набора
# ---------------------------------------------------------------------------
teardown_file() {
    log_info "=== TEARDOWN_FILE: final cluster state ==="
    _log_cluster_state
    log_file_suite_end
    _generate_suite_report
}

# ---------------------------------------------------------------------------
# setup -- выполняется перед каждым тестом: сброс кластера в чистое состояние, затем начальная загрузка
# ---------------------------------------------------------------------------
setup() {
    log_test_start
    _cluster_reset || {
        log_error "Cluster reset failed"
        return 1
    }
    _cluster_bootstrap || {
        log_error "Cluster bootstrap failed"
        return 1
    }
}

# ---------------------------------------------------------------------------
# teardown -- выполняется после каждого теста: только логирование + отслеживание успеха/провала
# ---------------------------------------------------------------------------
teardown() {
    log_test_end
    # Очистка по возможности — ошибки подавляются; авторитетный сброс выполняется через _cluster_reset в следующем setup()
    stop_all_test_vms 2>/dev/null || true
    disable_upgrade_if_enabled 2>/dev/null || true
    if [[ -n "${BATS_FILE_TMPDIR:-}" ]]; then
        # BATS_TEST_STATUS не существует в bats-core (проверено на 1.13.0, исходники
        # /usr/lib/bats-core/*.bash) — "${BATS_TEST_STATUS:-0}" всегда давало 0,
        # поэтому ветка ниже с провалившимися тестами была недостижима и отчёт
        # всегда показывал PASS даже при реальных падениях.
        # Корректный сигнал: BATS_TEST_SKIPPED устанавливается skip() (bats >= 1.7);
        # BATS_TEST_COMPLETED устанавливается bats-exec-test только когда тело теста
        # (или skip) завершилось без ошибки — иначе teardown() вызывается через EXIT
        # trap и переменная остаётся пустой (подтверждено прогоном на bats 1.13.0).
        if [[ -n "${BATS_TEST_SKIPPED:-}" ]]; then
            echo "${BATS_TEST_DESCRIPTION}" >>"${BATS_FILE_TMPDIR}/tests_skipped"
        elif [[ -n "${BATS_TEST_COMPLETED:-}" ]]; then
            echo "${BATS_TEST_DESCRIPTION}" >>"${BATS_FILE_TMPDIR}/tests_passed"
        else
            # Фиксация состояния кластера в момент сбоя для анализа первопричины
            log_info "=== CLUSTER STATE AT FAILURE ==="
            _log_cluster_state
            echo "${BATS_TEST_DESCRIPTION}" >>"${BATS_FILE_TMPDIR}/tests_failed"
        fi
    fi
}

# ===========================================================================
# Внутренние вспомогательные функции
# ===========================================================================

_check_prerequisites() {
    local missing=0
    if ! command -v grpcurl &>/dev/null; then
        log_error "grpcurl is not installed"
        missing=1
    fi
    if ! command -v jq &>/dev/null; then
        log_error "jq is not installed"
        missing=1
    fi
    [[ $missing -eq 0 ]]
}

_generate_suite_report() {
    [[ -n "${BATS_FILE_TMPDIR:-}" ]] || return 0

    local reports_dir="${_setup_dir}/reports"
    mkdir -p "$reports_dir" 2>/dev/null || return 0

    local suite_name
    suite_name="$(basename "${BATS_TEST_FILENAME:-unknown}" .bats)"
    local report_file="${reports_dir}/test-run-${suite_name}-$(date +%Y%m%d_%H%M%S).md"

    local pass_count=0 fail_count=0 skip_count=0
    [[ -f "${BATS_FILE_TMPDIR}/tests_passed" ]] && pass_count=$(wc -l <"${BATS_FILE_TMPDIR}/tests_passed")
    [[ -f "${BATS_FILE_TMPDIR}/tests_failed" ]] && fail_count=$(wc -l <"${BATS_FILE_TMPDIR}/tests_failed")
    [[ -f "${BATS_FILE_TMPDIR}/tests_skipped" ]] && skip_count=$(wc -l <"${BATS_FILE_TMPDIR}/tests_skipped")
    local total=$((pass_count + fail_count + skip_count))

    {
        echo "# Test Run: ${suite_name}"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Log: ${_API_LOG_FILE:-N/A}"
        echo ""
        echo "## Summary"
        echo "| Result | Count |"
        echo "|--------|-------|"
        echo "| PASS   | $pass_count |"
        echo "| FAIL   | $fail_count |"
        echo "| SKIP   | $skip_count |"
        echo "| TOTAL  | $total |"
        if [[ -f "${BATS_FILE_TMPDIR}/tests_failed" ]]; then
            echo ""
            echo "## Failed Tests"
            while IFS= read -r line; do
                echo "- $line"
            done <"${BATS_FILE_TMPDIR}/tests_failed"
        fi
        if [[ -f "${BATS_FILE_TMPDIR}/tests_skipped" ]]; then
            echo ""
            echo "## Skipped Tests"
            while IFS= read -r line; do
                echo "- $line"
            done <"${BATS_FILE_TMPDIR}/tests_skipped"
        fi
        # В отчёт включаются только строки ERROR/WARN из лога, чтобы не раздувать его объём;
        # полный лог доступен по указанному выше пути.
        if [[ -n "${_API_LOG_FILE:-}" && -f "$_API_LOG_FILE" ]]; then
            local error_lines
            error_lines=$(grep -E '\[(ERROR|WARN)\]' "$_API_LOG_FILE" 2>/dev/null || true)
            if [[ -n "$error_lines" ]]; then
                echo ""
                echo "## Errors / Warnings"
                echo '```'
                echo "$error_lines"
                echo '```'
            fi
        fi
    } >"$report_file"

    { echo "Report: $report_file"; } >&3 2>/dev/null || echo "Report: $report_file" >&2
}

_log_cluster_state() {
    for target_name_target in "node01:$API_NODE01" "node02:$API_NODE02" "node03:$API_NODE03"; do
        local name="${target_name_target%%:*}"
        local target="${target_name_target#*:}"
        local response
        response=$(grpcurl -plaintext \
            -import-path "$PROTO_ROOT" \
            -proto "${PROTO_ROOT}/cluster/init/v1/init_service.proto" \
            -d '{}' \
            "$target" \
            cluster.init.v1.InitService.GetStatus 2>/dev/null) || response="unreachable"
        if [[ "$response" != "unreachable" ]] && echo "$response" | jq empty 2>/dev/null; then
            local state node_id cluster_instance_id
            state=$(echo "$response" | jq -r '.state // "?"' 2>/dev/null)
            node_id=$(echo "$response" | jq -r '.nodeId // "?"' 2>/dev/null)
            cluster_instance_id=$(echo "$response" | jq -r '.clusterInstanceId // "?"' 2>/dev/null)
            log_info "  $name: state=$state, nodeId=$node_id, cluster=$cluster_instance_id"
        else
            log_info "  $name: UNREACHABLE"
        fi
    done
}
