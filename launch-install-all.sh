#!/bin/bash
# 給 Install-All-GB10.desktop 雙擊執行用的啟動器：
# 依序執行 install_docker.sh → ollama_gb10.sh（同一個終端機視窗），
# 兩支腳本邏輯上互不相依，Docker 那段失敗也不會擋住後面的 Ollama 部署。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_script_dir() {
    for candidate in "$SELF_DIR" "$HOME/gx10-setup" "$PWD"; do
        if [ -f "$candidate/ollama_gb10.sh" ] && [ -f "$candidate/install_docker.sh" ]; then
            echo "$candidate"
            return 0
        fi
    done
    find "$HOME" -maxdepth 4 -name ollama_gb10.sh 2>/dev/null | head -n 1 | xargs -r dirname
}

TARGET_DIR="$(find_script_dir)"

run_in_terminal() {
    local cmd="$1"
    if command -v x-terminal-emulator >/dev/null 2>&1; then
        x-terminal-emulator -e bash -c "$cmd"
    elif command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal -- bash -c "$cmd"
    elif command -v konsole >/dev/null 2>&1; then
        konsole -e bash -c "$cmd"
    elif command -v xterm >/dev/null 2>&1; then
        xterm -e bash -c "$cmd"
    else
        return 1
    fi
}

if [ -z "$TARGET_DIR" ]; then
    MSG='echo "找不到 install_docker.sh 或 ollama_gb10.sh，請確認這個檔案跟這兩支腳本在同一個資料夾（或 ~/gx10-setup）。"; read -rp "按 Enter 鍵關閉視窗..." _'
    run_in_terminal "$MSG" || echo "找不到腳本，也找不到終端機模擬器可以顯示訊息。" >&2
    exit 1
fi

RUN_CMD="cd \"$TARGET_DIR\" \
&& echo '==================================================' \
&& echo '[1/2] 安裝 Docker' \
&& echo '==================================================' \
&& bash install_docker.sh \
; echo \
&& echo '==================================================' \
&& echo '[2/2] 安裝 Ollama GB10（含 Whisper／Reranker）' \
&& echo '==================================================' \
&& bash ollama_gb10.sh \
; echo \
&& read -rp \"按 Enter 鍵關閉視窗...\" _"

if ! run_in_terminal "$RUN_CMD"; then
    echo "找不到可用的終端機模擬器（試過 x-terminal-emulator / gnome-terminal / konsole / xterm）。" >&2
    exit 1
fi
