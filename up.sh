#!/bin/bash
# ============================================================
# up.sh — 현재 서버 역할에 맞는 서비스 기동
# ============================================================
# 기동 순서: Worker 먼저 → Head 나중
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 역할 감지
source "${SCRIPT_DIR}/_detect-role.sh"

echo ""
echo -e "\033[0;36m[INFO]\033[0m  서버 역할: ${ROLE_NAME}"
echo -e "\033[0;36m[INFO]\033[0m  디렉토리:  ${ROLE_DIR}"
echo ""

if [[ "${ROLE_NAME}" == "head" ]]; then
    echo -e "\033[1;33m[WARN]\033[0m  Head 서버입니다. 모든 Worker가 먼저 기동되었는지 확인하세요."
    read -rp "계속 진행하시겠습니까? [Y/n]: " confirm
    if [[ "${confirm,,}" == "n" ]]; then
        echo "중단합니다."
        exit 0
    fi
fi

docker compose --project-directory "${ROLE_DIR}" -f "${ROLE_DIR}/docker-compose.yml" up -d

echo ""
echo -e "\033[0;32m[OK]\033[0m    ${ROLE_NAME} 서비스 기동 완료"
echo ""
echo "  로그 확인:"
if [[ "${ROLE_NAME}" == "head" ]]; then
    echo "    docker logs -f vllm-gpu-all"
else
    echo "    docker logs -f vllm-worker"
fi
