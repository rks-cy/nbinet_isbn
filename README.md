# NBINet ISBN 書目批次下載與匯出工具

## 目的

批次查詢 NBINet 圖書館書目系統（Primo VE），把每本書的書目資料整理成一份 Excel 可直接開啟的 CSV 表格。

---

## 使用環境

- Windows 10 + 內建 PowerShell（不需安裝任何額外套件）
- 準備好 `isbn.csv`（每行一筆：`登錄號,ISBN`）
- 雙擊 `launch.cmd` 即自動執行全流程

---

## 資料來源

- 站台：https://nbinet.primo.exlibrisgroup.com
- View ID：`886NCL_NBINET:NBINET`
- 搜尋 API：`/primaws/rest/pub/pnxs`（參數使用 `scope=`，不是 `search_scope=`）
- 機讀格式 API：`/primaws/rest/pub/sourceRecord?docId=alma…&vid=…`
- 同一 ISBN 若命中多筆，**只取搜尋結果第一筆**

---

## 兩階段流程

### 第一階段：下載書目（scrape.ps1）

1. 讀取 `isbn.csv` 的 ISBN 清單
2. 逐一呼叫 Primo 搜尋 API → 取第一筆 `recordid` → 下載 `sourceRecord` MARC 純文字
3. 把 MARC 純文字存成 `grabbed_isbn/{ISBN}.txt`，搜尋 JSON 存成 `grabbed_isbn/{ISBN}.json`
4. 每本間隔 0.5～0.9 秒；失敗自動重試 3 次；錯誤記入 `scrape.log`

### 第二階段：解析輸出（parse.ps1）

1. 讀取每本的 `grabbed_isbn/{ISBN}.txt`（Primo `leader\t` / `$a` 分欄格式）
2. 依 `fields.conf` 的欄位定義，解析書名、作者、出版資訊、主題等
3. 自動辨識 MARC21 或 UNIMARC 格式
4. 匯出 `marc_output.csv`（UTF-8 BOM，可直接用 Excel 開啟）；錯誤記入 `parse.log`

---

## 檔案一覽

| 檔案 | 說明 |
|---|---|
| `isbn.csv` | 輸入：每行 `登錄號,ISBN` |
| `fields.conf` | 設定：CSV 欄位映射規則 |
| `grabbed_isbn/` | Phase 1 輸出：`.txt`（MARC）與 `.json`（搜尋結果） |
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

## fields.conf 格式說明

每個欄位定義由**欄位名稱行**加上選用的**選項行**（恰好 4 個空格縮排）組成。

### 來源格式

| 格式 | 說明 | 範例 |
|---|---|---|
| `TAGsf` | MARC tag + 子欄碼 | `245a`、`200ahe`、`490av` |
| `008[N:L]` | 008 控制欄位段落，偏移 N 起取 L 碼 | `008[07:4]`（西元年）、`008[35:3]`（語言） |

同一欄位可列多個來源（空格分隔），依優先序由左至右。

### 選項

| 選項 | 說明 |
|---|---|
| `TAKE=first` | （預設）同一 TAG 有多筆時只取第一筆 |
| `TAKE=all` | 同一 TAG 有多筆時全部收集，以 `JOIN` 串接 |
| `JOIN=<分隔符>` | `TAKE=all` 時多筆之間的分隔符（預設 `；`） |
| `SUBFIELD_JOIN= ` | 同一筆中多個子欄值以**空格**串接（等號後接一個空格） |
| `SUBFIELD_JOIN=` | 同一筆中多個子欄值**直接串接**（等號後無字元） |
| `SOURCES_JOIN= ` | 啟用跨來源合併模式：對每個來源各取第一個非空值，以**空格**串接所有結果。適用於需同時顯示書名與並列題名的欄位（見 `全書名`）。設定後 `TAKE` 與 `JOIN` 被忽略。 |
| `TRANSFORM=T1,T2,...` | 依序套用資料轉換（見下表） |

### TRANSFORM 轉換名稱

| 名稱 | 說明 |
|---|---|
| `HTML_DECODE` | 解碼 HTML 實體（`&amp;` 等） |
| `STRIP_PUNCT` | 去除首尾 `/` `:` `,` `;` `。` `，` `、` 等常見標點 |
| `ISBN_CLEAN` | 去除連字號與空格，驗證 10 或 13 碼 |
| `YEAR_CE` | 從字串中提取四位數西元年 |
| `YEAR_ROC` | 從字串中提取四位數西元年並換算為民國年 |
| `BINDING` | 裝訂描述正規化為 `平裝`／`精裝`／`套裝`／`其他` |
| `FOUR_CORNER_INT` | 查 Unicode Unihan 四角號碼（只取整數部分） |

---

## 變更記錄

### 目前版本
- 資料來源改為 NBINet Primo VE（`nbinet.primo.exlibrisgroup.com`）
- Phase 1 改呼叫 `pnxs` + `sourceRecord` REST API；輸出 `.txt` + `.json`
- Phase 2 MARC 解析改為只支援 Primo 機讀格式（`leader\t`、tab 分隔、`$` 分欄）
- 分欄邏輯修正：只以小寫字母（`$a`–`$z`）為子欄分隔符，避免貨幣符號 `NT$200` 被誤判為子欄 `$2`；並自動清除殘留的控制子欄尾綴（如 ` $2ncsclt`）
- `fields.conf` 補充 RDA 編目使用的 `264` 欄位：出版地 / 出版社 / 出版西元年 / 出版民國年 現在同時嘗試 `260`（舊式）與 `264`（RDA）
- `fields.conf` 新增 `SOURCES_JOIN` 選項（見下方 fields.conf 格式說明），並以此修正 `全書名` 欄位：現在輸出「書名 + 並列題名」合併結果
- `lib/http.ps1` 全面加入 `TimeoutSec`（預設 30 秒）避免 HTTP 請求無限期卡住；`Invoke-GetWithRetry` 內建中文重試日誌

---

## 已知空白說明

以下情況為 MARC 紀錄本身未填寫，並非程式問題：

| 欄位 | 說明 |
|---|---|
| 作者號 | 取自本館 `949$d$e`；需有本館館藏才有值 |
| 版本 | 取自 `250$a`；CIP 預行編目紀錄（含 `263` 欄位）常省略版本欄位 |

### 前一版本
- 新增「作者首字四角號碼」欄位：取作者首字並查 Unicode Unihan 四角號碼（`kFourCornerCode`）
- 新增 `data/` 目錄存放 `Unihan_DictionaryLikeData.txt`，並附 `data/SOURCES.md` 說明來源與更新方式
- `parse.ps1` 新增 `-UnihanFile` 參數（預設：`.\data\Unihan_DictionaryLikeData.txt`）
- `isbn.csv` 改為兩欄格式（登錄號,ISBN）；登錄號直接填入 CSV 第一欄
- 第一階段輸出改存至 `grabbed_isbn/` 子目錄（不存在時自動建立）
- `launch.cmd` 直接呼叫 `scrape.ps1`，移除中間層 `run.ps1`
