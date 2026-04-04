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

# Dot-source libs with correct 2-arg Join-Path (PS 5.1)
$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'http.ps1')
. (Join-Path $libDir 'parse.ps1')

$BaseOrigin = "https://nbinet3.ncl.edu.tw"
$OpacMenu   = "$BaseOrigin/screens/opacmenu_cht.html"
function New-BaseHeaders { param([string]$Ref = $null); $h = @{ 'User-Agent'=$UserAgent; 'Accept-Language'=$AcceptLanguage; 'Accept'='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' }; if ($Ref) { $h['Referer']=$Ref }; if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k]=$ExtraHeaders[$k] } }; return $h }

function Normalize-Isbn { param([string]$Raw) if ([string]::IsNullOrWhiteSpace($Raw)) { return $null } $s = ($Raw -replace '[\s-]','').Trim().ToUpper(); if ($s -match '^\d{13}$') { return $s }; if ($s -match '^\d{9}[\dX]$') { return $s }; return $null }

$session = Initialize-WebSession -OpacMenuUrl $OpacMenu -Headers (New-BaseHeaders)

# 讀檔並強制為陣列
$lines = Get-Content -Path $inputPath -Encoding UTF8
$isbnList = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not $isbnList -or $isbnList.Count -eq 0) { Write-Log -Level 'ERROR' -Message "輸入檔沒有任何 ISBN：$inputPath"; exit 1 }

Write-Log -Level 'INFO' -Message "總計 $($isbnList.Count) 筆 ISBN，開始處理。"

$idx = 0
foreach ($raw in $isbnList) {
  $idx++
  $isbn = Normalize-Isbn ($raw.Trim().Split(',', 2)[1])
  if (-not $isbn) { Write-Log -Level 'WARN' -Message "第 $idx 筆：ISBN '${raw}' 非 10/13 碼，跳過。"; continue }
  Write-Log -Level 'INFO' -Message "第 $idx 筆：處理 ISBN=$isbn"
  Start-Sleep -Milliseconds (Get-Random -Minimum $MinDelayMs -Maximum ($MaxDelayMs+1))

  $searchUrl = "$BaseOrigin/search*cht/?searchtype=i&searcharg=$isbn&searchscope=1"
  $searchResp = Invoke-GetWithRetry -Url $searchUrl -WebSession $session -Headers (New-BaseHeaders -Ref $OpacMenu) -MaxRetry $MaxRetry -InitialDelaySec $InitialRetrySec -Backoff $RetryBackoff -OnRetry { param($try,$ex) Write-Log -Level 'WARN' -Message "  [重試 $try/$MaxRetry] 讀取結果頁失敗：$($ex.Message)" }
  if (-not $searchResp) { Write-Log -Level 'ERROR' -Message "  無法取得結果頁（多次重試後失敗）：$searchUrl"; "（請求失敗，無內容）" | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.search.error.html") -Encoding utf8; continue }

  if (Test-HasPagination -Response $searchResp) { Write-Log -Level 'INFO' -Message "  偵測到搜尋結果存在分頁（Prev/Next 或 offset/page 連結）。僅處理第一頁第一筆。" }
  if (Test-NoResult -Response $searchResp) { $msg = "沒有查獲符合查詢條件的館藏（ISBN=$isbn）。"; Write-Log -Level 'INFO' -Message "  $msg"; if ($Interactive) { Write-Host "[無結果] $msg  按空白鍵繼續..." -ForegroundColor Yellow; while ($true) { $key = [Console]::ReadKey($true); if ($key.Key -eq 'Spacebar') { break } } }; continue }

  $detailUrl = Get-FirstResultLink -Response $searchResp -BaseOrigin $BaseOrigin
  if (-not $detailUrl) { Write-Log -Level 'WARN' -Message "  找不到第一筆 .briefcitTitle a 連結，視為無結果。"; continue } else { Write-Log -Level 'INFO' -Message "  細項頁 URL：$detailUrl" }

  $detailResp = Invoke-GetWithRetry -Url $detailUrl -WebSession $session -Headers (New-BaseHeaders -Ref $searchUrl) -MaxRetry $MaxRetry -InitialDelaySec $InitialRetrySec -Backoff $RetryBackoff -OnRetry { param($try,$ex) Write-Log -Level 'WARN' -Message "  [重試 $try/$MaxRetry] 讀取細項頁失敗：$($ex.Message)" }
  if (-not $detailResp) { Write-Log -Level 'ERROR' -Message "  無法取得細項頁（多次重試後失敗）：$detailUrl"; "（請求失敗，無內容）" | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.detail.error.html") -Encoding utf8; continue }

  $marcUrl = Get-MarcLink -Response $detailResp -DetailUrl $detailUrl -BaseOrigin $BaseOrigin
  if (-not $marcUrl) { Write-Log -Level 'WARN' -Message "  細項頁未找到「MARC 顯示」連結，跳過該 ISBN。"; continue } else { Write-Log -Level 'INFO' -Message "  MARC 頁 URL：$marcUrl" }

  $marcResp = Invoke-GetWithRetry -Url $marcUrl -WebSession $session -Headers (New-BaseHeaders -Ref $detailUrl) -MaxRetry $MaxRetry -InitialDelaySec $InitialRetrySec -Backoff $RetryBackoff -OnRetry { param($try,$ex) Write-Log -Level 'WARN' -Message "  [重試 $try/$MaxRetry] 讀取 MARC 頁失敗：$($ex.Message)" }
  if (-not $marcResp) { Write-Log -Level 'ERROR' -Message "  無法取得 MARC 頁（多次重試後失敗）：$marcUrl"; "（請求失敗，無內容）" | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.marc.error.html") -Encoding utf8; continue }

  $preText = Get-PreText -Response $marcResp
  if (-not $preText) { Write-Log -Level 'WARN' -Message "  MARC 頁未找到 <pre>，跳過。已輸出原始 HTML 供除錯。"; $marcResp.Content | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.marc.nopre.html") -Encoding utf8; continue }

  $norm = ($preText -replace "`r`n|`n|`r", "`r`n").TrimEnd()
  $norm | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.txt") -Encoding utf8
  $marcResp.Content | Out-File -FilePath (Join-Path $resolvedOutputDir "$isbn.html") -Encoding utf8

  Write-Log -Level 'INFO' -Message "  完成：$isbn  →  $isbn.txt, $isbn.html"
}

Write-Log -Level 'INFO' -Message "全部處理完成。"
