param(
  [string]$InputFile      = ".\isbn.txt",
  [string]$UserAgent      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShellScraper/1.0",
  [string]$AcceptLanguage = "zh-TW",
  [int]$MinDelayMs = 500,
  [int]$MaxDelayMs = 900,
  [int]$MaxRetry = 3,
  [double]$InitialRetrySec = 3.0,
  [double]$RetryBackoff = 1.5
)
$ErrorActionPreference = 'Continue'
$VerbosePreference = 'Continue'
$transcriptPath = Join-Path $PSScriptRoot 'transcript.log'
try { Start-Transcript -Path $transcriptPath -Append -Force | Out-Null } catch {}

Write-Host "[BOOT] run.ps1 starting at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "[BOOT] PSScriptRoot=$PSScriptRoot"
Write-Host "[BOOT] PSVersion=$($PSVersionTable.PSVersion); Edition=$($PSVersionTable.PSEdition); LanguageMode=$((Get-Variable ExecutionContext -ValueOnly).SessionState.LanguageMode)"
Write-Host "[BOOT] ExecutionPolicy(Proc)=$(Get-ExecutionPolicy -Scope Process); (LocalMachine)=$(Get-ExecutionPolicy -Scope LocalMachine)"

try { Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | Unblock-File -ErrorAction SilentlyContinue; Write-Host "[BOOT] Unblock-File done" } catch { Write-Host "[BOOT] Unblock-File error: $($_.Exception.Message)" }

Write-Host "[BOOT] Args: -InputFile=$InputFile -UserAgent=$UserAgent -AcceptLanguage=$AcceptLanguage -MinDelayMs=$MinDelayMs -MaxDelayMs=$MaxDelayMs -MaxRetry=$MaxRetry -InitialRetrySec=$InitialRetrySec -RetryBackoff=$RetryBackoff"

$script = Join-Path $PSScriptRoot 'scrape.ps1'
if (-not (Test-Path $script)) { Write-Host "[FATAL] 找不到 scrape.ps1：$script"; try { Stop-Transcript | Out-Null } catch {}; exit 1 }
if (-not (Test-Path $InputFile)) { Write-Host "[FATAL] 找不到輸入檔：$InputFile"; try { Stop-Transcript | Out-Null } catch {}; exit 1 }

$exit = 0
Write-Host "[BOOT] Invoking scrape.ps1 ..."
try {
  & $script `
    -InputFile $InputFile `
    -UserAgent $UserAgent `
    -AcceptLanguage $AcceptLanguage `
    -MinDelayMs $MinDelayMs -MaxDelayMs $MaxDelayMs `
    -MaxRetry $MaxRetry -InitialRetrySec $InitialRetrySec -RetryBackoff $RetryBackoff
  $exit = $LASTEXITCODE
  Write-Host "[BOOT] scrape.ps1 returned exit=$exit"
} catch {
  Write-Host "[FATAL] 未攔截的例外：$($_.Exception.Message)"
  $exit = 1
}

try { Stop-Transcript | Out-Null } catch {}
exit $exit
