# data/ 目錄 — 外部參考資料說明

此目錄存放從外部來源取得、供腳本查表使用的靜態資料檔案。

---

## Unihan_DictionaryLikeData.txt

| 項目 | 說明 |
|---|---|
| **用途** | 漢字四角號碼查表（`kFourCornerCode` 欄位），供 `parse.ps1` 輸出「作者首字四角號碼」欄位使用 |
| **使用腳本** | `parse.ps1`（透過 `-UnihanFile` 參數指定路徑） |
| **格式版本** | Unicode Unihan Database（Tab 分隔純文字） |

### 下載來源

Unicode 官方下載頁：
```
https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip
```

解壓縮後，取出壓縮檔內的 `Unihan_DictionaryLikeData.txt`，置於本目錄即可。

### 更新方式

直接以新版檔案覆蓋 `data/Unihan_DictionaryLikeData.txt`，腳本下次執行時會自動讀取新版資料。格式自 Unicode 3.x 以來向下相容，無需修改腳本。

---

## 查詢單一字元的四角號碼

若需確認特定漢字的四角號碼，可使用 Unicode 官方查詢頁面：

```
https://www.unicode.org/cgi-bin/GetUnihanData.pl?codepoint=張
```

將 URL 最後的字元（`張`）替換為欲查詢的字，開啟頁面後尋找 **`kFourCornerCode`** 欄位，其值即為該字的四角號碼。

範例：

| 字 | 查詢 URL | kFourCornerCode |
|---|---|---|
| 迪 | https://www.unicode.org/cgi-bin/GetUnihanData.pl?codepoint=迪 | 3530.6 |
| 陳 | https://www.unicode.org/cgi-bin/GetUnihanData.pl?codepoint=陳 | 7529.6 |
| 郭 | https://www.unicode.org/cgi-bin/GetUnihanData.pl?codepoint=郭 | 0742.7 |
| 張 | https://www.unicode.org/cgi-bin/GetUnihanData.pl?codepoint=張 | 1123.2 |
