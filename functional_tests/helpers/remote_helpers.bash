#!/usr/bin/env bash
# =============================================================================
# remote_helpers.bash — примитивы выполнения по SSH для тестов внедрения сбоев
#
# Зависит от: подключённого .env (SSH_USER, SSH_NODE01-03, NODE*_RAFT_IP, CLUSTER_API_NODE*)
# =============================================================================

SSH_USER="${SSH_USER:-root}"
SSH_NODE01="${SSH_NODE01:-${NODE01_RAFT_IP:-192.168.1.11}}"
SSH_NODE02="${SSH_NODE02:-${NODE02_RAFT_IP:-192.168.1.12}}"
SSH_NODE03="${SSH_NODE03:-${NODE03_RAFT_IP:-192.168.1.13}}"
STORAGE_IP="${STORAGE_IP:-192.168.1.20}"

_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no)

# node_exec <node_id> <cmd...>
#   Выполняет shell-команду на узле через SSH. node_id: 1, 2 или 3.
node_exec() {
    local node_id="$1"; shift
    local ssh_host
    ssh_host=$(node_ssh_host "$node_id") || return 1
    ssh "${_SSH_OPTS[@]}" "${SSH_USER}@${ssh_host}" "$@"
}

# node_ssh_host <node_id>  →  имя хоста SSH (IP-адрес)
node_ssh_host() {
    case "$1" in
        1) echo "$SSH_NODE01" ;;
        2) echo "$SSH_NODE02" ;;
        3) echo "$SSH_NODE03" ;;
        *) echo "remote_helpers: unknown node_id '$1'" >&2; return 1 ;;
    esac
}

# node_raft_ip <node_id>  →  IP-адрес Raft
node_raft_ip() {
    case "$1" in
        1) echo "${NODE01_RAFT_IP:-192.168.1.11}" ;;
        2) echo "${NODE02_RAFT_IP:-192.168.1.12}" ;;
        3) echo "${NODE03_RAFT_IP:-192.168.1.13}" ;;
        *) echo "remote_helpers: unknown node_id '$1'" >&2; return 1 ;;
    esac
}

# node_name_for_id <node_id>  →  "node01" | "node02" | "node03" (имя узла)
node_name_for_id() {
    case "$1" in
        1) echo "node01" ;;
        2) echo "node02" ;;
        3) echo "node03" ;;
        *) echo "remote_helpers: unknown node_id '$1'" >&2; return 1 ;;
    esac
}

# node_id_for_name <name>  →  1 | 2 | 3 (идентификатор узла)
node_id_for_name() {
    case "$1" in
        node01) echo "1" ;;
        node02) echo "2" ;;
        node03) echo "3" ;;
        *) echo "remote_helpers: unknown node name '$1'" >&2; return 1 ;;
    esac
}

# api_for_node <node_id>  →  "localhost:1733x" (адрес CLUSTER_API узла)
api_for_node() {
    case "$1" in
        1) echo "${CLUSTER_API_NODE01:-localhost:17331}" ;;
        2) echo "${CLUSTER_API_NODE02:-localhost:17332}" ;;
        3) echo "${CLUSTER_API_NODE03:-localhost:17333}" ;;
        *) echo "remote_helpers: unknown node_id '$1'" >&2; return 1 ;;
    esac
}

# get_leader_id  →  выводит node_id лидера (1|2|3)
#   Последовательно опрашивает каждый узел до получения ответа.
get_leader_id() {
    local node_id
    for node_id in 1 2 3; do
        local target leader_id
        target=$(api_for_node "$node_id")
        leader_id=$(get_leader_node_id "$target" 2>/dev/null) || continue
        [[ -n "$leader_id" ]] && echo "$leader_id" && return 0
    done
    echo "remote_helpers: could not determine leader" >&2
    return 1
}

# get_follower_ids  →  выводит два node_id ведомых узлов (через пробел)
get_follower_ids() {
    local leader_id
    leader_id=$(get_leader_id) || return 1
    local followers=()
    for id in 1 2 3; do
        [[ "$id" != "$leader_id" ]] && followers+=("$id")
    done
    echo "${followers[*]}"
}
