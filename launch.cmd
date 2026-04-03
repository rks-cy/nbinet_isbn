@echo off
chcp 65001 > nul
setlocal
echo [INFO] 初始化啟動器...
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { if (-not (Test-Path '%~dp0scrape.log')) { Set-Content -Path '%~dp0scrape.log' -Value '' -Encoding utf8 } } catch { }"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scrape.ps1" ^
  -InputFile "%~dp0isbn.txt" ^
  -OutputDir "%~dp0grabbed_isbn" ^
  -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShellScraper/1.0" ^
  -AcceptLanguage "zh-TW" ^
  -MinDelayMs 500 -MaxDelayMs 900 ^
  -MaxRetry 3 -InitialRetrySec 3 -RetryBackoff 1.5

set ERR=%errorlevel%

echo.
echo ================== [Scrape Log Tail] ==================
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'--- scrape.log (tail 80) ---'; if (Test-Path '%~dp0scrape.log') { Get-Content -Path '%~dp0scrape.log' -Tail 80 | Out-String | Write-Host } else { Write-Host 'scrape.log not found.' }"

echo.
if %ERR% NEQ 0 (
  echo [ERROR] Phase 1 執行發生錯誤（errorlevel=%ERR%），跳過 Phase 2。
  pause
  endlocal
  exit /b %ERR%
)

echo [INFO] Phase 1 完成，開始執行 Phase 2（MARC → CSV）...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0parse.ps1" ^
  -IsbnFile "%~dp0isbn.txt" ^
  -InputDir "%~dp0grabbed_isbn" ^
  -FieldsConf "%~dp0fields.conf" ^
  -OutputCsv "%~dp0marc_output.csv"

set ERR2=%errorlevel%

echo.
echo ================== [Parse Log Tail] ==================
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'--- parse.log (tail 40) ---'; if (Test-Path '%~dp0parse.log') { Get-Content -Path '%~dp0parse.log' -Tail 40 | Out-String | Write-Host } else { Write-Host 'parse.log not found.' }"

echo.
if %ERR2% NEQ 0 (
  echo [ERROR] Phase 2 執行發生錯誤（errorlevel=%ERR2%）。
  pause
) else (
  echo [INFO] 全部完成。輸出檔案：%~dp0marc_output.csv
  echo [INFO] 按任意鍵關閉...
  pause
)
endlocal
