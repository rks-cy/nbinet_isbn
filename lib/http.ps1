#Requires -Version 3.0

function Invoke-WebRequestCompat {
  param(
    [Parameter(Mandatory=$true)] [string]$Uri,
    [Parameter(Mandatory=$true)] $WebSession,
    [Parameter(Mandatory=$true)] [hashtable]$Headers
  )
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    return Invoke-WebRequest -Uri $Uri -WebSession $WebSession -Headers $Headers -ErrorAction Stop
  } else {
    return Invoke-WebRequest -Uri $Uri -WebSession $WebSession -Headers $Headers -ErrorAction Stop -UseBasicParsing
  }
}

function Initialize-WebSession {
  param(
    [Parameter(Mandatory=$true)] [string]$OpacMenuUrl,
    [Parameter(Mandatory=$true)] [hashtable]$Headers
  )
  $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  try {
    Invoke-WebRequestCompat -Uri $OpacMenuUrl -WebSession $sess -Headers $Headers | Out-Null
  } catch {
    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
      Write-Log -Level 'WARN' -Message "初始化 Session 時發生例外：$($_.Exception.Message)"
    } else {
      Write-Host "[WARN] 初始化 Session 例外：$($_.Exception.Message)"
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
  return Invoke-WebRequestCompat -Uri $Url -WebSession $WebSession -Headers $Headers
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
      } else {
        Write-Host "[WARN] 重試 $attempt/$MaxRetry ${Url} → $($_.Exception.Message)"
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
  try { $Href = [System.Web.HttpUtility]::HtmlDecode($Href) } catch { try { $Href = [System.Net.WebUtility]::HtmlDecode($Href) } catch { } }
  if ($Href -like 'about:*') { $Href = $Href.Substring(6) }
  if ($Href.StartsWith('http://') -or $Href.StartsWith('https://')) { return $Href }
  if ($Href.StartsWith('/')) { return "$BaseOrigin$Href" }
  if (-not $BaseOrigin.EndsWith('/')) { $BaseOrigin = $BaseOrigin + '/' }
  return "$BaseOrigin$Href"
}
