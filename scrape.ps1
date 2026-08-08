param(
  [string]$InputFile      = ".\isbn.csv",
  [string]$OutputDir      = ".\grabbed_isbn",
  [string]$UserAgent      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShellScraper/1.0",
  [string]$AcceptLanguage = "zh-TW",
  [hashtable]$ExtraHeaders = @{},
  [int]$MinDelayMs = 500,
  [int]$MaxDelayMs = 900,
  [int]$MaxRetry = 3,
  [double]$InitialRetrySec = 3.0,
  [double]$RetryBackoff = 1.5,
  [int]$TimeoutSec = 30,
  [switch]$AppendLog = $false,
  [switch]$Interactive = $false
)
Write-Host "[SCRAPE] script started"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'

$scriptDir = $PSScriptRoot
$logPath   = Join-Path $scriptDir 'scrape.log'
if (-not $AppendLog) { "" | Out-File -FilePath $logPath -Encoding utf8 }
function Write-Log { param([ValidateSet('INFO','WARN','ERROR')] [string]$Level, [string]$Message); $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); $line = "[$ts] [$Level] $Message"; Write-Host $line; Add-Content -Path $logPath -Value $line -Encoding utf8 }
Write-Log -Level 'INFO' -Message "Scrape.ps1 啟動，PSScriptRoot=$scriptDir"

try { $inputPath = Resolve-Path -Path $InputFile -ErrorAction Stop } catch { Write-Log -Level 'ERROR' -Message "無法解析輸入檔路徑：$InputFile ；錯誤：$($_.Exception.Message)"; exit 1 }
$resolvedOutputDir = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $OutputDir)) }
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null
Write-Log -Level 'INFO' -Message "輸出目錄：$resolvedOutputDir"

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'http.ps1')
. (Join-Path $libDir 'parse.ps1')

$BaseOrigin = "https://nbinet.primo.exlibrisgroup.com"
$Vid        = "886NCL_NBINET:NBINET"
$WarmupUrl  = "$BaseOrigin/nde/home?vid=$Vid&lang=zh-tw"

function New-JsonHeaders {
  param([string]$Ref = $null)
  $h = @{
    'User-Agent'      = $UserAgent
    'Accept-Language' = $AcceptLanguage
    'Accept'          = 'application/json, text/plain, */*'
  }
  if ($Ref) { $h['Referer'] = $Ref }
  if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
  return $h
}

function New-TextHeaders {
  param([string]$Ref = $null)
  $h = @{
    'User-Agent'      = $UserAgent
    'Accept-Language' = $AcceptLanguage
    'Accept'          = 'text/plain, */*'
  }
  if ($Ref) { $h['Referer'] = $Ref }
  if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
  return $h
}

function Normalize-Isbn {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $s = ($Raw -replace '[\s-]', '').Trim().ToUpper()
  if ($s -match '^\d{13}$') { return $s }
  if ($s -match '^\d{9}[\dX]$') { return $s }
  return $null
}

function Build-PrimoSearchUrl {
  param([string]$Isbn)
  $q = [uri]::EscapeDataString("any,contains,$Isbn")
  $vidEsc = [uri]::EscapeDataString($Vid)
  return "$BaseOrigin/primaws/rest/pub/pnxs?q=$q&tab=LibraryCatalog&scope=MyInstitution&vid=$vidEsc&lang=zh-TW&offset=0&limit=10"
}

function Build-PrimoSourceRecordUrl {
  param([string]$DocId)
  $vidEsc = [uri]::EscapeDataString($Vid)
  $docEsc = [uri]::EscapeDataString($DocId)
  return "$BaseOrigin/primaws/rest/pub/sourceRecord?docId=$docEsc&vid=$vidEsc"
}

$session = Initialize-WebSession -WarmupUrl $WarmupUrl -Headers (New-JsonHeaders) -TimeoutSec $TimeoutSec

$lines = Get-Content -Path $inputPath -Encoding UTF8
$isbnList = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not $isbnList -or $isbnList.Count -eq 0) { Write-Log -Level 'ERROR' -Message "輸入檔沒有任何 ISBN：$inputPath"; exit 1 }

Write-Log -Level 'INFO' -Message "資料來源：$BaseOrigin （vid=$Vid）"
Write-Log -Level 'INFO' -Message "逾時設定：每次請求最多等待 $TimeoutSec 秒，失敗後最多重試 $MaxRetry 次"
Write-Log -Level 'INFO' -Message "總計 $($isbnList.Count) 筆 ISBN，開始處理。"

$idx = 0
foreach ($raw in $isbnList) {
  $idx++
  $isbn = Normalize-Isbn ($raw.Trim().Split(',', 2)[1])
  if (-not $isbn) { Write-Log -Level 'WARN' -Message "第 $idx 筆：ISBN '${raw}' 非 10/13 碼，跳過。"; continue }
  Write-Log -Level 'INFO' -Message "第 $idx 筆：處理 ISBN=$isbn"
  Start-Sleep -Milliseconds (Get-Random -Minimum $MinDelayMs -Maximum ($MaxDelayMs+1))

  $searchUrl = Build-PrimoSearchUrl -Isbn $isbn
  $searchResp = Invoke-GetWithRetry -Url $searchUrl -WebSession $session -Headers (New-JsonHeaders -Ref $WarmupUrl) `
    -MaxRetry $MaxRetry -InitialDelaySec $InitialRetrySec -Backoff $RetryBackoff -TimeoutSec $TimeoutSec
  if (-not $searchResp) {
    Write-Log -Level 'ERROR' -Message "  無法取得搜尋結果（多次重試後失敗）：$searchUrl"
    "（請求失敗，無內容）" | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.search.error.json") -Encoding utf8
    continue
  }

  $searchResp.Content | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.json") -Encoding utf8

  if (Test-PrimoNoResult -Response $searchResp) {
    $msg = "沒有查獲符合查詢條件的館藏（ISBN=$isbn）。"
    Write-Log -Level 'INFO' -Message "  $msg"
    if ($Interactive) {
      Write-Host "[無結果] $msg  按空白鍵繼續..." -ForegroundColor Yellow
      while ($true) { $key = [Console]::ReadKey($true); if ($key.Key -eq 'Spacebar') { break } }
    }
    continue
  }

  $total = Get-PrimoSearchTotal -Response $searchResp
  if ($total -gt 1) {
    Write-Log -Level 'INFO' -Message "  搜尋命中 $total 筆，僅取第一筆。"
  }

  $docId = Get-FirstPrimoRecordId -Response $searchResp
  if (-not $docId) {
    Write-Log -Level 'WARN' -Message "  搜尋結果無法解析 recordid，跳過。"
    continue
  }

  $title = Get-FirstPrimoTitle -Response $searchResp
  if ($title) {
    Write-Log -Level 'INFO' -Message "  第一筆：$docId — $title"
  } else {
    Write-Log -Level 'INFO' -Message "  第一筆：$docId"
  }

  $marcUrl = Build-PrimoSourceRecordUrl -DocId $docId
  Write-Log -Level 'INFO' -Message "  MARC URL：$marcUrl"

  $marcResp = Invoke-GetWithRetry -Url $marcUrl -WebSession $session -Headers (New-TextHeaders -Ref $searchUrl) `
    -MaxRetry $MaxRetry -InitialDelaySec $InitialRetrySec -Backoff $RetryBackoff -TimeoutSec $TimeoutSec
  if (-not $marcResp) {
    Write-Log -Level 'ERROR' -Message "  無法取得 MARC（多次重試後失敗）：$marcUrl"
    "（請求失敗，無內容）" | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.marc.error.txt") -Encoding utf8
    continue
  }

  $marcText = $marcResp.Content
  if ([string]::IsNullOrWhiteSpace($marcText) -or ($marcText -notmatch '(?i)^leader\t')) {
    Write-Log -Level 'WARN' -Message "  MARC 內容空白或非預期格式，跳過。已輸出原始內容供除錯。"
    $marcText | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.marc.bad.txt") -Encoding utf8
    continue
  }

  $norm = ($marcText -replace "`r`n|`n|`r", "`r`n").TrimEnd()
  $norm | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.txt") -Encoding utf8

  Write-Log -Level 'INFO' -Message "  完成：$isbn  →  $isbn.txt, $isbn.json"
}

Write-Log -Level 'INFO' -Message "全部處理完成。"
