# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Multi-node vLLM + Ollama serving infrastructure using Docker Compose. Ray 기반 분산 GPU 실행으로 1 Head + N Worker 구성을 지원한다. Head에는 Ollama(CPU) + Nginx 리버스 프록시도 함께 배포된다.

## Architecture

**N-server topology (1 Head + N Workers):**
- **Head:** Ray head + vLLM OpenAI API (port 8000) + Ollama CPU (port 11434) + Nginx (11435→vLLM, 11436→Ollama)
- **Worker(s):** Ray worker — Head 클러스터에 join

All containers use `network_mode: host` for Ray multi-node NCCL communication.

## Scripts

| 스크립트 | 용도 | 실행 권한 |
|---------|------|----------|
| `init-ubuntu.sh` | OS 초기 설정 (프록시, Docker, NVIDIA Toolkit) | `sudo` |
| `generate.sh` | 템플릿 → `generated/` 설정 파일 생성 | 일반 |
| `up.sh` | 현재 서버 IP 감지 → 역할에 맞는 서비스 기동 | 일반 |
| `down.sh` | 현재 서버 IP 감지 → 서비스 중지 | 일반 |
| `_detect-role.sh` | up/down 공용 — IP 기반 역할 감지 (source용) | — |

## Setup Flow

```
1. 모든 서버: sudo bash init-ubuntu.sh     # OS 설정 + Docker/NVIDIA 설치
2. 아무 서버: bash generate.sh              # 대화형으로 클러스터 설정 생성
3. 각 서버에 generated/ 파일 배포 (scp)
4. Worker 서버 먼저: bash up.sh
5. Head 서버 나중:   bash up.sh
```

## Generated Directory Structure

`generate.sh` 실행 후 생성:

```
generated/
  cluster.conf              # HEAD_IP, WORKER_COUNT, WORKER_N_IP
  head/
    .env                    # Head 환경변수
    docker-compose.yml      # vLLM + Ollama + Nginx
    nginx.conf              # Reverse proxy
    env.proxy               # 컨테이너 프록시
  worker-1/
    .env                    # Worker-1 환경변수
    docker-compose.yml      # Ray worker
    env.proxy
  worker-N/
    ...
```

## Template System

`templates/` 디렉토리에 `{{PLACEHOLDER}}` 문법 사용. `generate.sh`가 유저 입력을 받아 치환.

| 템플릿 | 대상 |
|--------|------|
| `templates/head-env.template` | `generated/head/.env` |
| `templates/head-docker-compose.template` | `generated/head/docker-compose.yml` |
| `templates/worker-env.template` | `generated/worker-N/.env` |
| `templates/worker-docker-compose.template` | `generated/worker-N/docker-compose.yml` |

## IP Auto-Detection (up.sh / down.sh)

`_detect-role.sh`가 `hostname -I`로 로컬 IP 수집 → `generated/cluster.conf`와 매칭하여 head/worker-N 자동 판별. 매칭 실패 시 에러와 함께 IP 목록 출력.

## Key Files

- `nginx.conf` — Reverse proxy config (SSE streaming 지원). `generate.sh`가 `generated/head/`로 복사.
- `env.proxy` — Docker 컨테이너용 프록시 환경변수. `generate.sh`에서 생성.
- `.gitignore` — `generated/` 디렉토리 제외.
