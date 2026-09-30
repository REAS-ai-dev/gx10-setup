#!/bin/bash
# 給 Install-Ollama-GB10.desktop 雙擊執行用的啟動器：
# 找到 ollama_gb10.sh、開一個終端機視窗執行它，執行完提示按 Enter 才關閉視窗
# （這樣即使腳本出錯或印出警告，視窗也不會一閃而過）。
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_script_dir() {
    for candidate in "$SELF_DIR" "$HOME/gx10-setup" "$PWD"; do
        if [ -f "$candidate/ollama_gb10.sh" ]; then
            echo "$candidate"
            return 0
        fi
    done
    # 最後手段：在使用者家目錄底下找（clone 到其他資料夾名稱時的備援）
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
    MSG='echo "找不到 ollama_gb10.sh，請確認這個檔案跟 ollama_gb10.sh 在同一個資料夾（或 ~/gx10-setup）。"; read -rp "按 Enter 鍵關閉視窗..." _'
    run_in_terminal "$MSG" || echo "找不到 ollama_gb10.sh，也找不到終端機模擬器可以顯示訊息。" >&2
    exit 1
fi

RUN_CMD="cd \"$TARGET_DIR\" && bash ollama_gb10.sh; echo; read -rp \"按 Enter 鍵關閉視窗...\" _"

if ! run_in_terminal "$RUN_CMD"; then
    echo "找不到可用的終端機模擬器（試過 x-terminal-emulator / gnome-terminal / konsole / xterm）。" >&2
    exit 1
fi
