#!/usr/bin/env bash
# =============================================================================
# load_helper.bash — Инициализация набора тестов отказоустойчивости
# Использование в .bats: load 'load_helper'
# =============================================================================

_ft_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_root_dir="$(cd "${_ft_dir}/../../functional_tests" && pwd)"

load "${_root_dir}/tests/lib/bats-support/load.bash"
load "${_root_dir}/tests/lib/bats-assert/load.bash"

[[ -f "${_root_dir}/.env" ]] && source "${_root_dir}/.env"

source "${_root_dir}/helpers/logging.bash"
source "${_root_dir}/helpers/grpc_helpers.bash"
source "${_root_dir}/helpers/validators.bash"
source "${_root_dir}/helpers/cluster_reset.bash"
source "${_root_dir}/helpers/cluster_bootstrap.bash"
source "${_root_dir}/helpers/remote_helpers.bash"
source "${_root_dir}/helpers/fault_helpers.bash"

# ---------------------------------------------------------------------------
# setup() — перед каждым тестом отказоустойчивости
#   1. fault_cleanup_all  — удалить остаточные сбои от предыдущего теста
#   2. _cluster_reset     — сбросить все узлы в состояние UNINITIALIZED
#   3. _cluster_bootstrap — восстановить кластер из 3 узлов в состояние RUNNING
# ---------------------------------------------------------------------------
setup() {
    log_test_start
    fault_cleanup_all
    _cluster_reset || {
        log_error "cluster_reset failed in setup"
        return 1
    }
    _cluster_bootstrap || {
        log_error "cluster_bootstrap failed in setup"
        return 1
    }
}

# ---------------------------------------------------------------------------
# teardown() — после каждого теста отказоустойчивости
#   Очистка выполняется только при УСПЕХЕ (BATS_TEST_COMPLETED=1).
#   При сбое: состояние кластера сохраняется для разбора полётов.
# ---------------------------------------------------------------------------
teardown() {
    log_test_end
    if [[ "${BATS_TEST_COMPLETED:-0}" -eq 1 ]]; then
        fault_cleanup_all || true
        stop_all_test_vms || true
    else
        log_info "Test FAILED — teardown skipped, cluster state preserved for analysis"
    fi
}

# ---------------------------------------------------------------------------
# teardown_file() — один раз после ВСЕХ тестов файла, независимо от исхода
#   Страховка на случай, если ПОСЛЕДНИЙ тест файла упал: per-test teardown()
#   намеренно не чистит при сбое ("state preserved for analysis"), а следующий
#   test'ый setup() обычно чистит через пару секунд — но для последнего теста
#   файла следующего setup() не будет. Без этой страховки run_tests.sh --fault
#   (он гоняет bats отдельным процессом на каждый *.bats-файл суита) оставлял
#   бы стенд с активными iptables/tc/NTP-сдвигом/fill-файлами до следующего
#   ЛЮБОГО запуска fault-сьюта.
# ---------------------------------------------------------------------------
teardown_file() {
    log_info "teardown_file: final safety-net cleanup for this suite file"
    fault_cleanup_all || true
    stop_all_test_vms || true
}
