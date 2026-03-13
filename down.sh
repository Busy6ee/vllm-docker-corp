#!/bin/bash
# ============================================================
# down.sh — 현재 서버 역할에 맞는 서비스 중지
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 역할 감지
source "${SCRIPT_DIR}/_detect-role.sh"

echo ""
echo -e "\033[0;36m[INFO]\033[0m  서버 역할: ${ROLE_NAME}"
echo -e "\033[0;36m[INFO]\033[0m  디렉토리:  ${ROLE_DIR}"
echo ""

docker compose --project-directory "${ROLE_DIR}" -f "${ROLE_DIR}/docker-compose.yml" down

echo ""
echo -e "\033[0;32m[OK]\033[0m    ${ROLE_NAME} 서비스 중지 완료"
