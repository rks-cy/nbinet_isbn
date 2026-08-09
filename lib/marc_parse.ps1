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
# Phase 1b: Parse Primo sourceRecord MARC plain-text into a structured list
# Format: TAG\tCONTENT  (leader\t…; data fields start with two indicator chars then $a…)
# Returns [System.Collections.ArrayList] of hashtables:
#   @{ Tag='245'; Ind1='1'; Ind2='0'; Subfields=@{a='…'; c='…'; …} }
# Control fields (001-009): stored as Subfields @{a='value'}
# ---------------------------------------------------------------------------
function ConvertFrom-MarcText {
    param([Parameter(Mandatory=$true)][string]$RawText)

    $records = [System.Collections.ArrayList]::new()

    foreach ($line in ($RawText -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # leader\t...
        if ($line -match '(?i)^leader\t(.*)$') {
            $rec = @{ Tag='LEADER'; Ind1=' '; Ind2=' '; RawContent=$Matches[1]; Subfields=@{} }
            [void]$records.Add($rec)
            continue
        }

        # TAG\tCONTENT
        if ($line -notmatch '^(\d{3})\t(.*)$') { continue }
        $tag = $Matches[1]
        $rest = $Matches[2]
        $tagNum = [int]$tag

        if ($tagNum -ge 1 -and $tagNum -le 9) {
            $value = $rest.Trim()
            $rec = @{ Tag=$tag; Ind1=' '; Ind2=' '; RawContent=$value; Subfields=@{ a=$value } }
            [void]$records.Add($rec)
        } else {
            # Indicators: first two characters of content (e.g. ##, 10, 1#)
            $ind1 = if ($rest.Length -gt 0) { $rest[0].ToString() } else { ' ' }
            $ind2 = if ($rest.Length -gt 1) { $rest[1].ToString() } else { ' ' }
            $content = if ($rest.Length -gt 2) { $rest.Substring(2) } else { '' }
            $rec = @{ Tag=$tag; Ind1=$ind1; Ind2=$ind2; RawContent=$content; Subfields=@{} }
            [void]$records.Add($rec)
        }
    }

    foreach ($rec in $records) {
        if ($rec.Tag -eq 'LEADER') { continue }
        $tagNum = [int]$rec.Tag
        if ($tagNum -ge 1 -and $tagNum -le 9) { continue }

        $content = Invoke-HtmlDecode -s $rec.RawContent
        $rec.Subfields = Parse-Subfields -Content $content
    }

    return $records
}

function Parse-Subfields {
    param([string]$Content)
    $sf = @{}
    if ([string]::IsNullOrEmpty($Content)) { return $sf }

    # Split only on lowercase-letter subfield codes ($a–$z).
    # Digit codes ($0–$9) are control/linkage subfields and must NOT be treated
    # as delimiters here; otherwise currency strings like "NT$200" would be
    # split at "$2", truncating the price to just "NT".
    $parts = [regex]::Split($Content, '\$([a-z])')
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
            $sf[$code] += ' ' + $value
        }
        $i += 2
    }

    # Remove any trailing digit-subfield residue left in values, e.g.
    # "8745.13 $2ncsclt" → "8745.13".  A digit subfield that was not split
    # above appears as " $<digit><text>" (always preceded by whitespace).
    $cleanKeys = @($sf.Keys)
    foreach ($key in $cleanKeys) {
        $sf[$key] = ($sf[$key] -replace '\s+\$\d\S*', '').Trim()
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
            } elseif ($optLine -match '^SOURCES_JOIN=(.*)$') {
                $currentDef.SourcesJoin = $Matches[1]  # separator used between values from different sources
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
                SourcesJoin  = $null   # non-null = merge values from ALL sources with this separator
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
        [System.Collections.ArrayList]$WarnList = $null
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
                        [void]$WarnList.Add("ISBN_CLEAN: 無效長度 $len for '$Value'")
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
                        [void]$WarnList.Add("YEAR_CE: 找不到年份 in '$Value'")
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
                                [void]$WarnList.Add("FOUR_CORNER: 找不到「$firstChar」的四角號碼")
                            }
                            $Value = "(查無四角號碼:$firstChar)"
                        }
                    }
                }
            }
            'FOUR_CORNER_INT' {
                if (-not [string]::IsNullOrEmpty($Value)) {
                    $firstChar = $Value[0]
                    # Non-CJK characters: output empty string, no warning.
                    if ([int]$firstChar -lt 0x2E80) {
                        $Value = ''
                    } else {
                        $lookup = $null
                        if ($Script:UnihanFourCorner -ne $null) {
                            $lookup = $Script:UnihanFourCorner[$firstChar.ToString()]
                        }
                        if ($lookup) {
                            # Keep integer part only (e.g. "3530.6" -> "3530")
                            $Value = ($lookup -replace '\.\d+$', '')
                        } else {
                            if ($WarnList -ne $null) {
                                [void]$WarnList.Add("FOUR_CORNER_INT: 找不到「$firstChar」的四角號碼")
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

    # ---- SOURCES_JOIN mode -----------------------------------------------
    # When SourcesJoin is set, collect the first non-empty value from EACH
    # source independently and join the collected pieces with SourcesJoin.
    # This is how "全書名 = 書名 + ' ' + 並列題名" is expressed in one field.
    # (Normal TAKE=first/all falls back to the next source only when the
    #  current source is empty; SOURCES_JOIN always tries every source.)
    # ----------------------------------------------------------------------
    if ($FieldDef.SourcesJoin -ne $null) {
        $collected = [System.Collections.ArrayList]::new()
        foreach ($src in $FieldDef.Sources) {
            if ($src.IsControl008) { continue }
            $matchingRecs = @($Records | Where-Object { $_.Tag -eq $src.Tag })
            if ($matchingRecs.Count -eq 0) { continue }
            $rowVal = Get-SubfieldValue -Rec $matchingRecs[0] -Subfields $src.Subfields `
                -SubfieldJoin $sjoin -DoStripPunct $doStripPunct
            if (-not [string]::IsNullOrEmpty($rowVal)) {
                $otherRules = $FieldDef.Transforms | Where-Object { $_ -ne 'STRIP_PUNCT' }
                $rowVal = Invoke-MarcTransform -Value $rowVal -Rules $otherRules -WarnList $WarnList.Value
                if (-not [string]::IsNullOrEmpty($rowVal)) {
                    [void]$collected.Add($rowVal)
                }
            }
        }
        if ($collected.Count -gt 0) {
            $combined = $collected -join $FieldDef.SourcesJoin
            if ($doStripPunct) { $combined = Invoke-StripPunct -Value $combined }
            return $combined
        }
        return ''
    }

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
                $result = Invoke-MarcTransform -Value $result -Rules $otherRules -WarnList $WarnList.Value
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
                $result = Invoke-MarcTransform -Value $result -Rules $otherRules -WarnList $WarnList.Value
                if (-not [string]::IsNullOrEmpty($result)) { return $result }
            }
        } else {
            # TAKE=first
            $rec = $matchingRecs[0]
            $rowVal = Get-SubfieldValue -Rec $rec -Subfields $src.Subfields -SubfieldJoin $sjoin -DoStripPunct $doStripPunct
            if (-not [string]::IsNullOrEmpty($rowVal)) {
                $otherRules = $FieldDef.Transforms | Where-Object { $_ -ne 'STRIP_PUNCT' }
                $result = Invoke-MarcTransform -Value $rowVal -Rules $otherRules -WarnList $WarnList.Value
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
