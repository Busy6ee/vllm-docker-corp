#!/bin/bash
# ============================================================
# _detect-role.sh — 현재 서버의 역할 자동 감지 (source 용)
# ============================================================
# 사용법: source _detect-role.sh
# 결과:   ROLE_DIR 변수에 해당 서버의 generated 디렉토리 경로 설정
#         ROLE_NAME 변수에 "head" 또는 "worker-N" 설정
# ============================================================

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# cluster.conf 탐색: 같은 디렉토리 → generated/ 하위 (하위 호환)
if [[ -f "${_SCRIPT_DIR}/cluster.conf" ]]; then
    _CLUSTER_CONF="${_SCRIPT_DIR}/cluster.conf"
elif [[ -f "${_SCRIPT_DIR}/generated/cluster.conf" ]]; then
    _CLUSTER_CONF="${_SCRIPT_DIR}/generated/cluster.conf"
else
    echo -e "\033[0;31m[ERROR]\033[0m cluster.conf 를 찾을 수 없습니다."
    echo "        먼저 generate.sh 를 실행하세요."
    exit 1
fi

# cluster.conf 로드
source "${_CLUSTER_CONF}"

# 로컬 IP 목록 수집
mapfile -t LOCAL_IPS < <(hostname -I | tr ' ' '\n' | grep -v '^$')
LOCAL_IPS+=("127.0.0.1")

# IP 매칭 함수
_ip_is_local() {
    local target="$1"
    for lip in "${LOCAL_IPS[@]}"; do
        if [[ "${lip}" == "${target}" ]]; then
            return 0
        fi
    done
    return 1
}

# 역할 감지
ROLE_DIR=""
ROLE_NAME=""

# docker-compose.yml이 현재 디렉토리에 있으면 배포된 단일 폴더 구조
_IS_DEPLOYED=false
if [[ -f "${_SCRIPT_DIR}/docker-compose.yml" ]]; then
    _IS_DEPLOYED=true
fi

if _ip_is_local "${HEAD_IP}"; then
    ROLE_NAME="head"
    if $_IS_DEPLOYED; then
        ROLE_DIR="${_SCRIPT_DIR}"
    else
        ROLE_DIR="${_SCRIPT_DIR}/generated/head"
    fi
else
    for i in $(seq 1 "${WORKER_COUNT}"); do
        var="WORKER_${i}_IP"
        if _ip_is_local "${!var}"; then
            ROLE_NAME="worker-${i}"
            if $_IS_DEPLOYED; then
                ROLE_DIR="${_SCRIPT_DIR}"
            else
                ROLE_DIR="${_SCRIPT_DIR}/generated/worker-${i}"
            fi
            break
        fi
    done
fi

if [[ -z "${ROLE_DIR}" ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m 이 서버의 IP가 cluster.conf 와 일치하지 않습니다."
    echo ""
    echo "  로컬 IP:    ${LOCAL_IPS[*]}"
    echo "  HEAD_IP:    ${HEAD_IP}"
    for i in $(seq 1 "${WORKER_COUNT}"); do
        var="WORKER_${i}_IP"
        echo "  WORKER-${i}:   ${!var}"
    done
    echo ""
    echo "  cluster.conf 를 확인하거나 generate.sh 를 다시 실행하세요."
    exit 1
fi

if [[ ! -d "${ROLE_DIR}" ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m 디렉토리가 없습니다: ${ROLE_DIR}"
    echo "        generate.sh 를 다시 실행하세요."
    exit 1
fi
