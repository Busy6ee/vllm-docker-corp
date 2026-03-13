#!/bin/bash
# ============================================================
# generate.sh — 클러스터 설정 파일 생성
# ============================================================
# 용도: 템플릿 기반으로 Head/Worker 별 설정 파일 생성
#   generated/
#     cluster.conf
#     head/         .env, docker-compose.yml, nginx.conf, env.proxy
#     worker-1/     .env, docker-compose.yml, env.proxy
#     worker-N/     ...
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
GENERATED_DIR="${SCRIPT_DIR}/generated"

# ============================================================
# 색상 / 유틸
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ============================================================
# 포트 사용 확인 함수
# ============================================================
# 지정된 포트가 현재 LISTEN 상태인지 확인
check_port_in_use() {
    local port="$1"
    if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
        return 0  # 사용 중
    fi
    return 1  # 미사용
}

# Head/Worker에서 사용할 포트 목록과 용도
declare -A HEAD_PORTS=(
    [6379]="Ray Head"
    [8000]="vLLM API"
    [11434]="Ollama"
    [11435]="Nginx → vLLM"
    [11436]="Nginx → Ollama"
)
WORKER_PORTS_LIST="6379"  # Worker는 Ray만 listen

# ============================================================
# 템플릿 치환 함수
# ============================================================
render_template() {
    local tmpl="$1"; shift
    local out="$1"; shift

    cp "$tmpl" "$out"
    for pair in "$@"; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        sed -i "s|{{${key}}}|${val}|g" "$out"
    done
}

# ============================================================
# 템플릿 존재 확인
# ============================================================
for f in head-env.template head-docker-compose.template \
         worker-env.template worker-docker-compose.template; do
    if [[ ! -f "${TEMPLATE_DIR}/${f}" ]]; then
        error "템플릿 파일이 없습니다: ${TEMPLATE_DIR}/${f}"
        exit 1
    fi
done

if [[ ! -f "${SCRIPT_DIR}/nginx.conf" ]]; then
    error "nginx.conf 파일이 없습니다: ${SCRIPT_DIR}/nginx.conf"
    exit 1
fi

# ############################################################
#  클러스터 구성 입력
# ############################################################
echo ""
echo "============================================"
echo " 클러스터 구성"
echo "============================================"
echo ""

# --- 서버 수 ---
read -rp "클러스터 전체 서버 수 (Head 포함) [기본값: 2]: " INPUT_TOTAL_SERVERS
INPUT_TOTAL_SERVERS="${INPUT_TOTAL_SERVERS:-2}"
if [[ "${INPUT_TOTAL_SERVERS}" -lt 1 ]]; then
    error "최소 1대(Head) 이상이어야 합니다."
    exit 1
fi
NUM_WORKERS=$((INPUT_TOTAL_SERVERS - 1))
info "Head: 1대 / Worker: ${NUM_WORKERS}대"

# --- Head IP ---
echo ""
read -rp "Head 서버 IP (HEAD_IP): " INPUT_HEAD_IP
while [[ -z "${INPUT_HEAD_IP}" ]]; do
    echo "  필수 항목입니다."
    read -rp "Head 서버 IP (HEAD_IP): " INPUT_HEAD_IP
done

# --- Worker IPs ---
declare -a WORKER_IPS
for i in $(seq 1 "${NUM_WORKERS}"); do
    read -rp "Worker-${i} 서버 IP: " wip
    while [[ -z "${wip}" ]]; do
        echo "  필수 항목입니다."
        read -rp "Worker-${i} 서버 IP: " wip
    done
    WORKER_IPS+=("${wip}")
done

# ############################################################
#  공통 설정 입력
# ############################################################
echo ""
echo "--------------------------------------------"
echo " 공통 설정"
echo "--------------------------------------------"

# NIC 자동 감지
DETECTED_NIC=$(ip -o -4 route show default 2>/dev/null | awk '{print $5}' | head -1 || true)
read -rp "네트워크 인터페이스 (NIC_NAME) [기본값: ${DETECTED_NIC:-eth0}]: " INPUT_NIC_NAME
INPUT_NIC_NAME="${INPUT_NIC_NAME:-${DETECTED_NIC:-eth0}}"

read -rp "HF_TOKEN (Hugging Face 토큰): " INPUT_HF_TOKEN
while [[ -z "${INPUT_HF_TOKEN}" ]]; do
    echo "  필수 항목입니다."
    read -rp "HF_TOKEN: " INPUT_HF_TOKEN
done

read -rp "NCCL_IB_DISABLE (InfiniBand 없으면 1, 있으면 0) [기본값: 1]: " INPUT_NCCL_IB
INPUT_NCCL_IB="${INPUT_NCCL_IB:-1}"

read -rp "SSL_CERT_FILE [기본값: /etc/ssl/certs/ca-certificates.crt]: " INPUT_SSL_CERT
INPUT_SSL_CERT="${INPUT_SSL_CERT:-/etc/ssl/certs/ca-certificates.crt}"

read -rp "데이터 디렉토리 (모든 노드 공유 경로) [기본값: /mnt/nas]: " INPUT_DATA_DIR
INPUT_DATA_DIR="${INPUT_DATA_DIR:-/mnt/nas}"

# ############################################################
#  GPU 설정
# ############################################################
echo ""
echo "--------------------------------------------"
echo " GPU 설정"
echo "--------------------------------------------"

DETECTED_GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l || echo 0)
if [[ "${DETECTED_GPU_COUNT}" -gt 0 ]]; then
    info "이 서버에서 감지된 GPU 수: ${DETECTED_GPU_COUNT}"
fi

read -rp "서버 당 GPU 수 (GPU_PER_NODE) [기본값: ${DETECTED_GPU_COUNT:-8}]: " INPUT_GPU_PER_NODE
INPUT_GPU_PER_NODE="${INPUT_GPU_PER_NODE:-${DETECTED_GPU_COUNT:-8}}"

TOTAL_GPU_COUNT=$((INPUT_GPU_PER_NODE * INPUT_TOTAL_SERVERS))
info "클러스터 전체 GPU 수: ${TOTAL_GPU_COUNT} (${INPUT_GPU_PER_NODE} x ${INPUT_TOTAL_SERVERS})"

CUDA_DEVICES=$(seq -s',' 0 $((INPUT_GPU_PER_NODE - 1)))

read -rp "공유 메모리 크기 (SHM_SIZE) [기본값: 16gb]: " INPUT_SHM_SIZE
INPUT_SHM_SIZE="${INPUT_SHM_SIZE:-16gb}"

# ############################################################
#  Head 전용 설정
# ############################################################
echo ""
echo "--------------------------------------------"
echo " Head 서버 전용 설정"
echo "--------------------------------------------"

read -rp "VLLM_API_KEY: " INPUT_VLLM_API_KEY
while [[ -z "${INPUT_VLLM_API_KEY}" ]]; do
    echo "  필수 항목입니다."
    read -rp "VLLM_API_KEY: " INPUT_VLLM_API_KEY
done

echo ""
echo "  --- 모델 설정 ---"
read -rp "모델 ID (예: zai-org/GLM-4.7) [기본값: zai-org/GLM-4.7]: " INPUT_MODEL_ID
INPUT_MODEL_ID="${INPUT_MODEL_ID:-zai-org/GLM-4.7}"

read -rp "서빙 모델 이름 (--served-model-name) [기본값: glm-4.7]: " INPUT_SERVED_NAME
INPUT_SERVED_NAME="${INPUT_SERVED_NAME:-glm-4.7}"

read -rp "Tensor Parallel Size [기본값: ${INPUT_GPU_PER_NODE}]: " INPUT_TP_SIZE
INPUT_TP_SIZE="${INPUT_TP_SIZE:-${INPUT_GPU_PER_NODE}}"

PP_DEFAULT="${INPUT_TOTAL_SERVERS}"
read -rp "Pipeline Parallel Size [기본값: ${PP_DEFAULT}]: " INPUT_PP_SIZE
INPUT_PP_SIZE="${INPUT_PP_SIZE:-${PP_DEFAULT}}"

read -rp "GPU Memory Utilization (0.0~1.0) [기본값: 0.90]: " INPUT_GPU_MEM
INPUT_GPU_MEM="${INPUT_GPU_MEM:-0.90}"

read -rp "Max Model Length [기본값: 16384]: " INPUT_MAX_LEN
INPUT_MAX_LEN="${INPUT_MAX_LEN:-16384}"

# ############################################################
#  env.proxy 설정
# ############################################################
echo ""
echo "--------------------------------------------"
echo " 컨테이너 프록시 설정 (env.proxy)"
echo "--------------------------------------------"

CONTAINER_PROXY_ENABLED=false
CONTAINER_HTTP_PROXY=""
CONTAINER_HTTPS_PROXY=""
CONTAINER_NO_PROXY=""

# 시스템 프록시 감지
SYS_HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
if [[ -n "${SYS_HTTP_PROXY}" ]]; then
    info "시스템 프록시 감지: ${SYS_HTTP_PROXY}"
    read -rp "컨테이너에도 동일 프록시를 적용하시겠습니까? [Y/n]: " use_sys_proxy
    if [[ "${use_sys_proxy,,}" != "n" ]]; then
        CONTAINER_PROXY_ENABLED=true
        CONTAINER_HTTP_PROXY="${SYS_HTTP_PROXY}"
        CONTAINER_HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-${SYS_HTTP_PROXY}}}"
        CONTAINER_NO_PROXY="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1}}"
    fi
fi

if ! $CONTAINER_PROXY_ENABLED; then
    read -rp "컨테이너 HTTP_PROXY (없으면 Enter): " CONTAINER_HTTP_PROXY
    if [[ -n "${CONTAINER_HTTP_PROXY}" ]]; then
        CONTAINER_PROXY_ENABLED=true
        read -rp "컨테이너 HTTPS_PROXY [기본값: ${CONTAINER_HTTP_PROXY}]: " input
        CONTAINER_HTTPS_PROXY="${input:-${CONTAINER_HTTP_PROXY}}"
        read -rp "컨테이너 NO_PROXY [기본값: localhost,127.0.0.1]: " input
        CONTAINER_NO_PROXY="${input:-localhost,127.0.0.1}"
    fi
fi

# ############################################################
#  입력 요약
# ############################################################
echo ""
echo "============================================"
echo " 설정 요약"
echo "============================================"
echo "  클러스터:        ${INPUT_TOTAL_SERVERS}대 (Head 1 + Worker ${NUM_WORKERS})"
echo "  HEAD_IP:         ${INPUT_HEAD_IP}"
for i in $(seq 1 "${NUM_WORKERS}"); do
    echo "  WORKER-${i} IP:    ${WORKER_IPS[$((i-1))]}"
done
echo "  NIC_NAME:        ${INPUT_NIC_NAME}"
echo "  HF_TOKEN:        ${INPUT_HF_TOKEN:0:10}..."
echo "  NCCL_IB_DISABLE: ${INPUT_NCCL_IB}"
echo "  SSL_CERT_FILE:   ${INPUT_SSL_CERT}"
echo "  GPU/노드:        ${INPUT_GPU_PER_NODE}"
echo "  전체 GPU:        ${TOTAL_GPU_COUNT}"
echo "  CUDA_DEVICES:    ${CUDA_DEVICES}"
echo "  SHM_SIZE:        ${INPUT_SHM_SIZE}"
echo "  데이터 디렉토리: ${INPUT_DATA_DIR}"
echo "  VLLM_API_KEY:    ${INPUT_VLLM_API_KEY:0:10}..."
echo "  모델 ID:         ${INPUT_MODEL_ID}"
echo "  서빙 이름:       ${INPUT_SERVED_NAME}"
echo "  TP Size:         ${INPUT_TP_SIZE}"
echo "  PP Size:         ${INPUT_PP_SIZE}"
echo "  GPU Mem Util:    ${INPUT_GPU_MEM}"
echo "  Max Model Len:   ${INPUT_MAX_LEN}"
if $CONTAINER_PROXY_ENABLED; then
    echo "  컨테이너 프록시: ${CONTAINER_HTTP_PROXY}"
else
    echo "  컨테이너 프록시: 없음"
fi
echo "============================================"

# ============================================================
# 로컬 포트 충돌 확인
# ============================================================
echo ""
echo "--------------------------------------------"
echo " 포트 사용 현황 (이 서버)"
echo "--------------------------------------------"

LOCAL_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$')
LOCAL_ROLE=""
if echo "${LOCAL_IPS}" | grep -qxF "${INPUT_HEAD_IP}"; then
    LOCAL_ROLE="head"
elif [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
    for i in $(seq 0 $((${#WORKER_IPS[@]} - 1))); do
        if echo "${LOCAL_IPS}" | grep -qxF "${WORKER_IPS[$i]}"; then
            LOCAL_ROLE="worker-$((i + 1))"
            break
        fi
    done
fi

PORT_CONFLICT=false
if [[ "${LOCAL_ROLE}" == "head" ]]; then
    info "이 서버 역할: Head (${INPUT_HEAD_IP})"
    for port in $(echo "${!HEAD_PORTS[@]}" | tr ' ' '\n' | sort -n); do
        if check_port_in_use "${port}"; then
            warn "  포트 ${port} (${HEAD_PORTS[$port]}) — 이미 사용 중"
            PORT_CONFLICT=true
        else
            ok "  포트 ${port} (${HEAD_PORTS[$port]}) — 사용 가능"
        fi
    done
elif [[ "${LOCAL_ROLE}" == worker-* ]]; then
    info "이 서버 역할: ${LOCAL_ROLE}"
    # Worker는 Ray가 head에 join하므로 별도 listen 포트 없음
    ok "  Worker는 별도 listen 포트 없음"
else
    warn "이 서버 IP가 클러스터 설정에 포함되지 않았습니다."
    info "Head 포트 기준으로 확인합니다."
    for port in $(echo "${!HEAD_PORTS[@]}" | tr ' ' '\n' | sort -n); do
        if check_port_in_use "${port}"; then
            warn "  포트 ${port} (${HEAD_PORTS[$port]}) — 이미 사용 중"
            PORT_CONFLICT=true
        else
            ok "  포트 ${port} (${HEAD_PORTS[$port]}) — 사용 가능"
        fi
    done
fi

if $PORT_CONFLICT; then
    echo ""
    warn "충돌하는 포트가 있습니다. 기동 전에 해당 프로세스를 종료하세요."
fi

echo "============================================"
read -rp "위 설정으로 파일을 생성하시겠습니까? [Y/n]: " confirm_gen
if [[ "${confirm_gen,,}" == "n" ]]; then
    echo "중단합니다."
    exit 0
fi

# ############################################################
#  파일 생성
# ############################################################
info "generated/ 디렉토리 초기화..."
rm -rf "${GENERATED_DIR}"

# --- env.proxy 생성 함수 ---
generate_env_proxy() {
    local dir="$1"
    if $CONTAINER_PROXY_ENABLED; then
        cat > "${dir}/env.proxy" <<EOF
http_proxy=${CONTAINER_HTTP_PROXY}
HTTP_PROXY=${CONTAINER_HTTP_PROXY}
https_proxy=${CONTAINER_HTTPS_PROXY}
HTTPS_PROXY=${CONTAINER_HTTPS_PROXY}
no_proxy=${CONTAINER_NO_PROXY}
NO_PROXY=${CONTAINER_NO_PROXY}
EOF
    else
        # 빈 파일 (docker-compose env_file 참조 에러 방지)
        touch "${dir}/env.proxy"
    fi
}

# ============================================================
# cluster.conf
# ============================================================
mkdir -p "${GENERATED_DIR}"
{
    echo "HEAD_IP=${INPUT_HEAD_IP}"
    echo "WORKER_COUNT=${NUM_WORKERS}"
    for i in $(seq 1 "${NUM_WORKERS}"); do
        echo "WORKER_${i}_IP=${WORKER_IPS[$((i-1))]}"
    done
} > "${GENERATED_DIR}/cluster.conf"
ok "cluster.conf 생성"

# ============================================================
# Head
# ============================================================
HEAD_DIR="${GENERATED_DIR}/head"
mkdir -p "${HEAD_DIR}"

render_template \
    "${TEMPLATE_DIR}/head-env.template" \
    "${HEAD_DIR}/.env" \
    "HF_TOKEN=${INPUT_HF_TOKEN}" \
    "VLLM_API_KEY=${INPUT_VLLM_API_KEY}" \
    "HEAD_IP=${INPUT_HEAD_IP}" \
    "NIC_NAME=${INPUT_NIC_NAME}" \
    "NCCL_IB_DISABLE=${INPUT_NCCL_IB}" \
    "SSL_CERT_FILE=${INPUT_SSL_CERT}"

render_template \
    "${TEMPLATE_DIR}/head-docker-compose.template" \
    "${HEAD_DIR}/docker-compose.yml" \
    "CUDA_VISIBLE_DEVICES=${CUDA_DEVICES}" \
    "SHM_SIZE=${INPUT_SHM_SIZE}" \
    "TOTAL_GPU_COUNT=${TOTAL_GPU_COUNT}" \
    "MODEL_ID=${INPUT_MODEL_ID}" \
    "SERVED_MODEL_NAME=${INPUT_SERVED_NAME}" \
    "TENSOR_PARALLEL_SIZE=${INPUT_TP_SIZE}" \
    "PIPELINE_PARALLEL_SIZE=${INPUT_PP_SIZE}" \
    "GPU_MEMORY_UTILIZATION=${INPUT_GPU_MEM}" \
    "MAX_MODEL_LEN=${INPUT_MAX_LEN}" \
    "DATA_DIR=${INPUT_DATA_DIR}"

cp "${SCRIPT_DIR}/nginx.conf" "${HEAD_DIR}/nginx.conf"
generate_env_proxy "${HEAD_DIR}"
ok "generated/head/ 생성 완료"

# ============================================================
# Workers
# ============================================================
for i in $(seq 1 "${NUM_WORKERS}"); do
    WORKER_DIR="${GENERATED_DIR}/worker-${i}"
    mkdir -p "${WORKER_DIR}"

    render_template \
        "${TEMPLATE_DIR}/worker-env.template" \
        "${WORKER_DIR}/.env" \
        "HF_TOKEN=${INPUT_HF_TOKEN}" \
        "HEAD_IP=${INPUT_HEAD_IP}" \
        "WORKER_IP=${WORKER_IPS[$((i-1))]}" \
        "NIC_NAME=${INPUT_NIC_NAME}" \
        "NCCL_IB_DISABLE=${INPUT_NCCL_IB}" \
        "SSL_CERT_FILE=${INPUT_SSL_CERT}"

    render_template \
        "${TEMPLATE_DIR}/worker-docker-compose.template" \
        "${WORKER_DIR}/docker-compose.yml" \
        "CUDA_VISIBLE_DEVICES=${CUDA_DEVICES}" \
        "SHM_SIZE=${INPUT_SHM_SIZE}" \
        "DATA_DIR=${INPUT_DATA_DIR}"

    generate_env_proxy "${WORKER_DIR}"
    ok "generated/worker-${i}/ 생성 완료"
done

# ============================================================
# 완료
# ============================================================
echo ""
echo "============================================"
echo " 파일 생성 완료"
echo "============================================"
echo ""
echo "  ${GENERATED_DIR}/"
echo "    cluster.conf"
echo "    head/"
echo "      .env, docker-compose.yml, nginx.conf, env.proxy"
for i in $(seq 1 "${NUM_WORKERS}"); do
    echo "    worker-${i}/"
    echo "      .env, docker-compose.yml, env.proxy"
done
echo ""

echo "--------------------------------------------"
echo " 배포"
echo "--------------------------------------------"
echo ""
read -rp "각 서버에 파일을 배포하시겠습니까? [Y/n]: " confirm_deploy
if [[ "${confirm_deploy,,}" == "n" ]]; then
    echo ""
    echo "  수동 배포 명령어:"
    echo ""
    echo "  Head 서버 (${INPUT_HEAD_IP}):"
    echo "    scp -r generated/head/ ${INPUT_HEAD_IP}:<배포경로>/"
    echo "    scp generated/cluster.conf ${INPUT_HEAD_IP}:<배포경로>/generated/"
    echo "    scp up.sh down.sh _detect-role.sh ${INPUT_HEAD_IP}:<배포경로>/"
    echo ""
    for i in $(seq 1 "${NUM_WORKERS}"); do
        echo "  Worker-${i} 서버 (${WORKER_IPS[$((i-1))]}):"
        echo "    scp -r generated/worker-${i}/ ${WORKER_IPS[$((i-1))]}:<배포경로>/"
        echo "    scp generated/cluster.conf ${WORKER_IPS[$((i-1))]}:<배포경로>/generated/"
        echo "    scp up.sh down.sh _detect-role.sh ${WORKER_IPS[$((i-1))]}:<배포경로>/"
        echo ""
    done
    ok "generate 완료 (배포 생략)"
    exit 0
fi

read -rp "원격 배포 경로 [기본값: ~/vllm-docker-corp]: " INPUT_DEPLOY_PATH
INPUT_DEPLOY_PATH="${INPUT_DEPLOY_PATH:-~/vllm-docker-corp}"

# SSH 사용자 (기본: 현재 사용자)
read -rp "SSH 사용자 [기본값: $(whoami)]: " INPUT_SSH_USER
INPUT_SSH_USER="${INPUT_SSH_USER:-$(whoami)}"

DEPLOY_FAILED=false

# --- 로컬 IP 판별 ---
is_local_ip() {
    echo "${LOCAL_IPS}" | grep -qxF "$1"
}

# --- 서버 배포 함수 ---
deploy_to_server() {
    local ip="$1"
    local role="$2"       # head 또는 worker-N
    local src_dir="$3"    # generated/head 또는 generated/worker-N

    local dest="${INPUT_DEPLOY_PATH}"

    if is_local_ip "${ip}"; then
        # 로컬 서버 — cp 사용
        info "배포 중 (로컬): ${role} (${ip}) → ${dest}/"

        mkdir -p "${dest}/generated" \
            || { error "  디렉토리 생성 실패: ${dest}/generated"; DEPLOY_FAILED=true; return 1; }

        cp -r "${src_dir}/." "${dest}/generated/${role}/" \
            && ok "  ${role}/ 배포 완료" \
            || { error "  ${role}/ 배포 실패"; DEPLOY_FAILED=true; return 1; }

        cp "${GENERATED_DIR}/cluster.conf" "${dest}/generated/" \
            && ok "  cluster.conf 배포 완료" \
            || { error "  cluster.conf 배포 실패"; DEPLOY_FAILED=true; return 1; }

        cp "${SCRIPT_DIR}/up.sh" "${SCRIPT_DIR}/down.sh" "${SCRIPT_DIR}/_detect-role.sh" \
            "${dest}/" \
            && ok "  스크립트 배포 완료" \
            || { error "  스크립트 배포 실패"; DEPLOY_FAILED=true; return 1; }
    else
        # 원격 서버 — scp 사용
        local remote="${INPUT_SSH_USER}@${ip}"
        info "배포 중 (원격): ${role} (${ip}) → ${dest}/"

        if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${remote}" "mkdir -p ${dest}/generated" 2>/dev/null; then
            error "  SSH 연결 실패: ${remote}"
            DEPLOY_FAILED=true
            return 1
        fi

        scp -r -o ConnectTimeout=10 "${src_dir}/" "${remote}:${dest}/generated/${role}/" 2>/dev/null \
            && ok "  ${role}/ 배포 완료" \
            || { error "  ${role}/ 배포 실패"; DEPLOY_FAILED=true; return 1; }

        scp -o ConnectTimeout=10 "${GENERATED_DIR}/cluster.conf" "${remote}:${dest}/generated/" 2>/dev/null \
            && ok "  cluster.conf 배포 완료" \
            || { error "  cluster.conf 배포 실패"; DEPLOY_FAILED=true; return 1; }

        scp -o ConnectTimeout=10 \
            "${SCRIPT_DIR}/up.sh" "${SCRIPT_DIR}/down.sh" "${SCRIPT_DIR}/_detect-role.sh" \
            "${remote}:${dest}/" 2>/dev/null \
            && ok "  스크립트 배포 완료" \
            || { error "  스크립트 배포 실패"; DEPLOY_FAILED=true; return 1; }
    fi
}

echo ""

# Head 배포
deploy_to_server "${INPUT_HEAD_IP}" "head" "${HEAD_DIR}"

# Worker 배포
for i in $(seq 1 "${NUM_WORKERS}"); do
    deploy_to_server "${WORKER_IPS[$((i-1))]}" "worker-${i}" "${GENERATED_DIR}/worker-${i}"
done

echo ""
if $DEPLOY_FAILED; then
    warn "일부 배포에 실패했습니다. 위 에러를 확인하세요."
else
    ok "모든 서버 배포 완료"
fi

echo ""
echo "--------------------------------------------"
echo " 기동 순서"
echo "--------------------------------------------"
echo ""
echo "  1) 모든 Worker 서버에서 먼저:  bash up.sh"
echo "  2) 그 다음 Head 서버에서:      bash up.sh"
echo ""
ok "generate 완료"
