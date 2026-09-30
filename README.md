# gx10-setup

在 NVIDIA GB10 機器(NVIDIA DGX Spark / ASUS Ascent GX10)上一鍵部署本機 AI 服務:

- **Ollama**(GB10 專用設定,`cuda_v13`)+ 對話模型 `gemma4:26b` + Embedding 模型 `bge-m3`
- **Whisper STT**(whisper.cpp,CUDA 加速)+ OpenAI 相容 API
- **Reranker**(`BAAI/bge-reranker-v2-m3`)
- **Docker**(選用,給同一台機器上要跑的其他容器服務用)

裝完後可直接給 [NeuroSme Private Hub](https://ee.neurosme.ai/zh-TW)(REAS.ai 的企業 AI 轉型平台)使用,也適用其他支援 Ollama / OpenAI 相容 API 的應用程式。

---

## 1. 開始之前

| 項目 | 需求 |
|---|---|
| 機器 | NVIDIA GB10(DGX Spark / ASUS GX10),`nvidia-smi` 要能看到 `NVIDIA GB10` |
| 系統 | Ubuntu / DGX OS(ARM64),NVIDIA 驅動已安裝 |
| 磁碟 | **至少 50 GB 可用空間**(實際安裝約 32 GB,見第 8 節) |
| 網路 | 能連到 `ollama.com`、`github.com`、`huggingface.co`、`pypi.org`、Ubuntu / Docker apt 來源 |
| 權限 | 有 `sudo` 權限的一般帳號(**不要**用 root 執行) |
| 終端機 | 要在**真正的終端機**執行(本機終端機或 SSH),過程中需要輸入 sudo 密碼 |
| Whisper 額外需求 | CUDA toolkit(`nvcc`)與 `cmake`;沒有的話 Whisper 這段會自動跳過,不影響其他服務 |

## 2. 安裝

```bash
git clone https://github.com/REAS-ai-dev/gx10-setup.git ~/gx10-setup
cd ~/gx10-setup

# 只裝 Ollama + Whisper + Reranker
bash ollama_gb10.sh

# (選用)也要裝 Docker 的話
bash install_docker.sh
```

> 請 clone 到 `~/gx10-setup`(家目錄底下)。雙擊啟動器是依這個位置找腳本的。

**不想打指令**:在檔案總管打開 `~/gx10-setup`,雙擊以下任一個檔案(會開一個終端機視窗執行,跑完按 Enter 關閉):

| 檔案 | 執行內容 |
|---|---|
| `Install-All-GB10.desktop` | 依序安裝 Docker → Ollama / Whisper / Reranker |
| `Install-Ollama-GB10.desktop` | 只裝 Ollama / Whisper / Reranker |
| `Install-Docker.desktop` | 只裝 Docker |

第一次雙擊可能會跳出「不受信任的應用程式啟動器」警告,選「信任並啟動」(或右鍵 →「允許啟動」)一次即可。

腳本一開始會問「標註名稱(選填)」,例如公司或機器名稱,會寫在最後的部署報告上;不需要就直接按 Enter。

**所需時間約 30~60 分鐘**,大部分花在下載:Ollama 模型約 20 GB,Reranker 首次要裝 PyTorch(約 6 GB)並下載模型權重,Whisper 要編譯並下載模型。

### 可調整的設定(環境變數)

不設定就用預設值,一般不需要改:

```bash
CHAT_MODEL=gemma4:26b INSTALL_WHISPER=0 bash ollama_gb10.sh
```

| 變數 | 預設值 | 說明 |
|---|---|---|
| `CHAT_MODEL` | `gemma4:26b` | 對話模型 |
| `EMBED_MODEL` | `bge-m3` | Embedding 模型(1024 維) |
| `OLLAMA_NUM_PARALLEL` | `3` | 同時處理的請求數。GB10 **不要設到 4**(有 segfault 回報,見 [ollama#15318](https://github.com/ollama/ollama/issues/15318)) |
| `OLLAMA_BIND_ALL` | 不設 | 設成 `1` 讓 Ollama 監聽所有網路介面,見第 5 節 |
| `INSTALL_WHISPER` | `1` | 設成 `0` 跳過 Whisper STT |
| `WHISPER_MODEL` | `medium` | whisper.cpp 模型,例如 `small`、`large-v3` |
| `WHISPER_PORT` | `8765` | whisper.cpp 原生 server port |
| `WHISPER_PROXY_PORT` | `8002` | OpenAI 相容 STT API port |
| `INSTALL_RERANK` | `1` | 設成 `0` 跳過 Reranker |
| `RERANK_MODEL` | `BAAI/bge-reranker-v2-m3` | HuggingFace cross-encoder 模型 |
| `RERANK_PORT` | `8001` | Reranker port |
| `CUSTOMER_NAME` | 不設 | 預先填好「標註名稱」,就不會詢問 |

## 3. 安裝完成後會有什麼

| 服務 | Port | 用途 | 管理方式 |
|---|---|---|---|
| Ollama | `11434` | 對話(`gemma4:26b`)、Embedding(`bge-m3`) | `sudo systemctl ... ollama` |
| Whisper Proxy | `8002` | 語音轉文字,OpenAI 相容 `/v1/audio/transcriptions` | `sudo systemctl ... whisper-proxy` |
| whisper-server | `8765` | whisper.cpp 原生 server(Proxy 在背後呼叫它) | `sudo systemctl ... whisper-server` |
| Reranker | `8001` | `POST /rerank {query, texts, top_n}` → `{results: [{index, score}]}` | `sudo systemctl ... rerank-server` |

Whisper 與 Reranker 以系統服務執行,身分是安裝時自動建立的專用服務帳號 `gx10`(不可登入),檔案都放在 `/opt/gx10/`,不綁任何人的帳號。

腳本跑完會在 `~/gx10-setup` 底下產生一份 `gb10-install-report-<時間>.md` 部署報告,列出各服務狀態與連線網址。

### 給 NeuroSme Private Hub 的設定

| NeuroSme Private Hub 設定 | 填什麼 |
|---|---|
| Ollama Base URL | `http://<機器 IP>:11434`(IP 見第 5 節) |
| 對話模型 | `gemma4:26b` |
| Embedding 模型 | `bge-m3`(1024 維) |
| STT Base URL | `http://<機器 IP>:8002`(**是 8002,不是 8765**) |
| STT 模型名稱 | `Systran/faster-whisper-medium` |
| Rerank Base URL | `http://<機器 IP>:8001` |

> `gemma4:26b` 是 thinking 模型,API 回應的內容可能主要在 `thinking` 欄位,串接時請確認應用程式有正確解析。

## 4. 確認安裝成功

腳本最後的「步驟 7/7」會印出驗證結果,逐項對照:

1. **Port 測試是 `HTTP 200`**
2. **GPU 推理後端有 `library=CUDA` 與 `cuda_v13`**:這是最重要的一項;看到 `library=cpu` 代表模型會用 CPU 跑(非常慢)
3. **`ollama ps` 兩個模型都是 `100% GPU`、`UNTIL` 為 `Forever`**
4. **已安裝模型清單有 `gemma4:26b` 與 `bge-m3`**
5. **Whisper**:有印出「Whisper Proxy(OpenAI 相容 API)已啟動」
6. **Reranker**:有印出「Reranker 已啟動」與一筆測試呼叫的 JSON 結果

事後隨時可以手動再確認(`<Ollama 位址>` 見第 5 節,沒裝 Tailscale 就是 `127.0.0.1:11434`):

```bash
sudo systemctl status ollama
journalctl -u ollama --no-pager | grep "inference compute" | tail -3   # 要看到 cuda_v13
OLLAMA_HOST=<Ollama 位址> ollama ps

curl http://<Ollama 位址>/api/chat -d '{
  "model": "gemma4:26b",
  "messages": [{"role": "user", "content": "你好"}],
  "stream": false
}'

sudo systemctl status whisper-server whisper-proxy rerank-server
curl http://127.0.0.1:8002/health
curl http://127.0.0.1:8001/health

# 用 whisper.cpp 內建的範例音檔測一次轉錄
curl http://127.0.0.1:8002/v1/audio/transcriptions -F "file=@/opt/gx10/whisper.cpp/samples/jfk.wav"
```

## 5. 網路與安全(請務必閱讀)

**這些服務都沒有任何帳號密碼驗證**,連得到 port 的人就能使用。各服務的監聽位址不同:

| 服務 | 監聽位址 | 誰連得到 |
|---|---|---|
| Ollama(有裝並登入 Tailscale) | Tailscale IP `:11434` | 只有同一個 Tailscale 網路的裝置;**本機也要用 Tailscale IP 連**,`127.0.0.1` 連不到 |
| Ollama(沒裝 Tailscale) | `127.0.0.1:11434` | 只有這台機器自己 |
| Ollama(`OLLAMA_BIND_ALL=1`) | `0.0.0.0:11434` | 所有連得到這台機器的裝置 |
| Whisper(`8002`、`8765`)、Reranker(`8001`) | `0.0.0.0` | 所有連得到這台機器的裝置 |

建議:

- 機器放在受信任的內部網路,**不要**直接暴露在網際網路上
- 用防火牆限制可連線的來源,例如只允許應用程式伺服器的 IP:
  ```bash
  sudo ufw allow from <應用程式伺服器 IP> to any port 8001,8002 proto tcp
  ```
- Ollama 設定了 `OLLAMA_ORIGINS=*`(允許任何網頁來源呼叫),若只給後端程式使用、不需要從瀏覽器直接呼叫,可改成你的網域
- 執行腳本前就已安裝並登入 Tailscale 的話,Ollama 會自動只監聽 Tailscale IP;裝完之後才補裝 Tailscale 的話,重跑一次 `bash ollama_gb10.sh` 即可

## 6. 重開機後的行為

- **Ollama** 開機就會啟動,但**模型要等第一次請求才會載入 GPU**(第一次請求會慢一些,之後常駐不卸載)
- **Whisper 與 Reranker** 是系統服務,開機就會自動啟動並把模型載入 GPU,**不需要有人登入**

## 7. 常用指令

```bash
# Ollama
sudo systemctl status ollama
sudo journalctl -u ollama -f
OLLAMA_HOST=<Ollama 位址> ollama ps

# Whisper
sudo systemctl status whisper-server whisper-proxy
sudo journalctl -u whisper-server -u whisper-proxy -f

# Reranker
sudo systemctl status rerank-server
sudo journalctl -u rerank-server -f

# Docker
sudo systemctl status docker
docker ps
```

Ollama 設定檔在 `/etc/systemd/system/ollama.service.d/override.conf`,修改後要:

```bash
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

## 8. 磁碟空間

以一台已完整安裝(全部預設值 + Docker)的 GX10 實測(Whisper / Reranker 的大小為 v1.0 安裝在家目錄時的實測值,搬到 `/opt/gx10/` 後內容相同):

| 元件 | 位置 | 大小 |
|---|---|---:|
| Ollama 本體 | `/usr/local/bin/ollama`、`/usr/local/lib/ollama/` | 2.2 GB |
| Ollama 模型(`gemma4:26b` 18.6 GB + `bge-m3` 1.2 GB) | `/usr/share/ollama/.ollama/models/` | 19.8 GB |
| Whisper STT(含 `medium` 模型 1.5 GB、ffmpeg) | `/opt/gx10/whisper.cpp/`、`/opt/gx10/whisper-env/`、`/opt/gx10/bin/` | 1.9 GB |
| Reranker(PyTorch 環境 5.7 GB + 模型 2.3 GB) | `/opt/gx10/rerank-env/`、`/opt/gx10/huggingface/` | 8.0 GB |
| Docker(套件本身,不含映像檔) | `/usr` | 0.3 GB |
| **合計** | | **約 32 GB** |

- 全部都在 `/` 分割區(`/usr`、`/opt`),不佔 `/home`
- 只裝 Ollama(`INSTALL_WHISPER=0 INSTALL_RERANK=0`)約需 22 GB
- `WHISPER_MODEL=large-v3` 的模型檔約 3.1 GB(`medium` 為 1.5 GB)
- 安裝時 pip 不保留下載快取,所以不會多佔空間
- 從 v1.0 升級的機器,舊檔案還留在家目錄(約 10 GB),見第 10 節

## 9. 疑難排解

| 狀況 | 先查 | 處理方式 |
|---|---|---|
| Port 測試不是 200 | `sudo systemctl status ollama` | `sudo ss -tlnp \| grep 11434` 看 port 是否被其他程式佔用 |
| 沒看到 `cuda_v13`、或看到 `library=cpu` | `cat /etc/systemd/system/ollama.service.d/override.conf` 要有 `OLLAMA_LLM_LIBRARY=cuda_v13` | 改完要 `daemon-reload` + `restart`。log 裡出現 `cuda_v12 skipped` 是**正常的**,GB10 本來就只用 `cuda_v13` |
| `ollama ps` 顯示 CPU | `nvidia-smi` 是否正常顯示 `NVIDIA GB10` | 確認 NVIDIA 驅動版本夠新 |
| 兩個模型一直重複載入 | override.conf 的 `OLLAMA_MAX_LOADED_MODELS` 要是 `2` | 對話 + Embedding 同時常駐至少需要 `2` |
| 模型下載卡住 | `curl -I https://ollama.com` | 重跑 `bash ollama_gb10.sh`,下載會續傳,已裝好的部分會跳過 |
| `sudo: a terminal is required to read the password` | 不是在真正的終端機執行 | 改在本機終端機或 SSH 裡直接執行 |
| Whisper 整段被跳過,印「找不到 nvcc 或 cmake」 | `command -v nvcc cmake` | 安裝 CUDA toolkit 與 `cmake`(`sudo apt install cmake`)後重跑 |
| Whisper 沒印出「已啟動」 | `sudo systemctl status whisper-server whisper-proxy` | `sudo journalctl -u whisper-server -u whisper-proxy -n 50`,常見是 port 被佔用 |
| Reranker 印「PyTorch 偵測不到 CUDA」 | `sudo -u gx10 /opt/gx10/rerank-env/bin/python -c "import torch; print(torch.cuda.is_available())"` | 仍可用 CPU 執行,只是較慢 |
| Reranker 沒印出「已啟動」 | `sudo systemctl status rerank-server` | 第一次要下載模型權重(1~2 分鐘);`sudo journalctl -u rerank-server -n 50` 看是否連不到 HuggingFace 或磁碟不足 |
| 重開機後 Whisper / Reranker 連不到 | `sudo systemctl is-enabled whisper-server whisper-proxy rerank-server` 要都是 `enabled` | `sudo systemctl enable --now whisper-server whisper-proxy rerank-server` |
| 雙擊 `.desktop` 沒反應 | 是否 clone 到 `~/gx10-setup` 以外的位置 | 改 clone 到 `~/gx10-setup`,或直接用指令執行 |
| `bad interpreter: /bin/bash^M` | 檔案經過 Windows 電腦後換行格式被改掉 | `sed -i 's/\r$//' *.sh *.desktop` |

## 10. 更新

```bash
cd ~/gx10-setup
git pull
bash ollama_gb10.sh
```

重跑是安全的:已安裝的 Ollama、已下載的模型、已編譯的 Whisper 都會跳過或只做增量更新。

### 從 v1.0 升級

v1.0 的 Whisper / Reranker 是裝在執行者家目錄的使用者服務(`systemctl --user`)。v1.1 起改成系統服務,重跑腳本時會自動:

1. 建立 `gx10` 服務帳號與 `/opt/gx10/`
2. 停用並移除舊的使用者服務,避免新舊兩套同時搶 port 8001 / 8002 / 8765
3. **複製**已下載的 Whisper 模型、Reranker 模型權重與 ffmpeg,不重新下載
4. 建立並啟動新的系統服務

家目錄的舊檔案**不會自動刪除**。腳本最後會列出這些檔案與刪除指令(約 10 GB),確認新服務運作正常後再刪即可。v1.0 為安裝帳號開啟的 linger 不影響新版,不需要處理;若想關掉可執行 `sudo loginctl disable-linger $USER`。

## 11. 移除

```bash
# Ollama:只移除本專案加上的設定,恢復成 Ollama 官方預設
sudo rm -rf /etc/systemd/system/ollama.service.d
sudo systemctl daemon-reload && sudo systemctl restart ollama

# 完全移除 Ollama(含模型約 20 GB,請確認再執行)
# sudo systemctl disable --now ollama
# sudo rm -f /etc/systemd/system/ollama.service /usr/local/bin/ollama
# sudo rm -rf /usr/local/lib/ollama /usr/share/ollama

# Whisper STT 與 Reranker
sudo systemctl disable --now whisper-server whisper-proxy rerank-server
sudo rm -f /etc/systemd/system/whisper-server.service \
           /etc/systemd/system/whisper-proxy.service \
           /etc/systemd/system/rerank-server.service
sudo systemctl daemon-reload

# 刪除程式、模型與服務帳號(約 10 GB)
sudo rm -rf /opt/gx10
sudo userdel gx10

# Docker(含所有容器與映像檔,請確認再執行)
# sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# sudo rm -rf /var/lib/docker /var/lib/containerd
# sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
```

## 授權

[MIT License](./LICENSE) © 2026 REAS.ai

本專案的腳本會從各自的官方來源下載並安裝第三方軟體與模型(Ollama、whisper.cpp、FFmpeg、PyTorch、Hugging Face 模型、Docker 等),這些軟體與模型各自適用其原本的授權條款。
