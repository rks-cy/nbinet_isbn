#Requires -Version 3.0
# Primo VE / NBINet helpers: search JSON → record id

function Get-PrimoSearchTotal {
  param([Parameter(Mandatory=$true)] $Response)
  try {
    $json = $Response.Content | ConvertFrom-Json
    if ($null -eq $json -or $null -eq $json.info) { return 0 }
    return [int]$json.info.total
  } catch {
    return 0
  }
}

function Test-PrimoNoResult {
  param([Parameter(Mandatory=$true)] $Response)
  try {
    $json = $Response.Content | ConvertFrom-Json
    if ($null -eq $json) { return $true }
    $total = 0
    if ($null -ne $json.info -and $null -ne $json.info.total) {
      $total = [int]$json.info.total
    }
    $docs = @()
    if ($null -ne $json.docs) { $docs = @($json.docs) }
    return ($total -le 0 -or $docs.Count -eq 0)
  } catch {
    return $true
  }
}

function Get-FirstPrimoRecordId {
  param([Parameter(Mandatory=$true)] $Response)
  try {
    $json = $Response.Content | ConvertFrom-Json
    if ($null -eq $json -or $null -eq $json.docs) { return $null }
    $docs = @($json.docs)
    if ($docs.Count -eq 0) { return $null }

    $doc = $docs[0]
    if ($null -eq $doc.pnx -or $null -eq $doc.pnx.control) { return $null }

    $ids = @($doc.pnx.control.recordid)
    if ($ids.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$ids[0])) { return $null }

    $rid = [string]$ids[0]
    if ($rid.StartsWith('alma')) { return $rid }
    return "alma$rid"
  } catch {
    return $null
  }
}

function Get-FirstPrimoTitle {
  param([Parameter(Mandatory=$true)] $Response)
  try {
    $json = $Response.Content | ConvertFrom-Json
    if ($null -eq $json -or $null -eq $json.docs) { return $null }
    $docs = @($json.docs)
    if ($docs.Count -eq 0) { return $null }
    $doc = $docs[0]
    if ($null -eq $doc.pnx -or $null -eq $doc.pnx.display) { return $null }
    $titles = @($doc.pnx.display.title)
    if ($titles.Count -eq 0) { return $null }
    return [string]$titles[0]
  } catch {
    return $null
  }
}
