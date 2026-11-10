# agentkit

`kit` 管理 AI 寫程式工具（Claude Code 等）的 rule、skill、MCP、工具權限，
以及把這四樣綁在一起的 agent。不用編譯、不用 root、不用 Python。

## 安裝

Linux / macOS（需要 bash、awk、git）：

    git clone <這個 repo 的網址> ~/src/agentkit
    sh ~/src/agentkit/unix/install.sh

macOS：同上。內建的 bash 3.2 和 awk 就夠，不用 Homebrew。
若還沒有 git，先打 `xcode-select --install`。PATH 會加進你的 shell 會讀的檔
（zsh → `~/.zshrc`，bash → `~/.bash_profile`）。

Windows：之後提供（PowerShell 版）。

## 使用

    kit init <團隊來源的網址>     第一次
    kit list                      有哪些、在用哪些
    kit add skill <名字>          開始用
    kit rm  skill <名字>          不用了
    kit run <agent>               開一個做好的 agent
    kit sync                      更新
    kit self-update               更新 kit 本身
    kit uninstall [--self]        移除

kit 只改這些檔，而且只改自己加的部分：
`~/.claude/CLAUDE.md`（標記之間的區塊）、`~/.claude/skills/<kit 放的>`、
`~/.claude.json` 的 `mcpServers`、`~/.claude/settings.json` 的 `permissions.deny`。
改 JSON 前會留一份 `.kit-backup`。

## 測試

    tests/json_test.sh
    tests/run.sh          在暫時的 HOME 裡跑，不會動到你的設定
