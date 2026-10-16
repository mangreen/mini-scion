# MEM: Secret scanning (`tools/scripts/scan-secrets.sh`)
Date: 2026-10-15
Status: Approved
Tags: [security, shell, ci, macos, testing]

## Summary
本機用 `scan-secrets.sh` 實作規範 §4.3 的「Code Review Gate」regex 掃描;CI 另用 gitleaks 補上 Git 歷史與高熵字串。這份文件記錄規則、取捨,以及寫 shell 掃描器時新手常踩、專家會留意的地方。

## Details

### Context & Evolution (脈絡與演進)
- 規範 §4.3 要求兩層防線:(1) Review 階段用 regex 掃 diff;(2) CI 用 Gitleaks/TruffleHog 掃歷史與 PR。
- 開發機是 macOS Big Sur(bash 3.2、BSD grep/find),Homebrew 對 Intel Mac 已不再提供新 bottle,所以本機**不安裝 gitleaks**,只用零依賴的 shell 腳本做第一層;第二層留給 GitHub Actions。
- 規範的 regex 直接使用會有誤報與漏報,因此做了下表的調整(偏離規範處皆有測試守住)。

### Specification

**契約(測試依賴它,不要隨意改)**

| Exit code | 意義 |
|---|---|
| 0 | 乾淨 |
| 1 | 發現疑似機密 |
| 2 | 掃描本身失敗(用法錯誤、檔案讀不了、`git`/`find` 失敗) |

輸出一律走 stderr,格式 `path:line: rule-name`。**絕不印出匹配到的內容。** 乾淨時完全安靜。

**掃描範圍**
- 在 git work tree 內:`git ls-files -z --cached --others --exclude-standard`,也就是「可能被 commit 的檔案」。被 `.gitignore` 的 `.env` 不掃(它不可能被提交,掃它只會讓每台開發機都失敗)。
- 不在 git 內(例如測試用暫存目錄):`find` 掃所有一般檔案,略過 `.git`、`node_modules`、`vendor`。
- 不跟隨 symlink;略過二進位檔(`grep -I`);已被 git 追蹤但磁碟上已刪除的檔案會被略過。

**規則(POSIX ERE,不分大小寫)**

| 規則 | 抓什麼 | 與規範 §4.3 的差異 |
|---|---|---|
| `password-assignment` | 關鍵字 password 後接 `=`、`:` 或 `:=`,值為引號包住的非空字串 | 允許關鍵字後有結尾引號,所以 JSON 的 `"key": "value"` 也會抓到;值不可為空 |
| `secret-assignment` | 同上,關鍵字 secret | 同上 |
| `api-key-assignment` | 同上,關鍵字 api_key / api-key / apikey | 同上 |
| `openai-style-key` | 前面不是英數字、`sk-` 之後連續 20 個以上英數字、底線或連字號 | 規範寫 `sk-[a-zA-Z0-9]`,會誤判 task-force、risk-adjusted 這類字;要求前導邊界與 20 字元長度 |
| `pem-private-key` | PEM 私鑰標頭,含 RSA/EC/OPENSSH 等變體 | 與規範相同,只是涵蓋所有變體 |
| `url-embedded-credentials` | URL 的 authority 區段內含「使用者、冒號、密碼、@」(資料庫連線字串、git remote 等) | 新增。規範 §4.3 禁止資料庫連線字串,但原本的 regex 清單沒有涵蓋 |

**例外機制:** 同一行含有 `scan-secrets:allow` 並寫明理由,該行不計入。這會留在 diff 裡,reviewer 看得到,所以不是靜默繞過。

**流程**
```text
list_files (NUL 分隔) -> 寫入暫存檔 -> 逐檔讀取
   每個檔案:  第 1 關: 合併 regex 的 grep -q   (乾淨檔案只花 1 次 fork)
              第 2 關: 只對有命中的檔案逐規則找行號
   結尾:      findings>0 -> exit 1;  errors>0 -> exit 2;  否則 exit 0
```

### 新手常犯的錯(以及本專案怎麼避免)

| # | 常見錯誤 | 後果 | 本專案的做法 |
|---|---|---|---|
| 1 | 測試用相對路徑呼叫腳本(`./scan-secrets.sh`) | 從不同的工作目錄執行,測試就找不到腳本 | 測試用 `BASH_SOURCE` 算出自己所在目錄 |
| 2 | 掃描器寫了 `set -e` | grep 回 1 代表「沒找到」是正常結果,第一個乾淨檔案就讓腳本中止 | 不用 `-e`,明確檢查每個 exit code |
| 3 | `cmd \| while read ...` 並在迴圈裡累加計數器 | 管線的迴圈在子 shell 執行,離開後計數器歸零,永遠回報「乾淨」 | 用重導向 `< file` 與 here-string `<<<` |
| 4 | `$f` 不加引號 | 檔名有空格就被拆成兩個參數 | 一律 `"$f"`;有測試覆蓋含空格的檔名 |
| 5 | 測試只檢查「exit code 不為 0」 | 腳本壞掉(127 找不到、2 出錯)被當成「抓到機密」,測試為錯誤的理由通過 | 斷言精確的 exit code;用法錯誤獨立使用 exit 2 |
| 6 | 把像機密的字串直接寫進測試檔 | 掃描器掃整個 repo 時掃到測試檔自己,`make scan` 永遠失敗 | fixture 在執行時由片段拼接 |
| 7 | 使用 `grep -P`、`\s`、`\d` | macOS 的 BSD grep 不支援或行為不同,本機與 CI 結果不一致 | 只用 POSIX ERE 與 `[[:space:]]`、`[[:alnum:]]` |
| 8 | 用 `find ... \| xargs grep` | 沒有任何檔案時,GNU 與 BSD 的 xargs 行為不同;grep 沒有檔名參數會去讀 stdin 而卡住 | 完全不用 xargs,自己逐檔迴圈 |
| 9 | `set -u` 搭配空陣列 `"${arr[@]}"` | bash 3.2(macOS 預設)會報 unbound variable | 迴圈只展開確定非空的陣列 |
| 10 | 發現機密時把那一行印出來 | CI 日誌常是公開的,等於又洩漏一次 | 只輸出 `path:line: rule` |
| 11 | 以為 `echo` 的行為各 shell 一致 | 在不同 shell 對反斜線與 `-n` 的處理不同 | 一律用 `printf '%s\n'` |

### 專家會留意的地方

1. **Fail-closed。** 檔案清單若用 `done < <(list_files)` 產生,`git` 或 `find` 失敗時迴圈只會讀到空輸入,掃描器回報「乾淨」。我們先把清單寫入暫存檔並檢查產生者的 exit code,失敗就回 2。安全工具的預設必須是「不確定就失敗」。
2. **Exit code 是 API。** 0/1/2 分開,CI 與 Makefile 才能區分「有機密」和「工具壞了」。
3. **規則只是啟發式。** 它抓不到:沒有引號的 `.env` 風格賦值、base64 或被拆開的字串、高熵 token。所以還需要 `.gitignore` 擋住 `.env`、gitleaks 在 CI 補位。regex 通過不代表安全。
4. **掃描範圍就是威脅模型。** 掃「可能被 commit 的檔案」比「磁碟上所有檔案」更貼近要防的事。
5. **歷史才是真正的風險。** 機密一旦 commit 並 push,刪檔沒有用,必須撤銷並重新發行(rotate)金鑰。本機掃描只擋得住「還沒進歷史」的部分。
6. **`LC_ALL=C`。** BSD grep 遇到非 UTF-8 位元組會報錯並回 2;固定為位元組模式更穩定,也更快。
7. **效能取捨。** 每個檔案至少一次 grep(fork);對教學規模的 repo 沒問題。repo 變大時可改成 `find -exec grep ... {} +` 批次處理,但要重新處理 exit code 的區分,這是刻意留下的簡單版。
8. **例外必須留痕。** `scan-secrets:allow` 寫在程式碼行上,會出現在 diff 與 code review 裡。不要改成獨立的 ignore 檔,那種檔案很容易被默默加長。
9. **不跟隨 symlink。** 否則 repo 內的連結可以讓掃描器去讀(並可能輸出)樹外的檔案。

### 測試策略與變異驗證
`tools/scripts/scan-secrets_test.sh` 共 18 個案例:乾淨、空目錄、相似但不該誤報、例外標記、6 種偵測規則、含空格的檔名、輸出不洩漏數值、symlink、git 模式(ignore、untracked、已刪除的追蹤檔)、兩種用法錯誤。

寫完後用「變異」驗證測試本身有效。以下 5 種把腳本故意改壞的版本,都被測試抓出來:
- 永遠回 0;永遠回 1;
- `sk-` 規則還原成規範的寫法(被 near-miss 案例抓到);
- 輸出匹配到的內容(被洩漏檢查抓到);
- 忽略 `.gitignore`(被 git 案例抓到);
- 允許空值(被 near-miss 案例抓到)。

### 吃自己的狗糧(dogfooding)發現的問題
單元測試全綠之後,對整個專案跑一次掃描,仍然抓到兩處誤報:腳本裡的註解與本文件,都為了說明 URL 規則而寫出完整範例,被規則本身匹配。教訓:**說明文字與測試 fixture 一樣,不能含有可被匹配的字面量**;`make scan` 要持續掃整個專案,而不只是測試案例。

### Known limitations
- 在 Linux(GNU 工具,bash 5.2)與 `shellcheck` 下驗證過;並已在開發機(macOS 11.7.11、bash 3.2、BSD grep)以 `make check` 實測通過。
- 非 UTF-8 檔名、超大檔案、二進位檔中的機密不處理。
- 尚未接 pre-commit hook;CI 以 gitleaks 補足,見 Step 0.5。

## When to Use
- 修改 `scan-secrets.sh` 或其測試之前,先讀這份。
- 新增規則時:先在測試檔寫 fixture(以片段拼接)與 near-miss,再改腳本。
- 若本文件被標為 Superseded,請忽略它。
