# vllm-docker-corp

Multi-node vLLM + Ollama 서빙 인프라. Ray 기반 분산 GPU 실행으로 **1 Head + N Worker** 구성을 지원한다.

## Architecture

```
                          ┌─────────────────────────────────┐
                          │  Head Server                    │
                          │  ┌───────────┐  ┌────────────┐  │
  :11435 (vLLM) ─────────┤  │   Nginx   │  │  Ollama    │  │
  :11436 (Ollama) ────────┤  │  (Router) │  │  (CPU)     │  │
                          │  └─────┬─────┘  └────────────┘  │
                          │        │                         │
                          │  ┌─────▼─────────────────────┐  │
                          │  │  vLLM + Ray Head           │  │
                          │  │  :8000 (OpenAI API)        │  │
                          │  │  :6379 (Ray GCS)           │  │
                          │  └───────────────────────────┘  │
                          └──────────────┬──────────────────┘
                                         │ Ray Cluster
                       ┌─────────────────┼─────────────────┐
                       │                 │                  │
                ┌──────▼──────┐   ┌──────▼──────┐   ┌──────▼──────┐
                │  Worker-1   │   │  Worker-2   │   │  Worker-N   │
                │  Ray Worker │   │  Ray Worker │   │  Ray Worker │
                │  (GPU x M)  │   │  (GPU x M)  │   │  (GPU x M)  │
                └─────────────┘   └─────────────┘   └─────────────┘
```

- 모든 컨테이너는 `network_mode: host`로 동작 (Ray 멀티노드 NCCL 통신)
- Head: vLLM(OpenAI 호환 API) + Ollama(CPU) + Nginx(리버스 프록시)
- Worker: Ray worker로 Head 클러스터에 join

## Quick Start

### 1. 서버 초기 설정 (모든 서버에서 각각 실행)

```bash
sudo bash init-ubuntu.sh
```

프록시 설정(apt, pip, git, docker), Docker Engine, Docker Compose, NVIDIA Container Toolkit을 설치한다.

### 2. 클러스터 설정 파일 생성 (아무 서버에서 1회 실행)

```bash
bash generate.sh
```

대화형으로 다음 항목을 입력받아 `generated/` 디렉토리에 설정 파일을 생성한다:

| 항목 | 설명 |
|------|------|
| 클러스터 서버 수 | Head 포함 전체 서버 수 |
| HEAD_IP / WORKER_IP | 각 서버의 IP |
| NIC_NAME | 노드 간 통신 NIC (자동 감지) |
| HF_TOKEN | Hugging Face 토큰 |
| VLLM_API_KEY | vLLM API 인증 키 |
| 모델 설정 | 모델 ID, TP/PP size, GPU 메모리 등 |
| 프록시 | 컨테이너 프록시 (env.proxy) |

생성 결과:

```
generated/
  cluster.conf          # 클러스터 IP 매핑 정보
  head/
    .env                # Head 환경변수
    docker-compose.yml  # vLLM + Ollama + Nginx
    nginx.conf          # 리버스 프록시
    env.proxy           # 컨테이너 프록시
  worker-1/
    .env
    docker-compose.yml
    env.proxy
  worker-N/
    ...
```

### 3. 파일 배포

생성된 파일을 각 서버에 배포한다:

```bash
# Head 서버
scp -r generated/head/ <HEAD_IP>:<배포경로>/generated/
scp generated/cluster.conf <HEAD_IP>:<배포경로>/generated/
scp up.sh down.sh _detect-role.sh <HEAD_IP>:<배포경로>/

# Worker 서버 (각각)
scp -r generated/worker-N/ <WORKER_IP>:<배포경로>/generated/
scp generated/cluster.conf <WORKER_IP>:<배포경로>/generated/
scp up.sh down.sh _detect-role.sh <WORKER_IP>:<배포경로>/
```

### 4. 서비스 기동

**Worker 먼저, Head 나중** 순서로 기동한다. `up.sh`가 로컬 IP를 감지하여 역할을 자동 판별한다.

```bash
# 모든 Worker 서버에서 먼저
bash up.sh

# Head 서버에서 나중
bash up.sh
```

Head는 클러스터에 전체 GPU가 감지될 때까지 최대 600초 대기한 후 vLLM 서버를 시작한다.

### 5. 서비스 중지

```bash
bash down.sh
```

## Verification

```bash
# Ray 클러스터 상태
docker exec vllm-gpu-all ray status

# vLLM 모델 확인 (Direct)
curl http://localhost:8000/v1/models

# vLLM 모델 확인 (Nginx 경유)
curl http://localhost:11435/v1/models

# 추론 테스트
curl -X POST http://localhost:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm-4.7",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64
  }'
```

## Scripts

| 스크립트 | 용도 |
|---------|------|
| `init-ubuntu.sh` | Ubuntu 24.04 OS 초기 설정 (프록시, Docker, NVIDIA Toolkit) |
| `generate.sh` | 대화형 설정 수집 → `generated/` 파일 생성 |
| `up.sh` | IP 자동감지 → 역할에 맞는 `docker compose up -d` |
| `down.sh` | IP 자동감지 → `docker compose down` |
| `_detect-role.sh` | up/down 공용 IP 기반 역할 감지 헬퍼 |

## Troubleshooting

**GPU가 전체 수로 안 잡히는 경우:**
- 양쪽 `.env`의 `HEAD_IP`가 동일한지 확인
- `VLLM_HOST_IP`가 각 서버의 실제 IP인지 확인
- `NIC_NAME`이 실제 인터페이스명인지 확인 (`ip addr`)
- 방화벽에서 포트 오픈 확인 (6379, 8000, 8265, 10001-10100)

**NCCL 타임아웃:**
- `NCCL_SOCKET_IFNAME`(=NIC_NAME) 확인
- `docker exec vllm-gpu-all ray status`로 양쪽 노드 IP 확인

**OOM 발생 시:**
- `generate.sh` 재실행하여 `--max-model-len` 축소 (8192 → 16384 → 32768)
- `--gpu-memory-utilization` 값 하향 (0.85)

**up.sh에서 IP 매칭 실패:**
- `hostname -I`로 로컬 IP 확인
- `generated/cluster.conf`의 IP와 비교

## Requirements

- Ubuntu 24.04
- NVIDIA GPU + Driver
- Docker Engine + Docker Compose Plugin
- NVIDIA Container Toolkit
- 서버 간 네트워크 통신 (포트: 6379, 8000, 8265, 10001-10100)
