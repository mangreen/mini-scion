# MEM: Testing discipline
Date: 2026-10-15
Status: Approved
Tags: [testing, concurrency, go, tdd]

## Summary
測試一律帶 `-race`;並發測試必須同時有結果斷言與 race detector;新測試要用「故意弄壞實作」驗證它真的會失敗。

## Details

### Context & Evolution (脈絡與演進)
Phase 0 的實驗:十個 goroutine 對同一個計數器累加,先不加鎖、再加 `sync.Mutex`、最後移除鎖。觀察到:

| 情況 | 不帶 `-race`,重複 100 次 | 帶 `-race`,重複 100 次 |
|---|---|---|
| 沒有鎖 | 只有 3 次算錯(`got 9, want 10`),其他 97 次通過 | 立即報 `DATA RACE`,並且同時有更多次數值錯誤 |
| 有鎖 | 全部通過 | 全部通過 |

結論:沒有 `-race` 時,測試靠「剛好撞上」才會失敗,CI 單次執行亮綠燈的機率約 97%,但 bug 還在。

### Specification
1. `make test` 固定為 `go test -race -count=1 ./...`。`-count=1` 繞過測試快取,避免舊結果造成誤判。
2. 並發測試(Phase 3 的 CAS、idempotency)要有兩層:**結果斷言**(例如 10 個請求只有 1 個成功)加上 **`-race`**。需要時用 `-count=N` 重複執行。
3. 新測試寫完要做一次變異驗證:暫時把被測邏輯改壞(拿掉鎖、改比較運算子),確認測試會失敗,再還原。
4. 風格:Arrange / Act / Assert 以空行分段;通過時安靜,失敗時一行 `got X, want Y`;名稱 `should_<behavior>_when_<condition>`(Go 中即 `TestShould...When...`)。
5. 鎖的預設寫法:`mu.Lock()` 後面立刻接 `defer mu.Unlock()`。只有在臨界區極短且不可能 panic 或提前 return 時才手動解鎖。
6. 註解只寫「為什麼」。程式改了,註解要同步,過期的註解比沒有更糟。
7. `gofmt -l .` 與 `go vet ./...` 是 `make lint` 的一部分。

### 新手常犯的錯
| 錯誤 | 為什麼有問題 | 作法 |
|---|---|---|
| 只靠最終數字判斷並發程式是否正確 | 結果「碰巧正確」不代表沒有 race | 加上 `-race` |
| `WaitGroup` 等於同步了 | 它只保證「等大家做完」,不保護共享資料 | 另外用 Mutex 或 atomic |
| 迴圈裡手動 `Unlock()`,中間有 `return` | 提前離開會讓鎖永遠不被釋放 | `defer` |
| 一個測試通過一次就信任 | 並發 bug 是機率性的 | `-count=N`,並做變異驗證 |
| 測試通過時印出一堆訊息 | 全專案累積後無法在日誌中找到真正的失敗 | 通過保持安靜 |

### 專家會留意的地方
- 同一個 race 只會被報告一次,所以警告「數量」不代表嚴重度;出現一次就是 bug。
- race detector 會拖慢執行並改變排程,所以它「沒報」不等於「沒有」;它是偵測工具,不是證明。
- 變異驗證是在測「測試」本身:拿掉保護後測試仍通過,就代表這個測試沒有保護力。
- 好的測試對照的是行為契約,不是實作細節,否則重構一次就要重寫一次。

## When to Use
- 寫任何涉及並發、鎖、CAS 或 idempotency 的程式與測試之前。
- 設定 Makefile 與 CI 的測試指令時。
- 若本文件被標為 Superseded,請忽略它。
