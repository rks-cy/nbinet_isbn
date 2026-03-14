@echo off
setlocal
echo [INFO] 初始化啟動器...
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { if (-not (Test-Path '%~dp0transcript.log')) { Set-Content -Path '%~dp0transcript.log' -Value '' -Encoding utf8 } } catch { }"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { if (-not (Test-Path '%~dp0scrape.log')) { Set-Content -Path '%~dp0scrape.log' -Value '' -Encoding utf8 } } catch { }"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" ^
  -InputFile "%~dp0isbn.txt" ^
  -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShellScraper/1.0" ^
  -AcceptLanguage "zh-TW" ^
  -MinDelayMs 500 -MaxDelayMs 900 ^
  -MaxRetry 3 -InitialRetrySec 3 -RetryBackoff 1.5

set ERR=%errorlevel%

echo.
echo ================== [Transcript Tail] ==================
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'--- transcript.log (tail 80) ---'; if (Test-Path '%~dp0transcript.log') { Get-Content -Path '%~dp0transcript.log' -Tail 80 | Out-String | Write-Host } else { Write-Host 'transcript.log 不存在。' }"

echo.
echo ================== [Scrape Log Tail] ==================
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'--- scrape.log (tail 80) ---'; if (Test-Path '%~dp0scrape.log') { Get-Content -Path '%~dp0scrape.log' -Tail 80 | Out-String | Write-Host } else { Write-Host 'scrape.log 不存在。' }"

echo.
if %ERR% NEQ 0 (
  echo [ERROR] 任務執行發生錯誤（errorlevel=%ERR%）。
  pause
) else (
  echo [INFO] 任務完成。按任意鍵關閉...
  pause
)
endlocal
