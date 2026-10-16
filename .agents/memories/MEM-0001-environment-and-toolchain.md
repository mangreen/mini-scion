# MEM: Environment and toolchain
Date: 2026-10-15
Status: Approved
Tags: [environment, go, macos, docker]

## Summary
開發機是 macOS 11.7.11 的 2014 年 MacBook Pro,因此專案固定使用 Go 1.24.x、零第三方依賴、不把 Docker 與 Homebrew 放進主線。

## Details

### Context & Evolution (脈絡與演進)
- 機器:MacBook Pro (Retina, 13-inch, Mid 2014)、雙核 i7 3 GHz、16 GB、macOS Big Sur 11.7.11。
- Go 1.24 是最後一個支援 macOS 11 的版本;Go 1.25 起需要 macOS 12。Go 1.24 已不再收到安全修補,所以 server 只綁 loopback。
- Homebrew 對 Intel Mac 已是 Tier 3,新套件可能得從原始碼編譯,不作為依賴。
- Docker Desktop 4.12.0 (Engine 20.10.17) 已安裝,實測 `docker run hello-world` 成功,但版本舊、雙核負擔大,所以只作為可選工具。
- 初版計畫曾假設 Go 1.24 與 Docker 都不可用,實測後更正為上述結論。

### Specification
| 項目 | 決定 | 驗證 |
|---|---|---|
| Go | 1.24.13(darwin/amd64),透過 gvm 管理 | `go version` |
| `go.mod` | `go 1.24.13` | 檔案內容 |
| 工具鏈鎖定 | `go env -w GOTOOLCHAIN=local`,避免自動下載跑不動的新工具鏈 | `go env GOTOOLCHAIN` 回傳 `local` |
| 依賴 | 只用標準庫 | `go.mod` 沒有 `require` |
| C 工具鏈 | 完整 Xcode 已安裝,`CGO_ENABLED=1` | `-race` 能抓到 data race |
| Git | 2.32.0 (Apple Git-132) | `git --version` |
| Shell 腳本 | 必須相容 bash 3.2 與 BSD 工具 | 見 MEM-0003 |
| Docker | 可選;設定上限 2 CPU、4 GB;不使用時退出;關閉 Kubernetes | `docker run hello-world` |
| 網路 | `SCION_ADDR` 預設 `127.0.0.1:8080`,不對外開放 | `.env.example` |
| CI | GitHub Actions(雲端),同時跑 Go 1.24 與最新穩定版 | Step 0.5 |

### 新手常犯的錯
| 錯誤 | 後果 | 作法 |
|---|---|---|
| 升級 Go 後 `go.mod` 多了 `toolchain` 行,`go` 指令自動下載新工具鏈 | 下載的版本在 Big Sur 上執行失敗,錯誤訊息難懂 | `GOTOOLCHAIN=local` |
| `go get` 一個新套件 | 套件的 `go` 指令版本高於 1.24,拉高 `go.mod` | 不引入第三方依賴 |
| 以為 Docker 能跑就把它放進測試流程 | 舊 Engine 與雙核機器變成瓶頸,測試變慢又不穩 | 測試只用 `t.TempDir()` 與 `httptest` |

### 專家會留意的地方
- 把「環境限制」寫成文件,而不是留在腦中:未來換機器時,這份就是要被 Supersede 的對象。
- 舊版 Go 沒有安全更新,所以用網路邊界(loopback)降低風險,並且不處理不受信任的輸入以外的場景。
- CI 同時跑「本機底線版本」與「最新版」,可提早發現相容性問題。

## When to Use
- 換機器、升級 macOS 或 Go 之前。
- 遇到版本、工具鏈或 Docker 相關問題時。
- 若本文件被標為 Superseded,請忽略它。
