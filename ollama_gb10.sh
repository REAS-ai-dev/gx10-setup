#!/bin/bash

# 發生錯誤、使用未定義變數或管線失敗時立即停止
set -Eeuo pipefail

# 終端機顏色（輸出被導向檔案／管線時自動關閉，避免 log 裡出現亂碼跳脫字元）
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

trap 'echo -e "${RED}部署失敗：第 ${LINENO} 行執行錯誤。${NC}" >&2' ERR

# 腳本本身所在目錄（不是執行時的當前目錄）：部署報告會寫在這裡，
# 不管是直接 bash 執行、cd 進去執行、還是雙擊 .desktop 啟動器都一樣。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 標註名稱（選填，例如公司或機器名稱，會寫進最後的部署報告；可用 CUSTOMER_NAME 環境變數跳過互動輸入）
if [ -z "${CUSTOMER_NAME:-}" ] && [ -t 0 ]; then
    read -r -p "標註名稱（選填，例如公司或機器名稱，直接按 Enter 跳過）： " CUSTOMER_NAME
fi
CUSTOMER_NAME="${CUSTOMER_NAME:-}"

echo "=================================================="
echo "開始部署：Ollama GB10 專用單實例（NVIDIA DGX Spark / ASUS GX10）"
echo "=================================================="

# ------------------------------
# 基本設定
# ------------------------------

OLLAMA_PORT=11434

# 可自行修改模型名稱（bge-m3 為目前驗證過、NeuroSme 相容的 1024 維 embedding 模型）
CHAT_MODEL="${CHAT_MODEL:-gemma4:26b}"
EMBED_MODEL="${EMBED_MODEL:-bge-m3}"

# GB10 實測上限為 3 路並發（設 4 有 segfault 回報，見 ollama#15318）
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-3}"

ARCH="$(uname -m)"

# ------------------------------
# 前置檢查
# ------------------------------

if ! command -v sudo >/dev/null 2>&1; then
    echo -e "${RED}錯誤：找不到 sudo。${NC}"
    exit 1
fi

case "$ARCH" in
    aarch64|arm64)
        ;;
    *)
        echo -e "${YELLOW}警告：此腳本針對 GB10（ARM64）調校，偵測到 $ARCH。${NC}"
        echo "仍會繼續，但 cuda_v13 相關設定可能不適用於這台機器。"
        ;;
esac

echo "CPU 架構：$ARCH"

# ------------------------------
# 1. 安裝共用依賴
# ------------------------------

echo "步驟 1/7：更新系統並安裝共用套件..."

sudo apt update
sudo apt install -y curl python3

# ------------------------------
# 2. 檢查 NVIDIA 驅動 / CUDA
# ------------------------------

echo "步驟 2/7：檢查 GPU 與驅動環境..."

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo -e "${RED}錯誤：找不到 nvidia-smi。${NC}"
    echo "本腳本僅支援 NVIDIA GB10（DGX Spark / ASUS GX10），請先確認驅動已安裝。"
    exit 1
fi

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || true)"
echo "GPU：${GPU_NAME:-無法取得型號}"

if ! echo "$GPU_NAME" | grep -qi "GB10"; then
    echo -e "${YELLOW}警告：偵測到的 GPU 不是 GB10（${GPU_NAME:-未知}）。${NC}"
    echo "OLLAMA_LLM_LIBRARY=cuda_v13 是針對 GB10（SM121 / Compute Capability 12.1）調校，"
    echo "其他 GPU 上可能不需要或不適用，請自行確認。"
fi

nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || true

# ------------------------------
# 3. 安裝 Ollama
# ------------------------------

echo "步驟 3/7：安裝 Ollama..."

if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "Ollama 已存在，跳過安裝：$(ollama --version 2>/dev/null || echo '版本未知')"
fi

OLLAMA_BIN="$(command -v ollama)"

if [ -z "$OLLAMA_BIN" ] || [ ! -x "$OLLAMA_BIN" ]; then
    echo -e "${RED}錯誤：Ollama 安裝後仍找不到可執行檔。${NC}"
    exit 1
fi

echo "Ollama 路徑：$OLLAMA_BIN"

# 官方安裝腳本已自動建立 ollama 系統使用者與 systemd service，
# 這裡不重建使用者/服務，只清掉舊版部署腳本可能留下的多實例/Nginx 設定
# （ollama1~3.service、/etc/nginx/conf.d/ollama-lb.conf），全新機器上不會有任何動作
for legacy_instance in 1 2 3; do
    legacy_service="ollama${legacy_instance}.service"
    if systemctl list-unit-files "$legacy_service" >/dev/null 2>&1 &&
       [ -f "/etc/systemd/system/${legacy_service}" ]; then
        echo "移除舊的 ${legacy_service}..."
        sudo systemctl disable --now "$legacy_service" 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/${legacy_service}"
    fi
done

sudo rm -f /etc/nginx/conf.d/ollama-lb.conf 2>/dev/null || true
if command -v nginx >/dev/null 2>&1; then
    sudo nginx -t 2>/dev/null && sudo systemctl reload nginx 2>/dev/null || true
fi

# ------------------------------
# 4. 寫入 GB10 專屬 override 設定
# ------------------------------

echo "步驟 4/7：套用 GB10 專屬設定並啟動服務..."

# 不對外綁 0.0.0.0：優先只監聽 Tailscale IP，沒有才退回 127.0.0.1。
# 需要對外直接開放（例如自己前面沒有 nginx/反向代理）時，
# 執行前手動 export OLLAMA_BIND_ALL=1。
TAILSCALE_IP=""
if command -v tailscale >/dev/null 2>&1; then
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
fi

if [ "${OLLAMA_BIND_ALL:-0}" = "1" ]; then
    OLLAMA_LISTEN_ADDR="0.0.0.0:${OLLAMA_PORT}"
    ACCESS_MESSAGE="http://$(hostname -I | awk '{print $1}'):${OLLAMA_PORT}"
    echo "OLLAMA_BIND_ALL=1，Ollama 將監聽所有介面 0.0.0.0。"
elif [ -n "$TAILSCALE_IP" ]; then
    OLLAMA_LISTEN_ADDR="${TAILSCALE_IP}:${OLLAMA_PORT}"
    ACCESS_MESSAGE="http://${TAILSCALE_IP}:${OLLAMA_PORT}"
    echo "Ollama 將監聽 Tailscale IP：$TAILSCALE_IP"
else
    OLLAMA_LISTEN_ADDR="127.0.0.1:${OLLAMA_PORT}"
    ACCESS_MESSAGE="http://127.0.0.1:${OLLAMA_PORT}"
    echo "未偵測到 Tailscale IPv4。安全起見，Ollama 暫時只監聽 127.0.0.1。"
fi

sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_LISTEN_ADDR}"
Environment="OLLAMA_ORIGINS=*"
Environment="OLLAMA_LLM_LIBRARY=cuda_v13"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
Environment="OLLAMA_REQUEST_TIMEOUT=600"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl restart ollama

echo "等待 Ollama 啟動..."

for attempt in $(seq 1 30); do
    if curl --silent --fail --max-time 2 \
        "http://${OLLAMA_LISTEN_ADDR}/api/version" >/dev/null 2>&1; then
        echo -e "${GREEN}Ollama 已啟動。${NC}"
        break
    fi

    if [ "$attempt" -eq 30 ]; then
        echo -e "${RED}錯誤：Ollama 未能在預期時間內啟動。${NC}"
        echo ""
        sudo systemctl --no-pager --full status ollama || true
        exit 1
    fi

    sleep 2
done

# ------------------------------
# 5. 下載模型並暖機
# ------------------------------

echo "步驟 5/7：下載模型..."
echo "對話模型：$CHAT_MODEL"
echo "Embedding 模型：$EMBED_MODEL"

OLLAMA_HOST="${OLLAMA_LISTEN_ADDR}" "$OLLAMA_BIN" pull "$CHAT_MODEL"
OLLAMA_HOST="${OLLAMA_LISTEN_ADDR}" "$OLLAMA_BIN" pull "$EMBED_MODEL"

echo "暖機（keep_alive=-1，模型常駐 VRAM）..."

curl -s "http://${OLLAMA_LISTEN_ADDR}/api/generate" \
    -d "{\"model\":\"${CHAT_MODEL}\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":-1,\"options\":{\"num_predict\":1}}" \
    >/dev/null 2>&1 || true

curl -s "http://${OLLAMA_LISTEN_ADDR}/api/embed" \
    -d "{\"model\":\"${EMBED_MODEL}\",\"input\":\"test\",\"keep_alive\":-1}" \
    >/dev/null 2>&1 || true

# ------------------------------
# 6. 注意事項：大 context 自動放大問題
# ------------------------------

echo "步驟 6/7：提醒 — Ollama 0.31+ 大 VRAM 環境會自動放大預設 context"
echo "GB10 有 121GB UMA，Ollama 可能把沒指定 num_ctx 的請求自動開到很大的 context，"
echo "吃掉大量 VRAM。若要固定 context 長度，建議另外用 Modelfile 寫死："
echo "  FROM ${CHAT_MODEL}"
echo "  PARAMETER num_ctx 32768"
echo "  ollama create ${CHAT_MODEL}-32k -f Modelfile"
echo "請求裡帶的 num_ctx 仍可覆蓋這個預設值。"

# ------------------------------
# 7. 驗證服務
# ------------------------------

echo "步驟 7/7：驗證服務與 GPU 使用狀態..."

echo ""
echo "Port 測試："
status_code="$(
    curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
        "http://${OLLAMA_LISTEN_ADDR}/api/version" 2>/dev/null || true
)"
if [ "$status_code" = "200" ]; then
    echo -e "  ${OLLAMA_LISTEN_ADDR}: ${GREEN}HTTP 200，正常${NC}"
else
    echo -e "  ${OLLAMA_LISTEN_ADDR}: ${RED}${status_code:-連線失敗}${NC}"
fi

echo ""
echo "已安裝模型："
curl --silent --fail --max-time 15 "http://${OLLAMA_LISTEN_ADDR}/api/tags" |
    python3 -m json.tool || true

echo ""
echo "GPU 推理後端確認（應看到 library=CUDA ... cuda_v13）："
sudo journalctl -u ollama --no-pager 2>/dev/null | grep -i "inference compute" | tail -5 || true

echo ""
echo "GPU 執行程序檢查："
nvidia-smi || true

echo ""
echo "Ollama 執行狀態（模型應顯示常駐 Forever）："
OLLAMA_HOST="${OLLAMA_LISTEN_ADDR}" "$OLLAMA_BIN" ps || true

# ------------------------------
# 附加服務前置：服務帳號與目錄
# ------------------------------

# Whisper / Reranker 以系統服務（/etc/systemd/system）執行，身分是專用的服務帳號 gx10，
# 檔案集中在 /opt/gx10。不綁任何人的帳號：開機即啟動、不需要登入，任何管理員都能用
# sudo systemctl 管理，服務本身也讀不到使用者家目錄。
INSTALL_WHISPER="${INSTALL_WHISPER:-1}"
INSTALL_RERANK="${INSTALL_RERANK:-1}"
SVC_USER="gx10"
SVC_HOME="/opt/gx10"
SVC_PATH="${SVC_HOME}/bin:/usr/local/bin:/usr/bin:/bin"

# 以服務帳號身分執行指令（先 cd 到 SVC_HOME，避免服務帳號讀不到目前所在目錄）
run_as_svc() {
    (cd "$SVC_HOME" && sudo -u "$SVC_USER" -H env "PATH=${SVC_PATH}" "$@")
}

# v1.0 的 Whisper / Reranker 是 systemd user service，裝在執行者的家目錄。
# 升級時先停用並移除舊的 user service，避免新舊兩套同時搶同一個 port。
remove_legacy_user_services() {
    local unit_dir="${HOME}/.config/systemd/user"
    local removed=0
    local unit
    for unit in "$@"; do
        if [ -f "${unit_dir}/${unit}.service" ]; then
            echo "  停用舊版使用者服務：${unit}"
            systemctl --user disable --now "$unit" 2>/dev/null || true
            rm -f "${unit_dir}/${unit}.service"
            removed=1
        fi
    done
    if [ "$removed" = "1" ]; then
        systemctl --user daemon-reload 2>/dev/null || true
    fi
}

LEGACY_FILES=()

if [ "$INSTALL_WHISPER" = "1" ] || [ "$INSTALL_RERANK" = "1" ]; then
    if ! id "$SVC_USER" >/dev/null 2>&1; then
        echo "建立服務帳號 ${SVC_USER}（家目錄 ${SVC_HOME}，不可登入）..."
        sudo useradd --system --user-group --home-dir "$SVC_HOME" --shell /usr/sbin/nologin "$SVC_USER"
    fi
    sudo install -d -o "$SVC_USER" -g "$SVC_USER" -m 0755 "$SVC_HOME" "${SVC_HOME}/bin"
fi

# ------------------------------
# 附加：安裝 Whisper STT（whisper.cpp, CUDA 加速）
# ------------------------------

# 預設會裝；設 INSTALL_WHISPER=0 可跳過整段（例如這台機器不需要語音轉文字）
WHISPER_MODEL="${WHISPER_MODEL:-medium}"
WHISPER_PORT="${WHISPER_PORT:-8765}"
WHISPER_PROXY_PORT="${WHISPER_PROXY_PORT:-8002}"
WHISPER_DIR="${SVC_HOME}/whisper.cpp"
WHISPER_BIN_DIR="${SVC_HOME}/bin"
WHISPER_VENV_DIR="${SVC_HOME}/whisper-env"
LEGACY_WHISPER_DIR="${HOME}/whisper.cpp"

if [ "$INSTALL_WHISPER" = "1" ]; then
    echo ""
    echo "=================================================="
    echo "附加部署：Whisper STT（whisper.cpp, CUDA 加速）"
    echo "=================================================="

    NVCC_PATH="$(command -v nvcc 2>/dev/null || true)"
    if [ -z "$NVCC_PATH" ]; then
        for cand in /usr/local/cuda*/bin/nvcc; do
            [ -x "$cand" ] && NVCC_PATH="$cand" && break
        done
    fi

    if [ -z "$NVCC_PATH" ] || ! command -v cmake >/dev/null 2>&1; then
        echo -e "${YELLOW}警告：找不到 nvcc 或 cmake，略過 Whisper STT 安裝。${NC}"
        echo "  請先確認 CUDA toolkit 與 cmake 已就緒後重跑此腳本，"
        echo "  或設定 INSTALL_WHISPER=0 以永久跳過這段。"
    else
        NVCC_DIR="$(dirname "$NVCC_PATH")"

        echo "[1/7] 安裝 ffmpeg（arm64 static）..."
        if [ -f "${WHISPER_BIN_DIR}/ffmpeg" ]; then
            echo "  已存在，略過"
        else
            tmp_ffmpeg="$(mktemp -d)"
            curl -fsSL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz \
                -o "${tmp_ffmpeg}/ffmpeg.tar.xz"
            tar xf "${tmp_ffmpeg}/ffmpeg.tar.xz" -C "$tmp_ffmpeg"
            ffmpeg_extracted="$(find "$tmp_ffmpeg" -maxdepth 1 -type d -name 'ffmpeg-*-arm64-static' | head -n 1)"
            sudo install -o "$SVC_USER" -g "$SVC_USER" -m 0755 \
                "${ffmpeg_extracted}/ffmpeg" "${ffmpeg_extracted}/ffprobe" "$WHISPER_BIN_DIR/"
            rm -rf "$tmp_ffmpeg"
        fi

        echo "[2/7] 準備 whisper.cpp 原始碼..."
        if [ -d "${WHISPER_DIR}/.git" ]; then
            run_as_svc git -C "$WHISPER_DIR" pull --ff-only
        else
            run_as_svc git clone https://github.com/ggerganov/whisper.cpp.git --depth=1 "$WHISPER_DIR"
        fi

        echo "[3/7] 編譯 whisper.cpp（CUDA，約 2-3 分鐘）..."
        run_as_svc "PATH=${NVCC_DIR}:${SVC_PATH}" "CUDACXX=${NVCC_PATH}" \
            cmake -S "$WHISPER_DIR" -B "${WHISPER_DIR}/build" \
                -DGGML_CUDA=ON \
                -DCMAKE_CUDA_ARCHITECTURES=native \
                -DWHISPER_BUILD_SERVER=ON \
                -DCMAKE_BUILD_TYPE=Release \
                -Wno-dev >/dev/null
        run_as_svc "PATH=${NVCC_DIR}:${SVC_PATH}" "CUDACXX=${NVCC_PATH}" \
            cmake --build "${WHISPER_DIR}/build" --config Release -j"$(nproc)"

        echo "[4/7] 下載 whisper ${WHISPER_MODEL} 模型..."
        WHISPER_MODEL_FILE="${WHISPER_DIR}/models/ggml-${WHISPER_MODEL}.bin"
        if [ -f "$WHISPER_MODEL_FILE" ]; then
            echo "  模型已存在，略過"
        else
            run_as_svc bash "${WHISPER_DIR}/models/download-ggml-model.sh" "$WHISPER_MODEL"
        fi

        echo "[5/7] 建立 Whisper Proxy（OpenAI 相容 API，NeuroSme 用，port ${WHISPER_PROXY_PORT}）..."
        if [ ! -d "$WHISPER_VENV_DIR" ]; then
            run_as_svc python3 -m venv "$WHISPER_VENV_DIR"
        fi
        run_as_svc "${WHISPER_VENV_DIR}/bin/pip" install --quiet --no-cache-dir \
            fastapi uvicorn python-multipart httpx

        run_as_svc tee "${SVC_HOME}/whisper-proxy.py" >/dev/null <<PYEOF
"""Whisper Proxy：把 OpenAI /v1/audio/transcriptions 請求轉給 whisper.cpp /inference"""
import httpx
from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
import uvicorn

WHISPER_CPP_URL = "http://127.0.0.1:${WHISPER_PORT}"

app = FastAPI(title="Whisper Proxy")


@app.get("/health")
async def health():
    try:
        async with httpx.AsyncClient(timeout=3.0) as c:
            r = await c.get(f"{WHISPER_CPP_URL}/health")
        return r.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form("Systran/faster-whisper-${WHISPER_MODEL}"),
    language: str = Form(None),
    response_format: str = Form("verbose_json"),
    temperature: str = Form("0"),
    prompt: str = Form(None),
    vad_filter: str = Form(None),
    hotwords: str = Form(None),
):
    audio = await file.read()
    form_data: dict = {
        "response_format": "verbose_json",
        "temperature": temperature,
    }
    if language:
        form_data["language"] = language
    if prompt:
        form_data["prompt"] = prompt

    try:
        async with httpx.AsyncClient(timeout=120.0) as c:
            resp = await c.post(
                f"{WHISPER_CPP_URL}/inference",
                files={"file": (file.filename or "audio.wav", audio, file.content_type or "audio/wav")},
                data=form_data,
            )
    except httpx.ConnectError as e:
        raise HTTPException(status_code=503, detail=f"無法連線至 whisper.cpp: {e}")
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="whisper.cpp 逾時")

    if resp.status_code != 200:
        raise HTTPException(status_code=resp.status_code, detail=resp.text[:300])

    data = resp.json()
    return JSONResponse(content={
        "text": data.get("text", ""),
        "language": data.get("language", ""),
        "duration": data.get("duration", 0.0),
        "segments": data.get("segments", []),
        "task": "transcribe",
    })


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=${WHISPER_PROXY_PORT}, log_level="info")
PYEOF

        echo "[6/7] 設定 whisper-server 與 whisper-proxy 系統服務..."
        remove_legacy_user_services whisper-proxy whisper-server

        sudo tee /etc/systemd/system/whisper-server.service >/dev/null <<EOF
[Unit]
Description=Whisper.cpp STT Server (GPU)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${WHISPER_DIR}
Environment="LD_LIBRARY_PATH=${WHISPER_DIR}/build/bin"
Environment="PATH=${WHISPER_BIN_DIR}:${NVCC_DIR}:/usr/local/bin:/usr/bin:/bin"
ExecStart=${WHISPER_DIR}/build/bin/whisper-server \\
    -m ${WHISPER_MODEL_FILE} \\
    --host 0.0.0.0 \\
    --port ${WHISPER_PORT} \\
    --convert \\
    -l auto \\
    --threads 4
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

        sudo tee /etc/systemd/system/whisper-proxy.service >/dev/null <<EOF
[Unit]
Description=Whisper OpenAI-compatible Proxy (port ${WHISPER_PROXY_PORT})
After=whisper-server.service
Wants=whisper-server.service

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${SVC_HOME}
ExecStart=${WHISPER_VENV_DIR}/bin/python ${SVC_HOME}/whisper-proxy.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable whisper-server whisper-proxy
        sudo systemctl restart whisper-server whisper-proxy

        echo "[7/7] 等待服務啟動並驗證..."
        WHISPER_READY=0
        for attempt in $(seq 1 20); do
            if curl --silent --fail --max-time 5 "http://127.0.0.1:${WHISPER_PROXY_PORT}/health" >/dev/null 2>&1; then
                WHISPER_READY=1
                break
            fi
            sleep 3
        done
        if [ "$WHISPER_READY" = "1" ]; then
            echo -e "${GREEN}Whisper Proxy（OpenAI 相容 API）已啟動：http://127.0.0.1:${WHISPER_PROXY_PORT}${NC}"
            echo "  NeuroSme 設定：Base URL = http://<機器IP>:${WHISPER_PROXY_PORT}，模型名稱 = Systran/faster-whisper-${WHISPER_MODEL}"
        else
            echo -e "${YELLOW}警告：Whisper Proxy 未能在預期時間內啟動，請查看：${NC}"
            echo "  sudo systemctl status whisper-server whisper-proxy"
            echo "  sudo journalctl -u whisper-server -u whisper-proxy -n 50"
        fi

        for legacy in "$LEGACY_WHISPER_DIR" "${HOME}/whisper-env" "${HOME}/whisper-proxy.py" \
                      "${HOME}/bin/ffmpeg" "${HOME}/bin/ffprobe"; do
            if [ -e "$legacy" ]; then LEGACY_FILES+=("$legacy"); fi
        done
    fi
fi

# ------------------------------
# 附加：安裝 Reranker（供 NeuroSme RAG 檢索的 Rerank 步驟用）
# ------------------------------

# 預設會裝；設 INSTALL_RERANK=0 可跳過整段。
# API 與 NeuroSme 的 Rerank 設定相容：POST /rerank {query, texts, top_n}
# → {results: [{index, score}, ...]}。
RERANK_MODEL="${RERANK_MODEL:-BAAI/bge-reranker-v2-m3}"
RERANK_PORT="${RERANK_PORT:-8001}"
RERANK_VENV_DIR="${SVC_HOME}/rerank-env"
RERANK_HF_HOME="${SVC_HOME}/huggingface"
# HuggingFace 快取裡的模型資料夾名稱，例如 BAAI/bge-reranker-v2-m3 → models--BAAI--bge-reranker-v2-m3
RERANK_CACHE_NAME="models--${RERANK_MODEL//\//--}"
LEGACY_RERANK_CACHE="${HOME}/.cache/huggingface/hub/${RERANK_CACHE_NAME}"

if [ "$INSTALL_RERANK" = "1" ]; then
    echo ""
    echo "=================================================="
    echo "附加部署：Reranker（${RERANK_MODEL}）"
    echo "=================================================="

    echo "[1/4] 建立 Python venv 並安裝套件（fastapi/uvicorn/torch/transformers，第一次跑可能要幾分鐘）..."
    if [ ! -d "$RERANK_VENV_DIR" ]; then
        run_as_svc python3 -m venv "$RERANK_VENV_DIR"
    fi

    if run_as_svc "${RERANK_VENV_DIR}/bin/pip" install --quiet --no-cache-dir --upgrade pip \
        && run_as_svc "${RERANK_VENV_DIR}/bin/pip" install --quiet --no-cache-dir \
            fastapi uvicorn pydantic torch transformers accelerate; then

        # 以服務帳號身分檢查，順便確認 gx10 帳號本身能使用 GPU
        CUDA_OK="$(run_as_svc "${RERANK_VENV_DIR}/bin/python" -c 'import torch; print("1" if torch.cuda.is_available() else "0")' 2>/dev/null || echo "0")"
        if [ "$CUDA_OK" != "1" ]; then
            echo -e "${YELLOW}警告：這個環境裝到的 PyTorch 偵測不到 CUDA，Reranker 會退回 CPU 執行（較慢）。${NC}"
            echo "  如需 GPU 加速，請確認 PyTorch 版本有支援 GB10（aarch64 + CUDA 13 / SM121）。"
        fi

        echo "[2/4] 產生 Reranker Server（port ${RERANK_PORT}）..."
        run_as_svc tee "${SVC_HOME}/rerank-server.py" >/dev/null <<PYEOF
"""Rerank Server：${RERANK_MODEL} cross-encoder，實作 NeuroSme Rerank 設定期待的 API"""
import torch
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from transformers import AutoModelForSequenceClassification, AutoTokenizer
import uvicorn

MODEL_NAME = "${RERANK_MODEL}"
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

app = FastAPI(title="Rerank Server")

tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
model = AutoModelForSequenceClassification.from_pretrained(MODEL_NAME)
model.to(DEVICE)
model.eval()


class RerankRequest(BaseModel):
    query: str
    texts: list[str]
    top_n: int | None = None
    model: str | None = None


@app.get("/health")
async def health():
    return {"status": "ok", "model": MODEL_NAME, "device": DEVICE}


@app.post("/rerank")
async def rerank(req: RerankRequest):
    if not req.texts:
        raise HTTPException(status_code=400, detail="texts 不能為空")
    pairs = [[req.query, t] for t in req.texts]
    with torch.no_grad():
        inputs = tokenizer(
            pairs, padding=True, truncation=True, return_tensors="pt", max_length=512
        ).to(DEVICE)
        scores = model(**inputs).logits.view(-1).float().cpu().tolist()
    ranked = sorted(range(len(scores)), key=lambda i: scores[i], reverse=True)
    top_n = req.top_n or len(ranked)
    results = [{"index": i, "score": scores[i]} for i in ranked[:top_n]]
    return {"results": results}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=${RERANK_PORT}, log_level="info")
PYEOF

        echo "[3/4] 設定 rerank-server 系統服務..."
        remove_legacy_user_services rerank-server

        sudo tee /etc/systemd/system/rerank-server.service >/dev/null <<EOF
[Unit]
Description=Reranker Server (${RERANK_MODEL})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=${SVC_HOME}
Environment="HF_HOME=${RERANK_HF_HOME}"
ExecStart=${RERANK_VENV_DIR}/bin/python ${SVC_HOME}/rerank-server.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable rerank-server
        sudo systemctl restart rerank-server

        echo "[4/4] 等待 Reranker 啟動（第一次要下載模型權重，可能要 1-2 分鐘）..."
        RERANK_READY=0
        for attempt in $(seq 1 60); do
            if curl --silent --fail --max-time 3 "http://127.0.0.1:${RERANK_PORT}/health" >/dev/null 2>&1; then
                RERANK_READY=1
                break
            fi
            sleep 3
        done

        if [ "$RERANK_READY" = "1" ]; then
            echo -e "${GREEN}Reranker 已啟動：http://127.0.0.1:${RERANK_PORT}${NC}"
            RERANK_TEST="$(curl --silent --max-time 10 "http://127.0.0.1:${RERANK_PORT}/rerank" \
                -H 'Content-Type: application/json' \
                -d '{"query":"哪一段在講退款政策？","texts":["公司地址在台北市","退款需在7天內申請","本產品保固一年"],"top_n":1}' 2>/dev/null || true)"
            echo "  測試呼叫：${RERANK_TEST}"
        else
            echo -e "${YELLOW}警告：Reranker 未能在預期時間內啟動，請查看：${NC}"
            echo "  sudo systemctl status rerank-server"
            echo "  sudo journalctl -u rerank-server -n 50"
        fi

        for legacy in "${HOME}/rerank-env" "${HOME}/rerank-server.py" "$LEGACY_RERANK_CACHE"; do
            if [ -e "$legacy" ]; then LEGACY_FILES+=("$legacy"); fi
        done
    else
        echo -e "${YELLOW}警告：Python 套件安裝失敗，略過 Reranker 安裝。${NC}"
        echo "  可手動檢查網路／磁碟空間後重跑，或設定 INSTALL_RERANK=0 以永久跳過這段。"
    fi
fi

echo ""
echo "=================================================="
echo -e "${GREEN}部署完成${NC}"
echo "=================================================="
echo "服務入口：$ACCESS_MESSAGE"
echo "對話模型：$CHAT_MODEL"
echo "Embedding 模型：$EMBED_MODEL（1024 維）"
if [ "$INSTALL_WHISPER" = "1" ] && [ "${WHISPER_READY:-0}" = "1" ]; then
    echo "Whisper STT（NeuroSme 用）：http://127.0.0.1:${WHISPER_PROXY_PORT}（模型：Systran/faster-whisper-${WHISPER_MODEL}）"
fi
if [ "$INSTALL_RERANK" = "1" ] && [ "${RERANK_READY:-0}" = "1" ]; then
    echo "Reranker（NeuroSme 用）：http://127.0.0.1:${RERANK_PORT}（模型：${RERANK_MODEL}）"
fi
echo ""
echo "查看服務狀態：sudo systemctl status ollama"
echo "查看服務日誌：sudo journalctl -u ollama -f"
echo "確認模型是否使用 GPU：OLLAMA_HOST=${OLLAMA_LISTEN_ADDR} ollama ps"
if [ "$INSTALL_WHISPER" = "1" ]; then
    echo "查看 Whisper 服務狀態：sudo systemctl status whisper-server whisper-proxy"
    echo "查看 Whisper 服務日誌：sudo journalctl -u whisper-server -u whisper-proxy -f"
fi
if [ "$INSTALL_RERANK" = "1" ]; then
    echo "查看 Reranker 服務狀態：sudo systemctl status rerank-server"
    echo "查看 Reranker 服務日誌：sudo journalctl -u rerank-server -f"
fi
echo "=================================================="

# 從 v1.0（使用者服務版）升級時，家目錄裡的舊檔案已不再使用，只提示、不自動刪除
if [ "${#LEGACY_FILES[@]}" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}以下是舊版（v1.0）安裝在家目錄的檔案，服務已改用 ${SVC_HOME}，這些檔案不再使用。${NC}"
    echo "確認 Whisper / Reranker 運作正常後，可執行以下指令刪除以釋放空間："
    printf '  rm -rf'
    printf ' %q' "${LEGACY_FILES[@]}"
    printf '\n'
fi

# ------------------------------
# 產生部署報告
# ------------------------------

REPORT_FILE="${SCRIPT_DIR}/gb10-install-report-$(date +%Y%m%d-%H%M%S).md"
GPU_DRIVER_INFO="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo '無法取得')"
OLLAMA_VERSION="$(OLLAMA_HOST="${OLLAMA_LISTEN_ADDR}" "$OLLAMA_BIN" --version 2>/dev/null || echo '版本未知')"
CUDA_BACKEND_LINE="$(sudo journalctl -u ollama --no-pager 2>/dev/null | grep -i "inference compute" | tail -1 || true)"
if command -v docker >/dev/null 2>&1; then
    DOCKER_VERSION="$(docker --version 2>/dev/null || echo '版本未知')"
    DOCKER_COMPOSE_VERSION="$(docker compose version 2>/dev/null || echo '未安裝 Compose plugin')"
else
    DOCKER_VERSION=""
fi

{
    echo "# GB10 部署報告"
    echo ""
    if [ -n "$CUSTOMER_NAME" ]; then
        echo "- 標註：${CUSTOMER_NAME}"
    fi
    echo "- 主機：$(hostname)"
    echo "- 日期：$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "- CPU 架構：${ARCH}"
    echo "- GPU：${GPU_DRIVER_INFO}"
    echo "- Ollama：${OLLAMA_VERSION}"
    echo ""
    echo "## Ollama"
    echo ""
    echo "- 服務入口：${ACCESS_MESSAGE}"
    echo "- 對話模型：${CHAT_MODEL}"
    echo "- Embedding 模型：${EMBED_MODEL}（1024 維）"
    echo "- Port 測試：${status_code:-連線失敗}"
    if [ -n "$CUDA_BACKEND_LINE" ]; then
        echo "- GPU 推理後端：\`${CUDA_BACKEND_LINE}\`"
    else
        echo "- GPU 推理後端：（未取得，請手動確認 \`journalctl -u ollama | grep 'inference compute'\`）"
    fi
    echo ""
    if [ "$INSTALL_WHISPER" = "1" ]; then
        echo "## Whisper STT"
        echo ""
        if [ "${WHISPER_READY:-0}" = "1" ]; then
            echo "- 狀態：✅ 已啟動"
            echo "- Proxy（NeuroSme STT Base URL）：http://127.0.0.1:${WHISPER_PROXY_PORT}"
            echo "- 模型名稱（NeuroSme 設定用）：Systran/faster-whisper-${WHISPER_MODEL}"
        else
            echo "- 狀態：⚠️ 未成功啟動，見部署當下輸出的警告訊息"
        fi
        echo ""
    fi
    if [ "$INSTALL_RERANK" = "1" ]; then
        echo "## Reranker"
        echo ""
        if [ "${RERANK_READY:-0}" = "1" ]; then
            echo "- 狀態：✅ 已啟動"
            echo "- Base URL（NeuroSme Rerank Base URL）：http://127.0.0.1:${RERANK_PORT}"
            echo "- 模型：${RERANK_MODEL}"
        else
            echo "- 狀態：⚠️ 未成功啟動，見部署當下輸出的警告訊息"
        fi
        echo ""
    fi
    echo "## Docker"
    echo ""
    if [ -n "$DOCKER_VERSION" ]; then
        echo "- 狀態：✅ 已安裝"
        echo "- 版本：${DOCKER_VERSION}"
        echo "- Compose plugin：${DOCKER_COMPOSE_VERSION}"
    else
        echo "- 狀態：未安裝（這台機器如果還要跑 Docker 化的服務，如 Caddy／client-app，執行 \`bash install_docker.sh\`）"
    fi
    echo ""
    echo "## 驗證指令"
    echo ""
    echo '```bash'
    echo "sudo systemctl status ollama"
    echo "OLLAMA_HOST=${OLLAMA_LISTEN_ADDR} ollama ps"
    if [ "$INSTALL_WHISPER" = "1" ]; then
        echo "sudo systemctl status whisper-server whisper-proxy"
    fi
    if [ "$INSTALL_RERANK" = "1" ]; then
        echo "sudo systemctl status rerank-server"
    fi
    if [ -n "$DOCKER_VERSION" ]; then
        echo "docker ps"
    fi
    echo '```'
} > "$REPORT_FILE"

echo ""
echo -e "${GREEN}部署報告已寫入：${REPORT_FILE}${NC}"
