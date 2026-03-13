#!/bin/bash
# ============================================================
# init-ubuntu.sh — Ubuntu 24.04 서버 초기 설정 스크립트
# ============================================================
# 용도: OS 레벨 사전 환경 구성 (양쪽 서버에서 각각 1회 실행)
#   - 프록시 설정 (apt, pip, git, docker, 시스템 환경변수)
#   - Docker Engine + Docker Compose 플러그인 설치
#   - NVIDIA Container Toolkit 설치
# ============================================================
set -euo pipefail

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
# root 권한 확인
# ============================================================
if [[ $EUID -ne 0 ]]; then
    error "이 스크립트는 root 권한으로 실행해야 합니다."
    echo "  sudo bash $0"
    exit 1
fi

# ############################################################
#  Phase 1 — 프록시 설정
# ############################################################
echo ""
echo "============================================"
echo " Phase 1. 프록시 설정"
echo "============================================"
echo ""

# 프록시 URL 유효성 검증
validate_proxy_url() {
    local url="$1"
    if [[ -z "${url}" ]]; then
        return 0  # 빈 값은 허용 (프록시 미사용)
    fi
    if [[ "${url}" =~ ^https?:// ]]; then
        return 0
    fi
    return 1
}

# 대소문자 환경변수 모두 확인
_DETECTED_HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
_DETECTED_HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
_DETECTED_NO_PROXY="${NO_PROXY:-${no_proxy:-}}"

# 감지된 프록시가 유효하지 않으면 무시
if [[ -n "${_DETECTED_HTTP_PROXY}" ]] && ! validate_proxy_url "${_DETECTED_HTTP_PROXY}"; then
    warn "환경변수의 HTTP_PROXY 값이 유효하지 않습니다: ${_DETECTED_HTTP_PROXY}"
    _DETECTED_HTTP_PROXY=""
fi
if [[ -n "${_DETECTED_HTTPS_PROXY}" ]] && ! validate_proxy_url "${_DETECTED_HTTPS_PROXY}"; then
    warn "환경변수의 HTTPS_PROXY 값이 유효하지 않습니다: ${_DETECTED_HTTPS_PROXY}"
    _DETECTED_HTTPS_PROXY=""
fi

if [[ -n "${_DETECTED_HTTP_PROXY}" ]]; then
    HTTP_PROXY="${_DETECTED_HTTP_PROXY}"
    info "기존 HTTP_PROXY 감지: ${HTTP_PROXY}"
    read -rp "이 값을 사용하시겠습니까? [Y/n]: " use_existing
    if [[ "${use_existing,,}" == "n" ]]; then
        read -rp "HTTP_PROXY  (예: http://proxy.example.com:8080): " HTTP_PROXY
    fi
else
    read -rp "HTTP_PROXY  (예: http://proxy.example.com:8080, 없으면 Enter): " HTTP_PROXY
fi

# 입력된 값 검증
if [[ -n "${HTTP_PROXY}" ]] && ! validate_proxy_url "${HTTP_PROXY}"; then
    error "유효하지 않은 프록시 URL: ${HTTP_PROXY}"
    error "http:// 또는 https:// 로 시작해야 합니다."
    exit 1
fi

HTTPS_PROXY="${_DETECTED_HTTPS_PROXY:-${HTTP_PROXY}}"
if [[ -n "${HTTP_PROXY}" ]]; then
    read -rp "HTTPS_PROXY [기본값: ${HTTPS_PROXY}]: " input
    HTTPS_PROXY="${input:-${HTTPS_PROXY}}"
    if ! validate_proxy_url "${HTTPS_PROXY}"; then
        error "유효하지 않은 프록시 URL: ${HTTPS_PROXY}"
        exit 1
    fi
fi

DEFAULT_NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local"
if [[ -n "${_DETECTED_NO_PROXY}" ]]; then
    NO_PROXY="${_DETECTED_NO_PROXY}"
    info "기존 NO_PROXY 감지: ${NO_PROXY}"
    read -rp "이 값을 사용하시겠습니까? [Y/n]: " use_existing_no
    if [[ "${use_existing_no,,}" == "n" ]]; then
        echo "  기본값: ${DEFAULT_NO_PROXY}"
        read -rp "NO_PROXY: " NO_PROXY
    fi
else
    echo "  기본값: ${DEFAULT_NO_PROXY}"
    read -rp "NO_PROXY [기본값 사용하려면 Enter]: " NO_PROXY
    NO_PROXY="${NO_PROXY:-${DEFAULT_NO_PROXY}}"
fi

PROXY_ENABLED=false
if [[ -n "${HTTP_PROXY}" ]]; then
    PROXY_ENABLED=true
    # 이후 curl 등 도구가 즉시 프록시를 사용할 수 있도록 선 적용
    export http_proxy="${HTTP_PROXY}" HTTP_PROXY="${HTTP_PROXY}"
    export https_proxy="${HTTPS_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}"
    export no_proxy="${NO_PROXY}" NO_PROXY="${NO_PROXY}"
fi

echo ""
echo "--------------------------------------------"
echo " 프록시 설정 요약"
echo "--------------------------------------------"
if $PROXY_ENABLED; then
    echo "  HTTP_PROXY  = ${HTTP_PROXY}"
    echo "  HTTPS_PROXY = ${HTTPS_PROXY}"
    echo "  NO_PROXY    = ${NO_PROXY}"
else
    echo "  프록시 없이 진행합니다."
fi
echo "--------------------------------------------"
read -rp "계속 진행하시겠습니까? [Y/n]: " confirm
if [[ "${confirm,,}" == "n" ]]; then
    echo "중단합니다."
    exit 0
fi

# --- 1. 시스템 환경변수 ---
info "1/7 시스템 환경변수 프록시 설정..."
if $PROXY_ENABLED; then
    sed -i '/^[Hh][Tt][Tt][Pp]_[Pp][Rr][Oo][Xx][Yy]=/d'  /etc/environment
    sed -i '/^[Hh][Tt][Tt][Pp][Ss]_[Pp][Rr][Oo][Xx][Yy]=/d' /etc/environment
    sed -i '/^[Nn][Oo]_[Pp][Rr][Oo][Xx][Yy]=/d'           /etc/environment
    cat >> /etc/environment <<EOF
http_proxy=${HTTP_PROXY}
HTTP_PROXY=${HTTP_PROXY}
https_proxy=${HTTPS_PROXY}
HTTPS_PROXY=${HTTPS_PROXY}
no_proxy=${NO_PROXY}
NO_PROXY=${NO_PROXY}
EOF
    export http_proxy="${HTTP_PROXY}" HTTP_PROXY="${HTTP_PROXY}"
    export https_proxy="${HTTPS_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}"
    export no_proxy="${NO_PROXY}" NO_PROXY="${NO_PROXY}"
    ok "/etc/environment 프록시 설정 완료"
else
    ok "프록시 없음 — 건너뜀"
fi

# --- 2. APT ---
info "2/7 APT 프록시 설정..."
APT_PROXY_CONF="/etc/apt/apt.conf.d/99proxy"
if $PROXY_ENABLED; then
    cat > "${APT_PROXY_CONF}" <<EOF
Acquire::http::Proxy "${HTTP_PROXY}";
Acquire::https::Proxy "${HTTPS_PROXY}";
EOF
    ok "${APT_PROXY_CONF} 생성 완료"
else
    rm -f "${APT_PROXY_CONF}"
    ok "프록시 없음 — APT 프록시 설정 제거"
fi

# --- 3. pip ---
info "3/7 pip 프록시 설정..."
if $PROXY_ENABLED; then
    mkdir -p /etc/pip
    cat > /etc/pip/pip.conf <<EOF
[global]
proxy = ${HTTP_PROXY}
trusted-host = pypi.org
               pypi.python.org
               files.pythonhosted.org
EOF
    SUDO_USER_HOME="${SUDO_USER:+$(eval echo ~"${SUDO_USER}")}"
    if [[ -n "${SUDO_USER_HOME}" && -d "${SUDO_USER_HOME}" ]]; then
        mkdir -p "${SUDO_USER_HOME}/.config/pip"
        cp /etc/pip/pip.conf "${SUDO_USER_HOME}/.config/pip/pip.conf"
        chown -R "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${SUDO_USER_HOME}/.config/pip"
    fi
    ok "pip 프록시 설정 완료"
else
    ok "프록시 없음 — 건너뜀"
fi

# --- 4. git ---
info "4/7 git 프록시 설정..."
if $PROXY_ENABLED; then
    git config --system http.proxy  "${HTTP_PROXY}"
    git config --system https.proxy "${HTTPS_PROXY}"
    ok "git 시스템 프록시 설정 완료"
else
    git config --system --unset http.proxy  2>/dev/null || true
    git config --system --unset https.proxy 2>/dev/null || true
    ok "프록시 없음 — git 프록시 제거"
fi

# ############################################################
#  Phase 2 — Docker / NVIDIA 설치
# ############################################################
echo ""
echo "============================================"
echo " Phase 2. Docker / NVIDIA Toolkit 설치"
echo "============================================"
echo ""

# --- 5. Docker Engine ---
info "5/7 Docker Engine 설치..."
if command -v docker &>/dev/null; then
    ok "Docker 이미 설치됨: $(docker --version)"
else
    info "Docker 설치 시작..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 \
               containerd runc podman-docker; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    ARCH=$(dpkg --print-architecture)
    CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME}")
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin

    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "${SUDO_USER}"
        info "${SUDO_USER} 사용자를 docker 그룹에 추가 (재로그인 필요)"
    fi
    systemctl enable docker
    systemctl start docker
    ok "Docker 설치 완료: $(docker --version)"
fi

if docker compose version &>/dev/null; then
    ok "Docker Compose: $(docker compose version --short)"
else
    error "docker compose 플러그인이 설치되지 않았습니다."
    exit 1
fi

# --- 6. Docker 데몬 프록시 ---
info "6/7 Docker 데몬 프록시 설정..."
DOCKER_SERVICE_DIR="/etc/systemd/system/docker.service.d"
if $PROXY_ENABLED; then
    mkdir -p "${DOCKER_SERVICE_DIR}"
    cat > "${DOCKER_SERVICE_DIR}/http-proxy.conf" <<EOF
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="NO_PROXY=${NO_PROXY}"
EOF
    DOCKER_CONFIG_DIR="/root/.docker"
    mkdir -p "${DOCKER_CONFIG_DIR}"
    if [[ -f "${DOCKER_CONFIG_DIR}/config.json" ]]; then
        EXISTING=$(cat "${DOCKER_CONFIG_DIR}/config.json")
    else
        EXISTING="{}"
    fi
    echo "${EXISTING}" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg['proxies'] = {
    'default': {
        'httpProxy':  '${HTTP_PROXY}',
        'httpsProxy': '${HTTPS_PROXY}',
        'noProxy':    '${NO_PROXY}'
    }
}
json.dump(cfg, sys.stdout, indent=2)
" > "${DOCKER_CONFIG_DIR}/config.json"
    if [[ -n "${SUDO_USER:-}" ]]; then
        USER_DOCKER_DIR="$(eval echo ~"${SUDO_USER}")/.docker"
        mkdir -p "${USER_DOCKER_DIR}"
        cp "${DOCKER_CONFIG_DIR}/config.json" "${USER_DOCKER_DIR}/config.json"
        chown -R "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${USER_DOCKER_DIR}"
    fi
    systemctl daemon-reload
    systemctl restart docker
    ok "Docker 프록시 설정 완료"
else
    rm -f "${DOCKER_SERVICE_DIR}/http-proxy.conf"
    if [[ -d "${DOCKER_SERVICE_DIR}" ]] && [[ -z "$(ls -A "${DOCKER_SERVICE_DIR}")" ]]; then
        rmdir "${DOCKER_SERVICE_DIR}"
    fi
    systemctl daemon-reload
    systemctl restart docker
    ok "프록시 없음 — Docker 프록시 제거"
fi

# --- 7. NVIDIA Container Toolkit ---
info "7/7 NVIDIA Container Toolkit 설치..."
if dpkg -l nvidia-container-toolkit &>/dev/null; then
    ok "NVIDIA Container Toolkit 이미 설치됨"
else
    if ! command -v nvidia-smi &>/dev/null; then
        warn "nvidia-smi를 찾을 수 없습니다. NVIDIA 드라이버가 먼저 설치되어야 합니다."
        warn "NVIDIA Container Toolkit 설치를 건너뜁니다."
    else
        info "NVIDIA Container Toolkit 설치 시작..."
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update -y
        apt-get install -y nvidia-container-toolkit
        nvidia-ctk runtime configure --runtime=docker
        systemctl restart docker
        ok "NVIDIA Container Toolkit 설치 완료"
    fi
fi

# ############################################################
#  최종 확인
# ############################################################
echo ""
echo "============================================"
echo " 설치 완료 — 상태 확인"
echo "============================================"
echo ""

echo "  Docker:          $(docker --version 2>/dev/null || echo 'NOT INSTALLED')"
echo "  Docker Compose:  $(docker compose version --short 2>/dev/null || echo 'NOT INSTALLED')"
echo "  NVIDIA Driver:   $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo 'NOT INSTALLED')"
echo "  NVIDIA Toolkit:  $(dpkg -l nvidia-container-toolkit 2>/dev/null | grep -oP '\d+\.\d+\.\d+-\d+' | head -1 || echo 'NOT INSTALLED')"
echo ""

if $PROXY_ENABLED; then
    echo "  프록시 설정 위치:"
    echo "    시스템:  /etc/environment"
    echo "    APT:     ${APT_PROXY_CONF}"
    echo "    pip:     /etc/pip/pip.conf"
    echo "    git:     git config --system --list | grep proxy"
    echo "    Docker:  ${DOCKER_SERVICE_DIR}/http-proxy.conf"
    echo ""
fi

if docker info 2>/dev/null | grep -q "Runtimes.*nvidia"; then
    ok "Docker NVIDIA 런타임 활성화 확인됨"
else
    warn "Docker NVIDIA 런타임이 감지되지 않음 — GPU 컨테이너 실행 전 확인 필요"
fi

echo ""
if [[ -n "${SUDO_USER:-}" ]]; then
    warn "docker 그룹 적용을 위해 재로그인하세요: su - ${SUDO_USER}"
fi
echo ""
ok "서버 초기화 완료. 다음 단계: bash generate.sh"
