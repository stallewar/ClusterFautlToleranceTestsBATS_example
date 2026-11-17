#!/usr/bin/env bash
# =============================================================================
# Вспомогательный модуль логирования для функциональных тестов CLUSTER_API
# Формат: [YYYY-MM-DDTHH:MM:SS] [TEST_NAME] LEVEL: message
#
# Вывод в реальном времени:
#   fd3 — канал реального времени BATS, обходит внутренний захват.
#   Откат на stderr при запуске вне BATS (прямое подключение через source).
#
# Запись в файл:
#   Автоматически инициализируется при первой записи для каждого набора.
#   Расположение: <functional_tests>/logs/<suite>_<timestamp>.log
#   Переопределение директории: CLUSTER_API_LOG_DIR=/path/to/dir
#
# Уровни детализации (установите LOG_LEVEL перед запуском тестов):
#   ERROR  WARN  INFO  STEP  CHECK  DEBUG  REQ  RESP
#   ────────────────────────────────────────────────▶ подробнее
#   По умолчанию: CHECK  (скрывает DEBUG, REQ, RESP)
#
#   Примеры:
#     LOG_LEVEL=STEP  ./run_tests.sh          # скрывает также CHECK
#     LOG_LEVEL=RESP  ./run_tests.sh nodes    # показывает всё
# =============================================================================

# ---------------------------------------------------------------------------
# Таблица уровней — индекс = приоритет (меньше = критичнее, всегда отображается)
# ---------------------------------------------------------------------------
declare -gA _CLUSTER_API_LEVEL_IDX=(
    [ERROR]=0
    [WARN]=1
    [INFO]=2
    [STEP]=3
    [CHECK]=4
    [DEBUG]=5
    [REQ]=6
    [RESP]=7
)

LOG_LEVEL="${LOG_LEVEL:-CHECK}"

_api_should_log() {
    local level="$1"
    local threshold="${_CLUSTER_API_LEVEL_IDX[$LOG_LEVEL]:-4}"
    local idx="${_CLUSTER_API_LEVEL_IDX[$level]:-999}"
    [[ "$idx" -le "$threshold" ]]
}

# ---------------------------------------------------------------------------
# Файл лога — автоматически инициализируется при первой записи, один файл на набор
# ---------------------------------------------------------------------------
_CLUSTER_API_LOG_FILE=""

_api_init_log_file() {
    [[ -n "$_CLUSTER_API_LOG_FILE" ]] && return 0

    # Переиспользуем путь, установленный setup_file (общий для всех дочерних процессов тестов)
    if [[ -n "${BATS_FILE_TMPDIR:-}" && -f "${BATS_FILE_TMPDIR}/api_log_path" ]]; then
        _CLUSTER_API_LOG_FILE="$(< "${BATS_FILE_TMPDIR}/api_log_path")"
        return 0
    fi

    local log_dir="${CLUSTER_API_LOG_DIR:-}"
    if [[ -z "$log_dir" ]]; then
        if [[ -n "$BATS_TEST_DIRNAME" ]]; then
            log_dir="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)/logs"
        else
            log_dir="$(pwd)/logs"
        fi
    fi

    mkdir -p "$log_dir" 2>/dev/null || return 1

    local suite_name
    if [[ -n "$BATS_TEST_FILENAME" ]]; then
        suite_name="$(basename "$BATS_TEST_FILENAME" .bats)"
    else
        suite_name="api"
    fi

    _CLUSTER_API_LOG_FILE="${log_dir}/${suite_name}_$(date +%Y%m%d_%H%M%S).log"
}

# ---------------------------------------------------------------------------
# _timestamp — возвращает текущую метку времени
# ---------------------------------------------------------------------------
_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S'
}

# ---------------------------------------------------------------------------
# _log_write <level> <message> — записывает строку лога
# ---------------------------------------------------------------------------
_log_write() {
    local level="$1"
    local message="$2"

    _api_should_log "$level" || return 0

    local ts
    ts="$(_timestamp)"
    local test_name="${BATS_TEST_DESCRIPTION:-GLOBAL}"
    local line="[${ts}] [${test_name}] ${level}: ${message}"

    # fd3 = вывод в реальном времени BATS (обходит внутренний захват → виден немедленно).
    # Откат на stderr, если fd3 недоступен (контекст вне BATS).
    { echo "$line" >&3; } 2>/dev/null || echo "$line" >&2

    # Файл — автоинициализация при первой записи, только дозапись
    _api_init_log_file && echo "$line" >>"$_CLUSTER_API_LOG_FILE"
}

# ---------------------------------------------------------------------------
# Публичный API
# ---------------------------------------------------------------------------
log_error() { _log_write "ERROR" "$*"; }
log_warn()  { _log_write "WARN"  "$*"; }
log_info()  { _log_write "INFO"  "$*"; }
log_step()  { _log_write "STEP"  "$*"; }
log_debug() { _log_write "DEBUG" "$*"; }
log_req()   { _log_write "REQ"   "$*"; }
log_resp()  { _log_write "RESP"  "$*"; }

log_check() {
    local description="$1"
    local result="$2"
    _log_write "CHECK" "${description} => ${result}"
}

# ---------------------------------------------------------------------------
# Жизненный цикл набора — сбрасывает файл лога, чтобы каждый набор получил свой файл
# ---------------------------------------------------------------------------
log_file_suite_start() {
    _CLUSTER_API_LOG_FILE=""
    _api_init_log_file
    # Передаём выбранный путь всем дочерним процессам тестов через BATS_FILE_TMPDIR
    if [[ -n "${BATS_FILE_TMPDIR:-}" ]]; then
        echo "$_CLUSTER_API_LOG_FILE" > "${BATS_FILE_TMPDIR}/api_log_path"
    fi
    local file_name
    file_name="$(basename "${BATS_TEST_FILENAME:-unknown}")"
    _log_write "INFO" "=== SUITE START: ${file_name} ==="
}

log_file_suite_end() {
    local file_name
    file_name="$(basename "${BATS_TEST_FILENAME:-unknown}")"
    _log_write "INFO" "=== SUITE END: ${file_name} ==="
}

# ---------------------------------------------------------------------------
# Жизненный цикл теста
# ---------------------------------------------------------------------------
log_test_start() {
    _log_write "INFO" "--- TEST START: ${BATS_TEST_DESCRIPTION:-unknown} ---"
}

log_test_end() {
    _log_write "INFO" "--- TEST END: ${BATS_TEST_DESCRIPTION:-unknown} ---"
}
