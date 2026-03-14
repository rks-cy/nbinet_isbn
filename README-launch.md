# 一鍵雙擊啟動（不需 cd）

- **launch.cmd**：雙擊即可，會在腳本所在資料夾執行 `scrape.ps1`，自動套用參數與 UTF-8 輸出。
- **launch_silent.vbs**（可選）：雙擊後以隱藏視窗啟動 `launch.cmd`（背景執行）。

## 說明
- `launch.cmd` 會：
  1) 切到腳本所在資料夾
  2) 以「僅限本次視窗」的方式繞過執行原則
  3) 設定主控台輸出為 UTF-8
  4) 呼叫 `scrape.ps1` 並帶入參數
- 你可把 `isbn.txt` 放在同一資料夾，雙擊 `launch.cmd` 即可。
