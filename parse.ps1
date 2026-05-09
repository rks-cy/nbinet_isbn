#Requires -Version 3.0
<#
.SYNOPSIS
    Phase 2: MARC plain-text → CSV exporter
.DESCRIPTION
    Reads {ISBN}.txt files produced by scrape.ps1, parses MARC records,
    maps fields using fields.conf, and writes marc_output.csv (UTF-8 BOM).
#>
param(
    [string]$IsbnFile   = ".\isbn.csv",
    [string]$InputDir   = ".\grabbed_isbn",
    [string]$FieldsConf = ".\fields.conf",
    [string]$OutputCsv  = ".\marc_output.csv",
    [string]$UnihanFile = ".\data\Unihan_DictionaryLikeData.txt"
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Resolve paths relative to script location
# ---------------------------------------------------------------------------
function Resolve-ScriptPath {
    param([string]$Path)
    $Path = $Path.Trim('"').Trim()
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Path))
}

$IsbnFile   = Resolve-ScriptPath $IsbnFile
$InputDir   = Resolve-ScriptPath $InputDir
$FieldsConf = Resolve-ScriptPath $FieldsConf
$OutputCsv  = Resolve-ScriptPath $OutputCsv
$UnihanFile = Resolve-ScriptPath $UnihanFile
$LogPath    = Join-Path $PSScriptRoot 'parse.log'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$logLines = [System.Collections.ArrayList]::new()

function Write-ParseLog {
    param([string]$Level, [string]$Isbn, [string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $entry = "[$ts] [$Level] $($Isbn): $Message"
    [void]$logLines.Add($entry)
    Write-Host $entry
}

# ---------------------------------------------------------------------------
# Dot-source library
# ---------------------------------------------------------------------------
$libPath = Join-Path $PSScriptRoot 'lib\marc_parse.ps1'
if (-not (Test-Path $libPath)) {
    Write-Host "[ERROR] : 找不到 lib\marc_parse.ps1：$libPath"
    exit 1
}
. $libPath

# ---------------------------------------------------------------------------
# Load Unihan Four-Corner lookup table
# ---------------------------------------------------------------------------
$script:UnihanFourCorner = @{}
if (-not (Test-Path $UnihanFile)) {
    Write-ParseLog -Level 'WARN' -Isbn '' -Message "找不到 Unihan 資料檔，作者首字四角號碼欄位將全部輸出查無結果：$UnihanFile"
} else {
    $unihanCount = 0
    foreach ($uLine in [System.IO.File]::ReadLines($UnihanFile, [System.Text.Encoding]::UTF8)) {
        # Match lines like: U+5150	kFourCornerCode	2401.0
        if ($uLine -match '^U\+([0-9A-Fa-f]+)\s+kFourCornerCode\s+(\S+)') {
            $cp = [Convert]::ToInt32($Matches[1], 16)
            # Only BMP characters (U+0000–U+FFFF) fit in a single [char]
            if ($cp -le 0xFFFF) {
                $ch = [char]$cp
                # Take only the first space-delimited code value
                $code = ($Matches[2] -split '\s+')[0]
                $script:UnihanFourCorner[$ch.ToString()] = $code
                $unihanCount++
            }
        }
    }
    Write-ParseLog -Level 'INFO' -Isbn '' -Message "Unihan 四角號碼表載入完成，共 $unihanCount 筆"
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
foreach ($f in @($IsbnFile, $FieldsConf)) {
    if (-not (Test-Path $f)) {
        Write-Host "[ERROR] : 找不到必要檔案：$f"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Parse fields.conf
# ---------------------------------------------------------------------------
Write-Host "[INFO] : 載入 fields.conf：$FieldsConf"
try {
    $fieldDefs = ConvertFrom-FieldsConf -ConfPath $FieldsConf
} catch {
    Write-Host "[ERROR] : fields.conf 解析失敗：$($_.Exception.Message)"
    exit 1
}
Write-Host "[INFO] : 欄位定義載入完成，共 $($fieldDefs.Count) 欄"

# ---------------------------------------------------------------------------
# RFC 4180 CSV quoting
# ---------------------------------------------------------------------------
function Format-CsvCell {
    param([string]$Value)
    if ($Value -match '[",\r\n]') {
        return '"' + $Value.Replace('"', '""') + '"'
    }
    return $Value
}

# ---------------------------------------------------------------------------
# Read ISBN list
# ---------------------------------------------------------------------------
$isbnLines = [System.IO.File]::ReadAllLines($IsbnFile, [System.Text.Encoding]::UTF8)

$csvRows = [System.Collections.ArrayList]::new()

# Header row
$headerCells = $fieldDefs | ForEach-Object { Format-CsvCell -Value $_.Name }
[void]$csvRows.Add(($headerCells -join ','))

# ---------------------------------------------------------------------------
# Process each ISBN
# ---------------------------------------------------------------------------
foreach ($rawLine in $isbnLines) {
    if ([string]::IsNullOrEmpty($rawLine.Trim())) { continue }
    $parts = $rawLine.Trim().Split(',', 2)
    $registerNumber = $parts[0].Trim()
    $isbn = $parts[1].Trim() -replace '[-\s]', ''

    # Validate ISBN (10 or 13 digits, last char may be X for ISBN-10)
    if ($isbn -notmatch '^[0-9]{9}[0-9Xx]$' -and $isbn -notmatch '^\d{13}$') {
        Write-ParseLog -Level 'WARN' -Isbn $isbn -Message "ISBN 格式不合法（非 10/13 碼），跳過"
        continue
    }
    $isbn = $isbn.ToUpper()

    # Locate .txt file
    $txtPath = Join-Path $InputDir "$isbn.txt"
    $records = [System.Collections.ArrayList]::new()
    $allEmpty = $false

    if (-not (Test-Path $txtPath)) {
        Write-ParseLog -Level 'ERROR' -Isbn $isbn -Message ".txt 檔案不存在：$txtPath"
        $allEmpty = $true
    } else {
        $rawText = [System.IO.File]::ReadAllText($txtPath, [System.Text.Encoding]::UTF8)
            # Strip UTF-8 BOM if present
            if ($rawText.StartsWith([char]0xFEFF)) { $rawText = $rawText.Substring(1) }
        if ([string]::IsNullOrWhiteSpace($rawText)) {
            Write-ParseLog -Level 'WARN' -Isbn $isbn -Message ".txt 存在但為空檔"
            $allEmpty = $true
        } else {
            try {
                $records = ConvertFrom-MarcText -RawText $rawText
            } catch {
                Write-ParseLog -Level 'ERROR' -Isbn $isbn -Message "MARC 解析例外：$($_.Exception.Message)"
                $allEmpty = $true
            }
        }
    }

    # Detect format
    if (-not $allEmpty) {
        $fmt = Get-MarcFormat -Records $records
        if ($fmt -eq $null) {
            Write-ParseLog -Level 'WARN' -Isbn $isbn -Message "無法辨識格式，以 MARC21 處理"
        } else {
            Write-ParseLog -Level 'INFO' -Isbn $isbn -Message "格式辨識 = $fmt"
        }
    }

    # Build row
    $rowCells = [System.Collections.ArrayList]::new()
    foreach ($def in $fieldDefs) {
        if ($def.Name -eq '登錄號') {
            [void]$rowCells.Add((Format-CsvCell -Value $registerNumber))
            continue
        }
        if ($allEmpty -or $def.Sources.Count -eq 0) {
            [void]$rowCells.Add('')
            continue
        }
        $warnList = [System.Collections.ArrayList]::new()
        $val = Get-FieldValue -Records $records -FieldDef $def -WarnList ([ref]$warnList)
        foreach ($w in $warnList) {
            Write-ParseLog -Level 'WARN' -Isbn $isbn -Message "$($def.Name): $w"
        }
        [void]$rowCells.Add((Format-CsvCell -Value $val))
    }

    [void]$csvRows.Add(($rowCells -join ','))
}

# ---------------------------------------------------------------------------
# Write CSV (UTF-8 with BOM)
# ---------------------------------------------------------------------------
$csvContent = ($csvRows -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($OutputCsv, $csvContent, [System.Text.UTF8Encoding]::new($true))
Write-Host "[INFO] : CSV 輸出完成：$OutputCsv（$($csvRows.Count - 1) 筆資料）"

# ---------------------------------------------------------------------------
# Write log (overwrite, UTF-8 no BOM)
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllLines($LogPath, $logLines, [System.Text.Encoding]::UTF8)
Write-Host "[INFO] : 日誌寫入完成：$LogPath"
