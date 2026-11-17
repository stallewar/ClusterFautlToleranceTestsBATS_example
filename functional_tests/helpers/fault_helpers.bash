#!/usr/bin/env bash
# =============================================================================
# fault_helpers.bash — Внедрение сбоев, очистка и опрос состояния для FT-тестов
#
# Зависимости: remote_helpers.bash, grpc_helpers.bash, logging.bash
#
# Таймауты по умолчанию соответствуют конфигурации тестового кластера:
#   selfFencingTimeout=15s, storageFencingGracePeriod=25s, fenceTimeout=30.5s
# =============================================================================

FAULT_RAFT_RECOVERY_TIMEOUT="${FAULT_RAFT_RECOVERY_TIMEOUT:-60}"
FAULT_STORAGE_RECOVERY_TIMEOUT="${FAULT_STORAGE_RECOVERY_TIMEOUT:-90}"
FAULT_CLUSTER_STORAGE_WAIT="${FAULT_CLUSTER_STORAGE_WAIT:-120}"
FAULT_PROCESS_RECOVERY_TIMEOUT="${FAULT_PROCESS_RECOVERY_TIMEOUT:-60}"
FAULT_NET_RECOVERY_TIMEOUT="${FAULT_NET_RECOVERY_TIMEOUT:-90}"
FAULT_POLL_INTERVAL="${FAULT_POLL_INTERVAL:-2}"

RAFT_PORT="${RAFT_PORT:-16330}"

# ============================================================================
# iptables — Изоляция Raft
# ============================================================================

# raft_block_between <node_id_a> <node_id_b>
#   Блокирует Raft-порт (TCP 16330) двунаправленно между двумя узлами.
raft_block_between() {
    local a="$1" b="$2"
    local ip_a ip_b
    ip_a=$(node_raft_ip "$a"); ip_b=$(node_raft_ip "$b")
    log_info "FAULT: raft_block_between node$a ($ip_a) ↔ node$b ($ip_b)"
    node_exec "$a" "iptables -A INPUT  -s $ip_b -p tcp --dport $RAFT_PORT -j DROP
                    iptables -A OUTPUT -d $ip_b -p tcp --dport $RAFT_PORT -j DROP"
    node_exec "$b" "iptables -A INPUT  -s $ip_a -p tcp --dport $RAFT_PORT -j DROP
                    iptables -A OUTPUT -d $ip_a -p tcp --dport $RAFT_PORT -j DROP"
}

# raft_isolate_node <node_id>
#   Блокирует Raft между этим узлом и всеми остальными.
raft_isolate_node() {
    local node="$1"
    for peer in 1 2 3; do
        [[ "$peer" == "$node" ]] && continue
        raft_block_between "$node" "$peer"
    done
}

# raft_unblock_node <node_id>
#   Удаляет все правила DROP для Raft на узле (INPUT + OUTPUT для порта RAFT_PORT),
#   а также зеркальные правила на остальных узлах, блокирующие IP этого узла.
#   raft_isolate_node ставит правила через raft_block_between СИММЕТРИЧНО — на
#   обеих сторонах каждой пары (на изолируемом узле и на каждом его соседе) —
#   снимать их нужно тоже с обеих сторон, иначе соседи остаются с "мёртвыми"
#   DROP-правилами против этого узла до следующего setup() теста.
raft_unblock_node() {
    local node="$1"
    local ip; ip=$(node_raft_ip "$node")
    log_info "FAULT: raft_unblock_node node$node"
    node_exec "$node" "iptables -S | grep \"dport ${RAFT_PORT}.*DROP\" | sed 's/^-A/-D/' | while IFS= read -r rule; do iptables \$rule 2>/dev/null || true; done" || true
    for peer in 1 2 3; do
        [[ "$peer" == "$node" ]] && continue
        node_exec "$peer" "iptables -S | grep \"dport ${RAFT_PORT}.*DROP\" | grep -- \"$ip\" | sed 's/^-A/-D/' | while IFS= read -r rule; do iptables \$rule 2>/dev/null || true; done" || true
    done
}

# ============================================================================
# iptables — Изоляция хранилища
# ============================================================================

# storage_block <node_id>
storage_block() {
    local node="$1"
    local sip="${STORAGE_IP:-192.168.1.20}"
    log_info "FAULT: storage_block node$node → $sip"
    node_exec "$node" "iptables -A OUTPUT -d $sip -j DROP
                       iptables -A INPUT  -s $sip -j DROP"
}

# storage_unblock <node_id>
storage_unblock() {
    local node="$1"
    local sip="${STORAGE_IP:-192.168.1.20}"
    log_info "FAULT: storage_unblock node$node"
    node_exec "$node" "iptables -D OUTPUT -d $sip -j DROP 2>/dev/null || true
                       iptables -D INPUT  -s $sip -j DROP 2>/dev/null || true"
}

# ============================================================================
# iptables — Полная сетевая изоляция (SSH сохраняется)
# ============================================================================

# net_isolate_node <node_id>
#   Блокирует весь внутрикластерный трафик (IP других узлов + IP хранилища).
#   SSH (порт 22) НЕ блокируется — управляющий канал остаётся доступным.
net_isolate_node() {
    local node="$1"
    local sip="${STORAGE_IP:-192.168.1.20}"
    log_info "FAULT: net_isolate_node node$node"
    for peer in 1 2 3; do
        [[ "$peer" == "$node" ]] && continue
        local peer_ip
        peer_ip=$(node_raft_ip "$peer")
        node_exec "$node" "iptables -A INPUT  -s $peer_ip -j DROP
                           iptables -A OUTPUT -d $peer_ip -j DROP"
    done
    node_exec "$node" "iptables -A OUTPUT -d $sip -j DROP
                       iptables -A INPUT  -s $sip -j DROP"
}

# net_unblock_all <node_id>
#   Удаляет все правила DROP в цепочках INPUT и OUTPUT.
net_unblock_all() {
    local node="$1"
    log_info "FAULT: net_unblock_all node$node"
    node_exec "$node" "
        iptables -S INPUT  | grep -w DROP | sed 's/^-A/-D/' | while IFS= read -r r; do iptables \$r 2>/dev/null || true; done
        iptables -S OUTPUT | grep -w DROP | sed 's/^-A/-D/' | while IFS= read -r r; do iptables \$r 2>/dev/null || true; done
    " || true
}

# ============================================================================
# tc netem — Деградация трафика (фильтры u32 по IP-адресу назначения)
# ============================================================================

# tc_degrade_raft <node_id> <netem_args>
#   Применяет netem только к IP-адресам Raft-пиров.
#   Примеры netem_args: "delay 2000ms", "loss 30%"
tc_degrade_raft() {
    local node="$1"; shift
    local netem_args="$*"
    local iface
    iface=$(node_exec "$node" "ip route get $(node_raft_ip 1) 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || echo eth0")
    log_info "FAULT: tc_degrade_raft node$node iface=$iface '$netem_args'"
    local self_ip
    self_ip=$(node_raft_ip "$node")
    node_exec "$node" "
        tc qdisc add dev $iface root handle 1: prio priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        tc qdisc add dev $iface parent 1:2 handle 20: netem $netem_args
        for peer_ip in $(node_raft_ip 1) $(node_raft_ip 2) $(node_raft_ip 3); do
            [ \"\$peer_ip\" = \"$self_ip\" ] && continue
            tc filter add dev $iface parent 1: protocol ip u32 match ip dst \$peer_ip/32 flowid 1:2
        done
    "
}

# tc_degrade_storage <node_id> <netem_args>
#   Применяет netem только к IP-адресу хранилища.
tc_degrade_storage() {
    local node="$1"; shift
    local netem_args="$*"
    local sip="${STORAGE_IP:-192.168.1.20}"
    local iface
    iface=$(node_exec "$node" "ip route get $sip 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || echo eth0")
    log_info "FAULT: tc_degrade_storage node$node iface=$iface '$netem_args'"
    node_exec "$node" "
        tc qdisc add dev $iface root handle 1: prio priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
        tc qdisc add dev $iface parent 1:2 handle 20: netem $netem_args
        tc filter add dev $iface parent 1: protocol ip u32 match ip dst $sip/32 flowid 1:2
    "
}

# tc_clear <node_id>
#   Удаляет корневой qdisc на основном интерфейсе (удаляет все дочерние qdisc).
tc_clear() {
    local node="$1"
    log_info "FAULT: tc_clear node$node"
    local iface
    iface=$(node_exec "$node" "ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || echo eth0")
    node_exec "$node" "tc qdisc del dev $iface root 2>/dev/null || true"
}

# ============================================================================
# Управление сервисами и процессами
# ============================================================================

service_stop()    { local n="$1" s="$2"; log_info "FAULT: service_stop node$n $s";    node_exec "$n" "systemctl stop $s"; }
service_start()   { local n="$1" s="$2"; log_info "FAULT: service_start node$n $s";   node_exec "$n" "systemctl start $s"; }
service_restart() { local n="$1" s="$2"; log_info "FAULT: service_restart node$n $s"; node_exec "$n" "systemctl restart $s"; }

# process_kill9 <node_id> <process_name>
process_kill9() {
    local node="$1" proc="$2"
    log_info "FAULT: process_kill9 node$node $proc"
    node_exec "$node" "pkill -9 -x '$proc' 2>/dev/null || pkill -9 -f '$proc' 2>/dev/null || true"
}

# wait_for_service_state <node_id> <service> <expected_state> [max_s] [interval_s]
#   expected_state: "active" или "inactive"
wait_for_service_state() {
    local node="$1" svc="$2" expected="$3"
    local max="${4:-30}" interval="${5:-2}" elapsed=0
    while (( elapsed < max )); do
        local state
        state=$(node_exec "$node" "systemctl is-active '$svc' 2>/dev/null || echo unknown")
        [[ "$state" == "$expected" ]] && return 0
        sleep "$interval"
        (( elapsed += interval ))
    done
    log_error "Timeout waiting for $svc on node$node to be '$expected' (got: $state)"
    return 1
}

# ============================================================================
# Манипуляция временем
# ============================================================================

# set_time_offset <node_id> <offset_expr>
#   Отключает NTP и сдвигает время. offset_expr: "+30 seconds", "-30 seconds"
set_time_offset() {
    local node="$1" expr="$2"
    log_info "FAULT: set_time_offset node$node '$expr'"
    node_exec "$node" "timedatectl set-ntp false && date -s '$expr'"
}

# restore_ntp <node_id>
restore_ntp() {
    local node="$1"
    log_info "FAULT: restore_ntp node$node"
    node_exec "$node" "timedatectl set-ntp true" || true
}

# ============================================================================
# Деградация хранилища (заполнение диска)
# ============================================================================

# storage_fill_start <node_id>
#   Записывает большой файл на точку монтирования STORAGE_HB для заполнения / нагрузки хранилища.
storage_fill_start() {
    local node="$1"
    local path="${STORAGE_HB:-/mnt/storage-space/storage-system}"
    log_info "FAULT: storage_fill_start node$node path=$path"
    node_exec "$node" "dd if=/dev/zero of=${path}/_fault_fill bs=1M count=4096 &>/dev/null &"
}

storage_fill_stop() {
    local node="$1"
    local path="${STORAGE_HB:-/mnt/storage-space/storage-system}"
    log_info "FAULT: storage_fill_stop node$node"
    node_exec "$node" "rm -f '${path}/_fault_fill'; pkill -f 'dd.*_fault_fill' 2>/dev/null || true"
}

local_disk_fill_start() {
    local node="$1"
    log_info "FAULT: local_disk_fill_start node$node"
    node_exec "$node" "dd if=/dev/zero of=/tmp/_fault_fill bs=1M count=2048 &>/dev/null &"
}

local_disk_fill_stop() {
    local node="$1"
    log_info "FAULT: local_disk_fill_stop node$node"
    node_exec "$node" "rm -f /tmp/_fault_fill; pkill -f 'dd.*_fault_fill' 2>/dev/null || true"
}

# ============================================================================
# Опрос восстановления
# ============================================================================

# wait_for_cluster_running [max_s] [interval_s]
#   Ожидает, пока ВСЕ три узла сообщат NODE_STATE_RUNNING.
wait_for_cluster_running() {
    local max="${1:-$FAULT_RAFT_RECOVERY_TIMEOUT}" interval="${2:-$FAULT_POLL_INTERVAL}"
    local elapsed=0
    log_step "Waiting for cluster recovery (max ${max}s)..."
    while (( elapsed < max )); do
        local all_running=true
        for id in 1 2 3; do
            local target state
            target=$(api_for_node "$id")
            state=$(get_node_state "$target" 2>/dev/null) || { all_running=false; break; }
            [[ "$state" == "NODE_STATE_RUNNING" ]] || { all_running=false; break; }
        done
        $all_running && { log_info "Cluster recovered after ${elapsed}s"; return 0; }
        sleep "$interval"
        (( elapsed += interval ))
    done
    log_error "Cluster not recovered after ${max}s"
    return 1
}

# wait_for_node_running <node_id> [max_s] [interval_s]
wait_for_node_running() {
    local node="$1"
    local max="${2:-$FAULT_RAFT_RECOVERY_TIMEOUT}" interval="${3:-$FAULT_POLL_INTERVAL}"
    local target
    target=$(api_for_node "$node")
    wait_for_node_state "$target" "NODE_STATE_RUNNING" "$(( max / interval ))" "$interval"
}

# ============================================================================
# Проверка отсутствия двойного запуска
# ============================================================================

# assert_no_dual_run <vm_id>
#   Проверяет, что vm_id находится в состоянии running не более чем на одном узле.
assert_no_dual_run() {
    local vm_id="$1"
    local running_count=0 running_node="" unreachable_nodes=""
    for id in 1 2 3; do
        local target resp on_node
        target=$(api_for_node "$id")
        resp=$(grpc_list_vms "$target" 2>/dev/null) || { unreachable_nodes+="node$id "; continue; }
        on_node=$(echo "$resp" | jq --arg vid "$vm_id" \
            '[.vms[]? | select(.id.id==$vid and .status=="VM_STATUS_RUNNING")] | length' 2>/dev/null) || { unreachable_nodes+="node$id "; continue; }
        if [[ "${on_node:-0}" -gt 0 ]]; then
            (( running_count++ ))
            running_node="node$id"
        fi
    done
    if [[ -n "$unreachable_nodes" ]]; then
        log_warn "assert_no_dual_run: could not query ${unreachable_nodes}for vm $vm_id state — dual-run there cannot be ruled out"
    fi
    if [[ "$running_count" -gt 1 ]]; then
        log_error "DUAL-RUN: vm $vm_id is running on $running_count nodes simultaneously"
        return 1
    fi
    log_info "No dual-run: vm $vm_id on ${running_count} node(s) (${running_node:-none})"
    return 0
}

# poll_no_dual_run <vm_id> <total_seconds> [interval_s]
#   Опрашивает assert_no_dual_run каждые interval_s в течение total_seconds.
#   Используйте ВМЕСТО обычного `sleep N` в тестах без двойного запуска —
#   проверяет безопасность ВМ на протяжении всего окна сбоя, а не только после него.
poll_no_dual_run() {
    local vm_id="$1" total_s="$2" interval="${3:-3}"
    local elapsed=0
    log_step "poll_no_dual_run: checking '$vm_id' every ${interval}s for ${total_s}s"
    while (( elapsed < total_s )); do
        assert_no_dual_run "$vm_id" || return 1
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done
    log_info "poll_no_dual_run: no dual-run detected over ${elapsed}s"
    return 0
}

# ============================================================================
# Верификация внедрения — проверяет, что сбои действительно применены
# ============================================================================

# assert_raft_blocked_between <node_a> <node_b>
#   Проверяет наличие двунаправленных правил Raft DROP на обоих узлах.
assert_raft_blocked_between() {
    local a="$1" b="$2"
    local ip_a ip_b
    ip_a=$(node_raft_ip "$a"); ip_b=$(node_raft_ip "$b")
    node_exec "$a" "iptables -S INPUT | grep -q '${ip_b}.*dport ${RAFT_PORT}.*DROP'" \
        || { log_error "assert_raft_blocked_between: no Raft DROP for $ip_b on node$a INPUT — injection may have failed"; return 1; }
    node_exec "$b" "iptables -S INPUT | grep -q '${ip_a}.*dport ${RAFT_PORT}.*DROP'" \
        || { log_error "assert_raft_blocked_between: no Raft DROP for $ip_a on node$b INPUT — injection may have failed"; return 1; }
    log_info "assert_raft_blocked_between: node$a ↔ node$b DROP rules verified"
}

# assert_raft_node_isolated <node_id>
#   Проверяет наличие правил Raft DROP на узле по отношению ко ВСЕМ остальным узлам.
assert_raft_node_isolated() {
    local node="$1"
    for peer in 1 2 3; do
        [[ "$peer" == "$node" ]] && continue
        assert_raft_blocked_between "$node" "$peer" || return 1
    done
    log_info "assert_raft_node_isolated: node$node isolation verified"
}

# assert_storage_blocked <node_id>
#   Проверяет наличие правила OUTPUT DROP для IP хранилища на узле.
assert_storage_blocked() {
    local node="$1"
    local sip="${STORAGE_IP:-192.168.1.20}"
    node_exec "$node" "iptables -S OUTPUT | grep -q '${sip}.*DROP'" \
        || { log_error "assert_storage_blocked: no DROP for storage $sip on node$node OUTPUT — injection may have failed"; return 1; }
    log_info "assert_storage_blocked: node$node → $sip OUTPUT DROP verified"
}

# assert_net_isolated <node_id>
#   Проверяет наличие правил DROP для всех IP пиров + IP хранилища на узле.
assert_net_isolated() {
    local node="$1"
    local sip="${STORAGE_IP:-192.168.1.20}"
    for peer in 1 2 3; do
        [[ "$peer" == "$node" ]] && continue
        local peer_ip
        peer_ip=$(node_raft_ip "$peer")
        node_exec "$node" "iptables -S INPUT | grep -q '${peer_ip}.*DROP'" \
            || { log_error "assert_net_isolated: no DROP for peer $peer_ip on node$node INPUT — injection may have failed"; return 1; }
    done
    node_exec "$node" "iptables -S OUTPUT | grep -q '${sip}.*DROP'" \
        || { log_error "assert_net_isolated: no DROP for storage $sip on node$node OUTPUT — injection may have failed"; return 1; }
    log_info "assert_net_isolated: node$node fully isolated (all peers + storage verified)"
}

# ============================================================================
# Глобальная очистка — вызывать в setup() перед каждым тестом
# ============================================================================

# fault_cleanup_all
#   Удаление всех внедрённых сбоев на всех трёх узлах по возможности (best-effort).
fault_cleanup_all() {
    log_info "FAULT_CLEANUP: removing all fault injections on all nodes"
    for node in 1 2 3; do
        net_unblock_all "$node"       || log_warn "net_unblock_all node$node failed (ok)"
        tc_clear "$node"              || log_warn "tc_clear node$node failed (ok)"
        restore_ntp "$node"           || log_warn "restore_ntp node$node failed (ok)"
        storage_fill_stop "$node"     || log_warn "storage_fill_stop node$node failed (ok)"
        local_disk_fill_stop "$node"  || log_warn "local_disk_fill_stop node$node failed (ok)"
        node_exec "$node" "systemctl start cluster-service 2>/dev/null || true" || true
        node_exec "$node" "systemctl start host-agent 2>/dev/null || true" || true
    done
}
