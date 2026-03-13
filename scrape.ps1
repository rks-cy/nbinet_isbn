<# 
NCL 全國書目網（nbinet3）— 以 ISBN 批次抓取 MARC（無 Selenium / 無 HAP）
PowerShell 5.1 版本
#>

param(
  [string]$InputFile      = ".\isbn.txt",
  [string]$UserAgent      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShellScraper/1.0",
  [string]$AcceptLanguage = "zh-TW",
  [hashtable]$ExtraHeaders = @{},
  [int]$MinDelayMs = 500,
  [int]$MaxDelayMs = 900,
  [int]$MaxRetry = 3,
  [double]$InitialRetrySec = 3.0,
  [double]$RetryBackoff = 1.5,
  [switch]$AppendLog = $false,
  [switch]$Interactive = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- 路徑與日誌 ---
$inputPath = Resolve-Path -Path $InputFile
$outDir = Split-Path -Parent $inputPath
$logPath = Join-Path $outDir 'scrape.log'

if (-not $AppendLog) { "" | Out-File -FilePath $logPath -Encoding utf8 }

function Write-Log {
  param([ValidateSet('INFO','WARN','ERROR')] [string]$Level, [string]$Message)
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $line = "[$ts] [$Level] $Message"
  Write-Host $line
  Add-Content -Path $logPath -Value $line -Encoding utf8
}

# 載入 lib
$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'http.ps1')
. (Join-Path $libDir 'parse.ps1')

# --- 共用常數 ---
$BaseOrigin = "https://nbinet3.ncl.edu.tw"
$OpacMenu   = "$BaseOrigin/screens/opacmenu_cht.html"
function New-BaseHeaders {
  param([string]$Ref = $null)
  $h = @{
    'User-Agent'      = $UserAgent
    'Accept-Language' = $AcceptLanguage
    'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
  }
  if ($Ref) { $h['Referer'] = $Ref }
  if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
  return $h
}

function Normalize-Isbn {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  $s = ($Raw -replace '[\s-]','').Trim().ToUpper()
  if ($s -match '^\d{13}$') { return $s }
  if ($s -match '^\d{9}[\dX]$') { return $s }
  return $null
}

# --- 建立 Session（需先 GET opacmenu_cht.html 建立 cookies/語系；無 CSRF token） ---
$session = Initialize-WebSession -OpacMenuUrl $OpacMenu -Headers (New-BaseHeaders)

# --- 讀取 ISBN 清單 ---
if (-not (Test-Path $inputPath)) {
  Write-Log -Level 'ERROR' -Message "找不到輸入檔：$inputPath"
  exit 1
}
$isbnList = Get-Content -Path $inputPath -Encoding UTF8 | Where-Object { $_ -ne '' }
if (-not $isbnList -or $isbnList.Count -eq 0) {
  Write-Log -Level 'ERROR' -Message "輸入檔沒有任何 ISBN：$inputPath"
  exit 1
}

Write-Log -Level 'INFO' -Message "總計 $($isbnList.Count) 筆 ISBN，開始處理。輸出目錄：$outDir"

$idx = 0
foreach ($raw in $isbnList) {
  $idx++
  $isbn = Normalize-Isbn $raw
  if (-not $isbn) {
    Write-Log -Level 'WARN' -Message "第 $idx 筆：ISBN '${raw}' 非 10/13 碼，跳過。"
    continue
  }

  Write-Log -Level 'INFO' -Message "第 $idx 筆：處理 ISBN=$isbn"

  # 節流
  $delay = Get-Random -Minimum $MinDelayMs -Maximum ($MaxDelayMs + 1)
  Start-Sleep -Milliseconds $delay

  # 1) 搜尋結果頁
  $searchUrl = "$BaseOrigin/search*cht/?searchtype=i&searcharg=$isbn&searchscope=1"
  $searchResp = Invoke-GetWithRetry `
    -Url $searchUrl `
    -WebSession $session `
    -Headers (New-BaseHeaders -Ref $OpacMenu) `
    -MaxRetry $MaxRetry -InitialDelaySec $InitialRetrySec -Backoff $RetryBackoff `
    -OnRetry { param($try,$ex) Write-Log -Level 'WARN' -Message "  [重試 $try/$MaxRetry] 讀取結果頁失敗：$($ex.Message)" }

  if (-not $searchResp) {
    Write-Log -Level 'ERROR' -Message "  無法取得結果頁（多次重試後失敗）：$searchUrl"
    $errPath = Join-Path $outDir "$isbn.search.error.html"
    "（請求失敗，無內容）" | Out-File -FilePath $errPath -Encoding utf8
    continue
  }

  # 分頁偵測
  if (Test-HasPagination -Response $searchResp) {
    Write-Log -Level 'INFO' -Message "  偵測到搜尋結果存在分頁（Prev/Next 或 offset/page 連結）。僅處理第一頁第一筆。"
  }

  # 無結果判定
  if (Test-NoResult -Response $searchResp) {
    $msg = "沒有查獲符合查詢條件的館藏（ISBN=$isbn）。"
    Write-Log -Level 'INFO' -Message "  $msg"
    if ($Interactive) {
      Write-Host ""
      Write-Host "[無結果] $msg  按空白鍵繼續..." -ForegroundColor Yellow
      while ($true) { $key = [Console]::ReadKey($true); if ($key.Key -eq 'Spacebar') { break } }
    }
    continue
  }

  # 2) 取第一筆 → 細項連結
  $detailUrl = Get-FirstResultLink -Response $searchResp -BaseOrigin $BaseOrigin
  if (-not $detailUrl) {
    Write-Log -Level 'WARN' -Message "  找不到第一筆 .briefcitTitle a 連結，視為無結果。"
    continue
  } else {
    Write-Log -Level 'INFO' -Message "  細項頁 URL：$detailUrl"
  }

  $detailResp = Invoke-GetWithRetry `
    -Url $detailUrl `
    -WebSession $session `
    -Headers (New-BaseHeaders -Ref $searchUrl) `
    -MaxRetry $MaxRetry -InitialDelaySec $InitialRetrySec -Backoff $RetryBackoff `
    -OnRetry { param($try,$ex) Write-Log -Level 'WARN' -Message "  [重試 $try/$MaxRetry] 讀取細項頁失敗：$($ex.Message)" }

  if (-not $detailResp) {
    Write-Log -Level 'ERROR' -Message "  無法取得細項頁（多次重試後失敗）：$detailUrl"
    $errPath = Join-Path $outDir "$isbn.detail.error.html"
    "（請求失敗，無內容）" | Out-File -FilePath $errPath -Encoding utf8
    continue
  }

  # 3) 細項頁找「MARC 顯示」連結
  $marcUrl = Get-MarcLink -Response $detailResp -DetailUrl $detailUrl -BaseOrigin $BaseOrigin
  if (-not $marcUrl) {
    Write-Log -Level 'WARN' -Message "  細項頁未找到「MARC 顯示」連結，跳過該 ISBN。"
    continue
  } else {
    Write-Log -Level 'INFO' -Message "  MARC 頁 URL：$marcUrl"
  }

  $marcResp = Invoke-GetWithRetry `
    -Url $marcUrl `
    -WebSession $session `
    -Headers (New-BaseHeaders -Ref $detailUrl) `
    -MaxRetry $MaxRetry -InitialDelaySec $InitialRetrySec -Backoff $RetryBackoff `
    -OnRetry { param($try,$ex) Write-Log -Level 'WARN' -Message "  [重試 $try/$MaxRetry] 讀取 MARC 頁失敗：$($ex.Message)" }

  if (-not $marcResp) {
    Write-Log -Level 'ERROR' -Message "  無法取得 MARC 頁（多次重試後失敗）：$marcUrl"
    $errPath = Join-Path $outDir "$isbn.marc.error.html"
    "（請求失敗，無內容）" | Out-File -FilePath $errPath -Encoding utf8
    continue
  }

  # 4) 擷取 <pre> 文字；並存 HTML 原文
  $preText = Get-PreText -Response $marcResp
  if (-not $preText) {
    Write-Log -Level 'WARN' -Message "  MARC 頁未找到 <pre>，跳過。已輸出原始 HTML 供除錯。"
    $rawErr = Join-Path $outDir "$isbn.marc.nopre.html"
    $marcResp.Content | Out-File -FilePath $rawErr -Encoding utf8
    continue
  }

  $norm = ($preText -replace "`r`n|`n|`r", "`r`n").TrimEnd()
  $txtPath  = Join-Path $outDir "$isbn.txt"
  $htmlPath = Join-Path $outDir "$isbn.html"
  $norm            | Out-File -FilePath $txtPath  -Encoding utf8
  $marcResp.Content| Out-File -FilePath $htmlPath -Encoding utf8

  Write-Log -Level 'INFO' -Message "  ✅ 完成：$isbn  →  $([IO.Path]::GetFileName($txtPath)), $([IO.Path]::GetFileName($htmlPath))"
}

Write-Log -Level 'INFO' -Message "全部處理完成。"
