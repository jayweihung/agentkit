# 在公司用 kit（Windows 第一天）

從安裝到第一次送出修改，照順序做一次就會了。Mac、Linux 的步驟一樣，只有安裝那一步不同（看 INSTALL.md）。

## 0. 先準備好

- **Git for Windows**：沒裝的話，kit 的安裝會停下來叫你先裝。
- **Herdr**：裝好，而且開過一次（這樣 Herdr 的設定資料夾才會存在）。
- **登得進公司的 Gitea**：先自己用 git clone 一次團隊來源的 repo，確定不會卡在帳號密碼。
  kit 跑 git 時不會跳出帳號密碼的視窗，沒先登入好的話只會看到「沒辦法 clone」。
- **公司信箱**：

      git config --global user.email 你的公司信箱

  團隊的 kit.yaml 有寫 `author_domains` 的話，信箱不是公司網域就送不出去。

## 1. 裝 kit

把公司的 agentkit repo clone 下來，在那個資料夾裡打：

    powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1

不用管理員權限。**開一個新的終端機**，打 `kit --version` 有出現版本就好了。

## 2. 接上團隊的來源

    kit init <團隊來源的網址>

kit 會把來源 clone 到 `%USERPROFILE%\agentkit\<來源名字>`，再把團隊必備的規則、skill、MCP 裝進你有的工具（Claude Code、Codex、omp）。
之後在畫面上改的檔案，就是這個資料夾裡的。

## 3. 裝進 Herdr

    kit herdr-panel install

裝好後（每個畫面的用法看 docs/herdr.md）：

- 每個 agent 視窗上面多一顆 Kit 按鈕。
- 上排多 `Agents` 和 `Kit` 兩顆按鈕：`Kit` 開關右邊的倉庫，`Agents` 開關右邊的 Agents 面板。

## 4. 第一次修改並送出

1. 按上排的 `Kit` 打開倉庫，選「Skills」，點一個 skill。
2. 改內容，按「存檔」。清單上它會標「改過」，最上面出現「送出」。
3. 按「送出」：kit 先列出會送哪些檔案，確認沒問題再按「確定送出」。
4. kit 會先跑 `kit check`（格式、引用、不該公開的字），有問題就什麼都不送，照訊息改好再送。
5. 過了就開一個 `kit/...` 分支推到 Gitea，並開 PR：
   - 有 Gitea token 的話，會直接印出 PR 的網址。
   - 沒有 token 的話，會印出一個網址，點進去自己按「建立 PR」。
6. 等 PR 被合併。**送出後，你改的檔案會從本機搬到那個分支上**，所以倉庫裡暫時看不到你的修改；合併後按「同步」（或打 `kit sync`）就會回來。

想先看會送什麼，不真的送：

    kit push --to <來源名字> --dry-run

## 5. Gitea token（讓 kit 自動開 PR，可以不設）

1. 在 Gitea 右上角的頭像 → 設定 → 應用程式，產生一個 token（權限要能讀寫 repository）。
2. 存成這個檔案，裡面只放 token 一行：

       %USERPROFILE%\.config\agentkit\gitea-token

不要把 token 貼到聊天、文件或 commit 裡。也可以用環境變數 `KIT_GITEA_TOKEN`。

## 6. 團隊的來源和自己的來源

每個來源的 `kit.yaml` 寫清楚送出的方式，kit 不用猜：

| `kit.yaml` | 送出時 | 用在 |
|---|---|---|
| `push: pr`（不寫就是這個） | 開 `kit/...` 分支，推到 `origin`，開 PR 等人審 | 團隊放在 Gitea 的來源 |
| `push: direct` | 直接 commit 到現在的分支，推到它所有的 remote，不開 PR | 只有你自己用的來源 |

同一台電腦可以同時接團隊的來源和自己的來源，各走各的。
團隊的來源一定要用 `push: pr`，這樣修改都會經過審查。

管理團隊來源的人還可以在 `kit.yaml` 寫：

- `allowed_hosts`：kit 只准連這些主機（clone、push 都檢查）。
- `author_domains`：送出的人的 git 信箱必須是這些網域。
- `kit_version`：kit 比這個舊的人會被提醒 `kit self-update`。

## 常見問題

- **「沒辦法 clone」**：先自己 git clone 一次，確定登得進 Gitea。
- **按「用編輯器開」跳出「要用哪個程式開」**：Windows 還沒設定 `.md`、`.yaml` 用什麼開，選記事本（或你的編輯器）並勾「一律使用」。
- **同步說「有沒送出的修改」**：你在倉庫改了檔案還沒送出，先送出或還原，再同步。
- **新加的 MCP 沒出現**：把那個 agent 關掉重開。
