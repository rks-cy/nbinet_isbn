# NCL nbinet3 ISBN → MARC 批次抓取（PowerShell 5.1）

**本版修正 v2**
- 修正 `mshtml` 將相對連結展開為 `about:` 絕對位址造成 404：優先取 `getAttribute('href')`、HTML 解碼、去除 `about:` 前綴，再組絕對 URL。
- 修正 `Start-Sleep -Seconds [int][math]::Ceiling($delay)` 在 PS 5.1 的參數繫結錯誤：改為 `Start-Sleep -Seconds ([int][math]::Ceiling($delay))`。

## 特色
- 無 Selenium、無 HtmlAgilityPack，純 `Invoke-WebRequest` + DOM/正則解析。
- 先 GET `opacmenu_cht.html` 建立 cookies 與中文介面；再以 `searchtype=i&searcharg={ISBN}&searchscope=1` 查詢。
- 取第一筆 `.briefcitTitle a` → 細項頁 → 找「MARC 顯示」 → 進入 MARC 頁。
- 擷取 `<pre>` 內容存 `{ISBN}.txt`，另存原始 `{ISBN}.html`。
- 無結果判定、分頁偵測、節流、重試、互動模式（可關閉）。

## 檔案結構
```
nbinet3_scraper_v2\
  scrape.ps1
  isbn.txt
  lib\
    http.ps1
    parse.ps1
  README.md
```
