#Requires -Version 3.0
# lib/marc_parse.ps1
# Phase 1: MARC text parser, fields.conf parser
# Phase 2: Transform pipeline
# Phase 3: Field extraction engine

# ---------------------------------------------------------------------------
# Phase 1a: HTML entity decode (reuse pattern from lib/parse.ps1)
# ---------------------------------------------------------------------------
function Invoke-HtmlDecode {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return $s }
    # Numeric decimal entities first
    $s = [regex]::Replace($s, '&#(\d+);', {
        param($m)
        [char][int]$m.Groups[1].Value
    })
    # Named entities
    try   { return [System.Net.WebUtility]::HtmlDecode($s) }
    catch { try { return [System.Web.HttpUtility]::HtmlDecode($s) } catch { return $s } }
}

# ---------------------------------------------------------------------------
# Phase 1b: Parse MARC plain-text into a structured list
# Returns [System.Collections.ArrayList] of hashtables:
#   @{ Tag='245'; Ind1='1'; Ind2='0'; Subfields=@{a='…'; c='…'; …} }
# Control fields (001-009): stored as Subfields @{a='value'}
# ---------------------------------------------------------------------------
function ConvertFrom-MarcText {
    param([Parameter(Mandatory=$true)][string]$RawText)

    $records = [System.Collections.ArrayList]::new()
    $currentRec = $null

    foreach ($line in ($RawText -split "`r?`n")) {
        # Skip blank lines
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Continuation line: starts with whitespace (no TAG at position 0-2)
        if ($line -match '^[ \t]') {
            if ($currentRec -ne $null) {
                $trimmed = $line.TrimStart(' ', "`t")
                $currentRec.RawContent += $trimmed
            }
            continue
        }

        # LEADER line
        if ($line -match '^LEADER') {
            $currentRec = @{ Tag='LEADER'; Ind1=' '; Ind2=' '; RawContent=($line -replace '^LEADER\s*',''); Subfields=@{} }
            [void]$records.Add($currentRec)
            continue
        }

        # TAG line: TAG = first 3 chars
        if ($line.Length -lt 3) { continue }
        $tag = $line.Substring(0,3).Trim()
        if ($tag -notmatch '^\d{3}$') { continue }

        $tagNum = [int]$tag

        if ($tagNum -ge 1 -and $tagNum -le 9) {
            # Control field: no indicators, rest of line (from col 3, trimmed) is value
            $value = $line.Substring(3).Trim()
            $currentRec = @{ Tag=$tag; Ind1=' '; Ind2=' '; RawContent=$value; Subfields=@{ a=$value } }
            [void]$records.Add($currentRec)
        } else {
            # Data field layout: TAG(0-2) SPACE(3) IND1(4) IND2(5) SPACE(6) CONTENT(7+)
            $ind1    = if ($line.Length -gt 4) { $line[4].ToString() } else { ' ' }
            $ind2    = if ($line.Length -gt 5) { $line[5].ToString() } else { ' ' }
            $content = if ($line.Length -gt 7) { $line.Substring(7) } else { '' }
            $currentRec = @{ Tag=$tag; Ind1=$ind1; Ind2=$ind2; RawContent=$content; Subfields=@{} }
            [void]$records.Add($currentRec)
        }
    }

    # Second pass: parse subfields from RawContent for all data fields
    foreach ($rec in $records) {
        if ($rec.Tag -eq 'LEADER') { continue }
        $tagNum = [int]$rec.Tag
        if ($tagNum -ge 1 -and $tagNum -le 9) { continue }  # already set

        $content = Invoke-HtmlDecode -s $rec.RawContent
        $rec.Subfields = Parse-Subfields -Content $content
    }

    return $records
}

function Parse-Subfields {
    param([string]$Content)
    $sf = @{}
    if ([string]::IsNullOrEmpty($Content)) { return $sf }

    # Split on |x where x is a letter
    $parts = [regex]::Split($Content, '\|([a-zA-Z0-9])')
    # parts[0] = implicit $a, then pairs: parts[1]=code parts[2]=value, parts[3]=code parts[4]=value ...
    $implicit = $parts[0].Trim()
    if (-not [string]::IsNullOrEmpty($implicit)) {
        $sf['a'] = $implicit
    }
    $i = 1
    while ($i -lt $parts.Count - 1) {
        $code  = $parts[$i]
        $value = $parts[$i+1].Trim()
        if (-not $sf.ContainsKey($code)) {
            $sf[$code] = $value
        } else {
            # Append subsequent occurrences with space separator
            $sf[$code] += ' ' + $value
        }
        $i += 2
    }
    return $sf
}

# ---------------------------------------------------------------------------
# Phase 1c: Detect MARC format (MARC21 vs UNIMARC)
# ---------------------------------------------------------------------------
function Get-MarcFormat {
    param([System.Collections.ArrayList]$Records)

    foreach ($rec in $Records) {
        if ($rec.Tag -eq '200') {
            $sf = $rec.Subfields
            if ($sf.ContainsKey('f') -or $sf.ContainsKey('g')) {
                return 'UNIMARC'
            }
        }
    }
    foreach ($rec in $Records) {
        if ($rec.Tag -eq '245') { return 'MARC21' }
    }
    return $null  # unknown
}

# ---------------------------------------------------------------------------
# Phase 1d: Parse fields.conf into field definition list
# ---------------------------------------------------------------------------
function ConvertFrom-FieldsConf {
    param([Parameter(Mandatory=$true)][string]$ConfPath)

    $fieldDefs = [System.Collections.ArrayList]::new()
    $currentDef = $null

    foreach ($rawLine in [System.IO.File]::ReadAllLines($ConfPath, [System.Text.Encoding]::UTF8)) {
        $line = $rawLine

        # Comment or blank line
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }

        # Option line (4-space indent)
        if ($line -match '^    (.+)$') {
            if ($currentDef -eq $null) { continue }
            $optLine = $Matches[1]

            if ($optLine -match '^#') { continue }  # inline comment

            if ($optLine -match '^TAKE=(.+)$') {
                $currentDef.Take = $Matches[1].Trim().ToLower()
            } elseif ($optLine -match '^JOIN=(.*)$') {
                $currentDef.Join = $Matches[1]  # preserve as-is (may be ；)
            } elseif ($optLine -match '^SUBFIELD_JOIN=(.*)$') {
                $currentDef.SubfieldJoin = $Matches[1]  # preserve trailing space/empty
            } elseif ($optLine -match '^TRANSFORM=(.+)$') {
                $currentDef.Transforms = ($Matches[1].Trim() -split ',') | ForEach-Object { $_.Trim() }
            }
            continue
        }

        # Field definition line:  欄位名稱: 來源1 來源2 ...
        if ($line -match '^([^:]+):\s*(.*)$') {
            $name    = $Matches[1].Trim()
            $srcStr  = $Matches[2].Trim()

            $currentDef = @{
                Name         = $name
                Sources      = [System.Collections.ArrayList]::new()
                Take         = 'first'
                Join         = '；'
                SubfieldJoin = ''
                Transforms   = @()
            }
            [void]$fieldDefs.Add($currentDef)

            # Parse sources
            foreach ($src in ($srcStr -split '\s+')) {
                if ([string]::IsNullOrEmpty($src)) { continue }
                $parsedSrc = Parse-FieldSource -Src $src
                if ($parsedSrc -ne $null) { [void]$currentDef.Sources.Add($parsedSrc) }
            }
        }
    }

    return $fieldDefs
}

function Parse-FieldSource {
    param([string]$Src)

    # 008[N:L] control field positional
    if ($Src -match '^008\[(\d+):(\d+)\]$') {
        return @{ IsControl008=$true; Offset=[int]$Matches[1]; Length=[int]$Matches[2]; Tag='008'; Subfields=@() }
    }

    # TAG + subfield codes: e.g. 020a, 200ahe, 490av
    if ($Src -match '^(\d{3})([a-zA-Z]+)$') {
        $tag  = $Matches[1]
        $subs = [char[]]$Matches[2] | ForEach-Object { $_.ToString() }
        return @{ IsControl008=$false; Tag=$tag; Subfields=$subs }
    }

    # TAG only (no subfield) — treat as $a
    if ($Src -match '^(\d{3})$') {
        return @{ IsControl008=$false; Tag=$Matches[1]; Subfields=@('a') }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Phase 2: Transform pipeline
# ---------------------------------------------------------------------------
function Invoke-MarcTransform {
    param(
        [string]$Value,
        [string[]]$Rules,
        [string]$Isbn = '',
        [ref]$WarnList  # [System.Collections.ArrayList]
    )

    foreach ($rule in $Rules) {
        switch ($rule.ToUpper()) {
            'HTML_DECODE' {
                $Value = Invoke-HtmlDecode -s $Value
            }
            'ISBN_CLEAN' {
                $Value = Invoke-HtmlDecode -s $Value
                $Value = $Value -replace '[-\s]', ''
                $Value = [regex]::Replace($Value, '[^0-9Xx]', '')
                $Value = $Value.ToUpper()
                $len = $Value.Length
                if ($len -ne 10 -and $len -ne 13) {
                    if ($WarnList -ne $null) {
                        [void]$WarnList.Value.Add("ISBN_CLEAN: 無效長度 $len for '$Value'")
                    }
                }
            }
            'STRIP_PUNCT' {
                $stripChars = [char[]]@('/', ':', ',', ';', '。', '，', '、', '˸', ' ', "`t")
                $Value = $Value.Trim().TrimStart($stripChars).TrimEnd($stripChars).Trim()
            }
            'YEAR_CE' {
                $m = [regex]::Match($Value, '\d{4}')
                if ($m.Success) {
                    $Value = $m.Value
                } else {
                    if ($WarnList -ne $null) {
                        [void]$WarnList.Value.Add("YEAR_CE: 找不到年份 in '$Value'")
                    }
                    $Value = ''
                }
            }
            'YEAR_ROC' {
                $m = [regex]::Match($Value, '\d{4}')
                if ($m.Success) {
                    $ce = [int]$m.Value
                    if ($ce -ge 1912) {
                        $Value = ($ce - 1911).ToString()
                    } else {
                        $Value = ''
                    }
                } else {
                    $Value = ''
                }
            }
            'BINDING' {
                if ([string]::IsNullOrEmpty($Value)) {
                    # leave empty
                } elseif ($Value -match '精裝') {
                    $Value = '精裝'
                } elseif ($Value -match '平裝') {
                    $Value = '平裝'
                } elseif ($Value -match '套裝') {
                    $Value = '套裝'
                } else {
                    $Value = '其他'
                }
            }
            'FOUR_CORNER' {
                if (-not [string]::IsNullOrEmpty($Value)) {
                    $firstChar = $Value[0]
                    # Non-CJK characters (below the CJK Radicals Supplement block U+2E80):
                    # foreign-author names are valid — output empty string, no warning.
                    if ([int]$firstChar -lt 0x2E80) {
                        $Value = ''
                    } else {
                        $lookup = $null
                        if ($Script:UnihanFourCorner -ne $null) {
                            $lookup = $Script:UnihanFourCorner[$firstChar.ToString()]
                        }
                        if ($lookup) {
                            $Value = $lookup
                        } else {
                            if ($WarnList -ne $null) {
                                [void]$WarnList.Value.Add("FOUR_CORNER: 找不到「$firstChar」的四角號碼")
                            }
                            $Value = "(查無四角號碼:$firstChar)"
                        }
                    }
                }
            }
        }
    }
    return $Value
}

# Strip-punct helper for individual subfield values
function Invoke-StripPunct {
    param([string]$Value)
    $stripChars = [char[]]@('/', ':', ',', ';', '。', '，', '、', '˸', ' ', "`t")
    return $Value.Trim().TrimStart($stripChars).TrimEnd($stripChars).Trim()
}

# ---------------------------------------------------------------------------
# Phase 3: Field value extraction engine
# ---------------------------------------------------------------------------
function Get-FieldValue {
    param(
        [System.Collections.ArrayList]$Records,
        [hashtable]$FieldDef,
        [ref]$WarnList
    )

    $hasSources = ($FieldDef.Sources.Count -gt 0)
    if (-not $hasSources) { return '' }

    $doStripPunct = ($FieldDef.Transforms -contains 'STRIP_PUNCT')
    $sjoin = $FieldDef.SubfieldJoin  # subfield join char (may be '' or ' ')

    foreach ($src in $FieldDef.Sources) {
        $result = ''

        # ---- 008 positional ----
        if ($src.IsControl008) {
            $ctl008 = $Records | Where-Object { $_.Tag -eq '008' } | Select-Object -First 1
            if ($ctl008 -ne $null) {
                $val = $ctl008.Subfields['a']
                if (-not [string]::IsNullOrEmpty($val) -and $val.Length -ge ($src.Offset + $src.Length)) {
                    $result = $val.Substring($src.Offset, $src.Length).Trim()
                }
            }
            if (-not [string]::IsNullOrEmpty($result)) {
                # Apply non-STRIP transforms
                $otherRules = $FieldDef.Transforms | Where-Object { $_ -ne 'STRIP_PUNCT' }
                $result = Invoke-MarcTransform -Value $result -Rules $otherRules -WarnList $WarnList
                if (-not [string]::IsNullOrEmpty($result)) { return $result }
            }
            continue
        }

        # ---- Data/control field ----
        $matchingRecs = @($Records | Where-Object { $_.Tag -eq $src.Tag })
        if ($matchingRecs.Count -eq 0) { continue }

        if ($FieldDef.Take -eq 'all') {
            $rowValues = [System.Collections.ArrayList]::new()
            foreach ($rec in $matchingRecs) {
                $rowVal = Get-SubfieldValue -Rec $rec -Subfields $src.Subfields -SubfieldJoin $sjoin -DoStripPunct $doStripPunct
                if (-not [string]::IsNullOrEmpty($rowVal)) {
                    [void]$rowValues.Add($rowVal)
                }
            }
            if ($rowValues.Count -gt 0) {
                $result = $rowValues -join $FieldDef.Join
                # Final strip on joined result
                if ($doStripPunct) { $result = Invoke-StripPunct -Value $result }
                # Apply other transforms
                $otherRules = $FieldDef.Transforms | Where-Object { $_ -ne 'STRIP_PUNCT' }
                $result = Invoke-MarcTransform -Value $result -Rules $otherRules -WarnList $WarnList
                if (-not [string]::IsNullOrEmpty($result)) { return $result }
            }
        } else {
            # TAKE=first
            $rec = $matchingRecs[0]
            $rowVal = Get-SubfieldValue -Rec $rec -Subfields $src.Subfields -SubfieldJoin $sjoin -DoStripPunct $doStripPunct
            if (-not [string]::IsNullOrEmpty($rowVal)) {
                $otherRules = $FieldDef.Transforms | Where-Object { $_ -ne 'STRIP_PUNCT' }
                $result = Invoke-MarcTransform -Value $rowVal -Rules $otherRules -WarnList $WarnList
                if (-not [string]::IsNullOrEmpty($result)) { return $result }
            }
        }
    }

    return ''
}

function Get-SubfieldValue {
    param(
        [hashtable]$Rec,
        [string[]]$Subfields,
        [string]$SubfieldJoin,
        [bool]$DoStripPunct
    )
    $parts = [System.Collections.ArrayList]::new()
    foreach ($sfCode in $Subfields) {
        if ($Rec.Subfields.ContainsKey($sfCode)) {
            $val = $Rec.Subfields[$sfCode]
            $val = Invoke-HtmlDecode -s $val
            if ($DoStripPunct) { $val = Invoke-StripPunct -Value $val }
            if (-not [string]::IsNullOrEmpty($val)) {
                [void]$parts.Add($val)
            }
        }
    }
    if ($parts.Count -eq 0) { return '' }
    return $parts -join $SubfieldJoin
}
