# NBINet ISBN 書目批次下載與匯出工具

## 目的

批次查詢 NBINet 圖書館書目系統，把每本書的書目資料整理成一份 Excel 可直接開啟的 CSV 表格。

---

## 使用環境

- Windows 10 + 內建 PowerShell（不需安裝任何額外套件）
- 準備好 `isbn.csv`（每行一筆：`登錄號,ISBN`）
- 雙擊 `launch.cmd` 即自動執行全流程

---

## 兩階段流程

### 第一階段：下載書目（scrape.ps1）

1. 讀取 `isbn.csv` 的 ISBN 清單
2. 逐一到 NBINet 搜尋 → 進入書目細項頁 → 點「MARC 顯示」
3. 把 MARC 純文字存成 `grabbed_isbn/{ISBN}.txt`，原始 HTML 存成 `grabbed_isbn/{ISBN}.html`
4. 每本間隔 0.5～0.9 秒；失敗自動重試 3 次；錯誤記入 `scrape.log`

### 第二階段：解析輸出（parse.ps1）

1. 讀取每本的 `grabbed_isbn/{ISBN}.txt`
2. 依 `fields.conf` 的欄位定義，解析書名、作者、出版資訊、主題等
3. 自動辨識 MARC21 或 UNIMARC 格式
4. 匯出 `marc_output.csv`（UTF-8 BOM，可直接用 Excel 開啟）；錯誤記入 `parse.log`

---

## 檔案一覽

| 檔案 | 說明 |
|---|---|
| `isbn.csv` | 輸入：每行 `登錄號,ISBN` |
| `fields.conf` | 設定：CSV 欄位映射規則 |
| `grabbed_isbn/` | Phase 1 輸出：`.txt` 與 `.html` |
| `marc_output.csv` | Phase 2 輸出：書目表格 |
| `scrape.log` / `parse.log` | 執行日誌 |
| `launch.cmd` | 一鍵執行入口 |
| `data/` | 外部參考資料目錄（詳見 `data/SOURCES.md`） |
| `data/Unihan_DictionaryLikeData.txt` | Unicode Unihan 資料庫，供四角號碼查表使用 |
| `data/SOURCES.md` | 資料來源與更新說明 |

---

## isbn.csv 格式

每行兩欄，以逗號分隔：

```
登錄號,ISBN
TEST001,9789864798087
TEST002,9789864795277
TEST003,9786267255384
```

---

## 變更記錄

### 目前版本
- 新增「作者首字四角號碼」欄位：取作者首字並查 Unicode Unihan 四角號碼（`kFourCornerCode`）
- 新增 `data/` 目錄存放 `Unihan_DictionaryLikeData.txt`，並附 `data/SOURCES.md` 說明來源與更新方式
- `parse.ps1` 新增 `-UnihanFile` 參數（預設：`.\data\Unihan_DictionaryLikeData.txt`）

### 前一版本
- `isbn.csv` 改為兩欄格式（登錄號,ISBN）；登錄號直接填入 CSV 第一欄
- 第一階段輸出改存至 `grabbed_isbn/` 子目錄（不存在時自動建立）
- `launch.cmd` 直接呼叫 `scrape.ps1`，移除中間層 `run.ps1`

### v3.4-fix3
- 修正 PS 5.1 `Join-Path` 只接受兩個位置參數的限制（改為先組 `$libDir`，再 `Join-Path $libDir 'http.ps1'`）
- 保留 v3.4-fix2 的 `Invoke-WebRequestCompat` 與強制陣列化的 ISBN 清單、log 分流等
