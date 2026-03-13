#Requires -Version 3.0

function Initialize-WebSession {
  param(
    [Parameter(Mandatory=$true)] [string]$OpacMenuUrl,
    [Parameter(Mandatory=$true)] [hashtable]$Headers
  )
  $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  try {
    Invoke-WebRequest -Uri $OpacMenuUrl -WebSession $sess -Headers $Headers -UseDefaultCredentials | Out-Null
  } catch {
    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
      Write-Log -Level 'WARN' -Message "初始化 Session 時發生例外：$($_.Exception.Message)"
    }
  }
  return $sess
}

function Invoke-Get {
  param(
    [Parameter(Mandatory=$true)] [string]$Url,
    [Parameter(Mandatory=$true)] $WebSession,
    [Parameter(Mandatory=$true)] [hashtable]$Headers
  )
  return Invoke-WebRequest -Uri $Url -WebSession $WebSession -Headers $Headers -ErrorAction Stop
}

function Invoke-GetWithRetry {
  param(
    [Parameter(Mandatory=$true)] [string]$Url,
    [Parameter(Mandatory=$true)] $WebSession,
    [Parameter(Mandatory=$true)] [hashtable]$Headers,
    [int]$MaxRetry = 3,
    [double]$InitialDelaySec = 3.0,
    [double]$Backoff = 1.5,
    [ScriptBlock]$OnRetry = $null
  )
  $attempt = 0
  $delay = [double]$InitialDelaySec
  while ($attempt -lt $MaxRetry) {
    try {
      return Invoke-Get -Url $Url -WebSession $WebSession -Headers $Headers
    } catch {
      $attempt++
      if ($attempt -ge $MaxRetry) { break }
      if ($OnRetry) { & $OnRetry $attempt $_.Exception } 
      elseif (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level 'WARN' -Message "  [重試 $attempt/$MaxRetry] ${Url} → $($_.Exception.Message)"
      }
      Start-Sleep -Seconds ([int][math]::Ceiling($delay))
      $delay = [math]::Min($delay * $Backoff, 60.0)
    }
  }
  return $null
}

function Build-AbsoluteUrl {
  param(
    [Parameter(Mandatory=$true)] [string]$BaseOrigin,
    [Parameter(Mandatory=$true)] [string]$Href
  )
  if ([string]::IsNullOrWhiteSpace($Href)) { return $null }
  # Decode HTML entities and strip leading 'about:' if present
  try { $Href = [System.Web.HttpUtility]::HtmlDecode($Href) } catch { try { $Href = [System.Net.WebUtility]::HtmlDecode($Href) } catch {} }
  if ($Href -like 'about:*') { $Href = $Href.Substring(6) }
  if ($Href.StartsWith('http://') -or $Href.StartsWith('https://')) { return $Href }
  if ($Href.StartsWith('/')) { return "$BaseOrigin$Href" }
  if (-not $BaseOrigin.EndsWith('/')) { $BaseOrigin = $BaseOrigin + '/' }
  return "$BaseOrigin$Href"
}
