# MEM: CI pipeline (`.github/workflows/ci.yml`)
Date: 2026-10-16
Status: Approved
Tags: [ci, github-actions, security, macos]

## Summary
CI 有四個 job:Go 1.24 與最新版各跑一次 `make check`、在 macOS 用 Apple 內建的 bash 3.2 與 BSD 工具測試 shell 腳本、gitleaks 掃完整 Git 歷史、govulncheck 掃標準庫漏洞。

## Details

### Context & Evolution (脈絡與演進)
- 規範要求 CI 必須跑測試、覆蓋率門檻、依賴與機密掃描,而本機受限於 Big Sur(MEM-0001),所以把「重」的檢查放到雲端。
- 查證後發現:GitHub 已在 2026-09-16 把 Node 20 從託管 runner 移除,所以使用 Node 20 的舊版 action(例如 `checkout@v4`、`setup-go@v5`、`gitleaks-action@v2`)現在會直接失效。本專案使用 Node 24 版:`checkout@v6`、`setup-go@v6`、`gitleaks-action@v3`。
- 覆蓋率門檻尚未加入,等 Phase 1 有第一批程式時再補(見 README §8)。

### Specification
| Job | 平台 | 做什麼 | 為什麼 |
|---|---|---|---|
| `test` | ubuntu,Go `1.24.x` 與 `stable` | `make check`(lint、`-race` 測試、腳本測試、機密掃描) | 1.24 是本機能跑的底線;stable 提早發現換新機器後的相容問題 |
| `shell-macos` | macos-latest | 用受限的 `PATH` 跑 `make test-scripts scan` | 本機是 bash 3.2 與 BSD grep,Linux 跑過不代表 macOS 也行 |
| `secrets` | ubuntu | gitleaks,`fetch-depth: 0` | 掃完整歷史,補足本機 regex 掃描 |
| `vulncheck` | ubuntu,Go `stable` | `govulncheck ./...` | 規範的依賴掃描;零依賴專案實際掃的是標準庫 |

觸發:`main` 與 `phase/**` 的 push,以及對 `main` 的 PR。同一個 ref 的舊執行會被新的取消。

### 新手常犯的錯
| # | 常見錯誤 | 後果 | 本專案的做法 |
|---|---|---|---|
| 1 | 照舊教學複製 `checkout@v4`、`setup-go@v5` | Node 20 已被移除,workflow 直接失敗 | 使用 Node 24 版本 |
| 2 | 沒寫 `permissions` | token 預設權限比需要的大,被攻陷的 action 可寫入 repo | 預設唯讀,需要才在 job 上加 |
| 3 | `checkout` 用預設的淺層 clone 再跑 gitleaks | 只看得到最新一個 commit,歷史裡的機密漏掉 | `fetch-depth: 0` |
| 4 | 只在 Linux 跑腳本就以為 macOS 也行 | bash 3.2 與 BSD grep 的差異在上線後才爆 | 獨立的 macOS job |
| 5 | macOS job 直接執行腳本 | runner 的 PATH 可能先找到較新的 bash 與 GNU 工具,根本沒測到 Apple 版本 | 把 `PATH` 限制為系統目錄,並印出版本確認 |
| 6 | 沒依賴卻開 `setup-go` 快取 | 找不到 `go.sum`,每次都跳警告 | `cache: false` |
| 7 | 在 EOL 的 Go 版本上跑 govulncheck | 修在新版的標準庫漏洞不會回補,CI 永遠紅燈,最後被人關掉 | 只在 stable 上跑 |
| 8 | 矩陣用預設 `fail-fast` | 一個版本失敗就取消另一個,看不到完整的相容性圖像 | `fail-fast: false` |
| 9 | 不設 `timeout-minutes` | 卡住的 job 預設最長 6 小時 | 每個 job 10 分鐘 |

### 專家會留意的地方
1. **供應鏈。** 用 `@v6` 這種可移動的 tag,上游被入侵時會自動取得惡意版本;更嚴謹的做法是釘住 commit SHA 並用 Dependabot 更新。本專案先取簡單,列為已知取捨。
2. **`persist-credentials: false`。** 避免 checkout 把 token 留在 `.git/config`,讓後面的步驟能讀到。
3. **`GOTOOLCHAIN: local`。** CI 與開發機行為一致,工具鏈不足時直接報錯,而不是悄悄下載另一個版本。
4. **govulncheck 的盲點。** 它只掃 CI 用的最新版標準庫,沒掃本機 Go 1.24。這個風險靠「server 只綁 loopback」接受,見 MEM-0001。
5. **兩層機密防線互補。** 本機 regex 掃描(MEM-0003)擋住「還沒 commit 的」,gitleaks 掃歷史與高熵字串。
6. **來自 fork 的 PR 拿不到 secrets。** 目前沒有需要 secrets 的 job,所以不受影響;日後若加入,要重新設計。
7. **日後要做的:** 在 repo 設定啟用 branch protection,把 `test`、`shell-macos`、`secrets` 設為合併前必須通過。

### 尚未驗證(誠實清單)
- **這份 workflow 還沒在 GitHub 上實際跑過。** 在沙盒只做了 YAML 語法與 actionlint 靜態檢查;第一次推送後以 Actions 頁面的結果為準。
- `gitleaks-action` 是否要求 `GITLEAKS_LICENSE`:據我所知只有組織帳號的 repo 需要,個人帳號不用,但沒有親自驗證。若第一次執行因此失敗,錯誤訊息會直接說明。
- `go install ...@latest` 沒有釘版本,見上方 FIXME。
- `macos-latest` 的映像內容會變動,PATH 限制是為了降低影響,但不保證永遠等同你的 Big Sur 環境。

## When to Use
- 修改 `.github/workflows/ci.yml`、新增 job 或升級 action 版本之前。
- CI 失敗、需要判斷是程式問題還是環境問題時。
- 若本文件被標為 Superseded,請忽略它。
