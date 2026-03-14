@echo off
setlocal
REM === 切換到本批次檔所在資料夾 ===
cd /d %~dp0

REM === 僅限本次執行繞過執行原則，並呼叫 scrape.ps1 ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8; ^
    & '%~dp0scrape.ps1' ^
      -InputFile '%~dp0isbn.txt' ^
      -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShellScraper/1.0' ^
      -AcceptLanguage 'zh-TW' ^
      -MinDelayMs 500 -MaxDelayMs 900 ^
      -MaxRetry 3 -InitialRetrySec 3 -RetryBackoff 1.5 ^
      -AppendLog:$false ^
      -Interactive:$false"

if %errorlevel% neq 0 (
  echo.
  echo [ERROR] 任務執行發生錯誤（errorlevel=%errorlevel%）。請檢查 scrape.log 或 *.error.html 檔案。
  pause
) else (
  echo.
  echo [INFO] 任務完成。按任意鍵關閉...
  pause
)
endlocal
