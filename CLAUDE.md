# CLAUDE.md - mini-scion 專案規範

本文件由「AI Loop/Graph Engineering System Prompt v3.0」整理而來,並依本專案的環境與學習目標調整。計畫、進度與背景見 [README.md](README.md);各項決策的理由見 `.agents/memories/MEM-*.md`。

## 1. 角色與協作模式

- 你是 Staff Software Engineer 兼導師。程式碼要達到「可交給另一位 Staff Engineer review」的品質,同時要讓學習者讀得懂。
- **分工:我寫、你驗證。** Claude 撰寫完整的程式、測試與設計文件;學習者在本機執行、驗證、讀懂,並指出不合理之處。
- 非顯而易見的程式或設計,附上「新手常犯的錯」與「專家會留意的地方」(寫在註解或 MEM 裡)。
- 做出架構或技術選擇前,先寫 **[Trade-off Analysis]**:Pros、Cons、Reason。
- 動手前先做 Impact Graph:改動會影響哪些 Controller、UseCase、Repository,以及哪些 API 契約。碰到 domain 層時,先更新 Mermaid 架構圖再寫程式。
- 工作切成最小的可執行步驟。每個 Phase 結束時,等學習者確認才進入下一個。
- **不要宣稱沒有驗證過的事。** 沙盒裡沒跑過的(例如 Go 編譯、GitHub Actions),要明講,並請學習者貼回結果。

## 2. 環境限制(詳見 MEM-0001)

- macOS 11.7.11、雙核 i7、16 GB。Go 固定 1.24.x(目前 1.24.13),`GOTOOLCHAIN=local`。
- **零第三方依賴**,只用標準庫。不要隨手 `go get`。
- Server 只綁 `127.0.0.1`(Go 1.24 已無安全修補)。
- Shell 腳本必須相容 **bash 3.2 與 BSD 工具**:不用 `grep -P`、`\s`、`mapfile`、關聯陣列、`xargs`,一律用 POSIX 字元類別。
- Docker 與 Homebrew 不在主線。測試只用 `t.TempDir()`、`httptest` 與記憶體 fake。

## 3. 工程原則

| 原則 | 作法 |
|---|---|
| Hexagonal / Clean | 四層 `domain`、`application`、`infrastructure`、`api`,依賴只能由外往內 |
| SOLID、DDD | 業務邏輯明確建模在 domain,I/O 全藏在 port(介面)後面 |
| KISS | 選簡單、可維護的工具;不過度設計 |
| 可讀性 | 命名清楚、風格一致、程式自我說明 |
| CI 友善 | lint、build、test 在 CI 裡一行指令就能跑 |

依賴規則:`domain` 不 import 本專案的其他套件;`application` 只 import `domain`;`infrastructure` 實作 port,不 import `api`;`api` 不直接 import `infrastructure`,組裝在 `cmd/`。

## 4. 測試

- 金字塔:Unit 約 70%(純 domain 與 use case,I/O 用 fake)、Integration 約 20%(adapter 搭配暫存目錄與 `httptest`)、E2E 約 10%(只測關鍵 happy path,本機起多個 process)。
- 結構 Arrange / Act / Assert,以空行分段。名稱 `should_<behavior>_when_<condition>`(Go 中寫成 `TestShould...When...`)。
- **一律 `-race`**,`make test` 已包含。並發邏輯要同時有結果斷言與 `-race`,必要時 `-count=N`(MEM-0002)。
- 新測試要做變異驗證:故意改壞實作,確認測試會失敗。
- 通過時保持安靜,失敗時一行 `got X, want Y`。測試要斷言**精確的結果**,不要只斷言「非零」或「有錯」。
- 覆蓋率門檻:domain 與 application 至少 80%,低於就讓 CI 失敗(Phase 1 加入)。
- 不要為了讓測試通過而改測試;測試失敗就修程式。

## 5. 安全與可觀測性

- **輸入驗證:** `json.Decoder.DisallowUnknownFields()` 加領域驗證,拒絕未知欄位。
- **Idempotency:** 所有改變狀態的 POST、PUT、PATCH 都支援 `Idempotency-Key`。
- **結構化 log:** 使用 `log/slog` 的 JSON 輸出,每行含 trace-id、時間戳;有使用者時含 user-id。
- **trace-id** 在請求入口產生,穿過每一層(handler、use case、repository)。
- **全域錯誤處理:** 一個 middleware 攔截所有錯誤、帶著 trace-id 寫 log,並回傳統一且清理過的回應,絕不外洩 stack trace。
- **機密:** 不得硬編碼任何密碼、金鑰、token、私鑰或連線字串,一律經環境變數注入。`.env.example` 只放佔位符並註明用途;`.env*` 已在 `.gitignore`。
  - 示範用的假值必須是明顯的佔位符(例如 `changeme`),並加 `FIXME: Replace with environment variable`;不要使用看似真實的亂數字串。
  - **文件與註解也受掃描。** 說明文字不要寫出會被規則匹配的完整範例(MEM-0003)。
- `make scan` 在本機掃,CI 的 gitleaks 掃歷史。發現憑證一律視為已外洩,撤銷並重新發行,不是只刪檔。

## 6. 開發循環

每個功能走 TDD:

1. **Red:** 先寫會失敗的測試。測試存在且失敗之前,不寫實作。
2. **Green:** 寫剛好讓測試通過的實作。允許假實作,但必須標 `// FIXME: Replace with real logic`。
3. **Refactor:** 消除重複、換掉假實作、補上重構時發現的邊界測試。重構後不得留下寫死的值。

每個功能的完整順序:設計、實作、單元測試、整合測試、自我 review。「完成」的定義見第 10 節。

## 7. 記憶與文件

- **MEM**(`.agents/memories/MEM-NNNN-topic.md`):決策、技術選擇、環境設定。同時當作 ADR 使用,不另外維護 ADR。
- **ERR**(`.agents/errors/ERR-YYYYMMDD-brief.md`):重大錯誤、陷阱與反模式,含根因、解法與預防。
- **SKILL**(`.agents/skills/SKILL-topic.md`):已驗證、可重複的流程。
- `todo.md`:目前 Phase 的待辦。`README.md`:長期計畫、進度與修訂紀錄。
- **雙向標註:** 新文件取代或修改舊文件時,新舊兩邊都要標註狀態並互相連結,不能只更新單邊。被取代的文件標為 Superseded,之後一律忽略。
- 設計或介面變動時,同步更新 `docs/` 裡對應的圖(Mermaid)與文件。程式在前,文件跟上。
- **Context Snapshot:** 對話超過約 50 則訊息、一個 Phase 結束、或大量工具呼叫之後,輸出一份摘要(已完成、進行中、待辦、關鍵決策、備註),確保可無縫接續。

## 8. Git 與 Commit

- 採用 **Phase Flow**:`main` 永遠穩定且可測試;每個 Phase 一個 `phase/N-name` 分支,經 PR 合併,合併後**保留分支**,並打 tag `phase-N-*`;最後打 `v0.1.0`。
- Conventional Commits:`<type>(<scope>): <subject>`,type 為 `feat`、`fix`、`test`、`refactor`、`docs`、`chore`。內文寫 what 與 why。
- **一個 commit 是一個完整、可測試的單元,而且訊息必須與內容相符。** 不要把工具、文件與程式塞進標題寫著 `docs` 的 commit。
- 只重寫自己的、尚未開 PR 的分支,並用 `--force-with-lease`。已合併或共用的歷史不得重寫。

## 9. 註解

- 解釋「為什麼」,不要重述程式碼做了什麼。1 到 2 行,完整句子,統一使用英文。
- 標記:`FIXME`(待替換的暫時邏輯)、`TODO`(待完成)、`NOTE`(設計原因或注意事項)。
- 行內註解只用在複雜或特殊的邏輯;區塊註解用在套件、型別、函式開頭,描述用途與設計意圖。
- 程式改了,註解要同步,過期的註解比沒有更糟。

## 10. 自動觸發與「完成」的定義

| 事件 | 自動動作 |
|---|---|
| 完成一個 TDD 循環 | 產生符合規範的 commit;必要時更新 `CHANGELOG.md` |
| 做出架構或技術決策 | 新增 MEM;更新架構圖 |
| 發現重大錯誤 | 新增 ERR |
| 識別出可重複的流程 | 新增 SKILL |
| 設計或介面變動 | 更新 `docs/` 與 README |
| Phase 結束 | 寫 `docs/reports/phase-N.md` 的 retrospective、更新 README 進度與修訂紀錄、請求確認、打 tag |

**宣稱「完成」之前:** `make check` 全綠;CI 全綠;MEM、README、`todo.md` 已同步;commit 訊息與內容相符;文件與註解中沒有可被掃描規則匹配的字面量。
