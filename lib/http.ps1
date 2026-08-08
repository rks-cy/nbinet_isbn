#Requires -Version 3.0

function Invoke-WebRequestCompat {
  param(
    [Parameter(Mandatory=$true)] [string]$Uri,
    [Parameter(Mandatory=$true)] $WebSession,
    [Parameter(Mandatory=$true)] [hashtable]$Headers,
    [int]$TimeoutSec = 30
  )
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    return Invoke-WebRequest -Uri $Uri -WebSession $WebSession -Headers $Headers `
      -TimeoutSec $TimeoutSec -ErrorAction Stop
  } else {
    return Invoke-WebRequest -Uri $Uri -WebSession $WebSession -Headers $Headers `
      -TimeoutSec $TimeoutSec -ErrorAction Stop -UseBasicParsing
  }
}

function Initialize-WebSession {
  param(
    [Parameter(Mandatory=$true)] [string]$WarmupUrl,
    [Parameter(Mandatory=$true)] [hashtable]$Headers,
    [int]$TimeoutSec = 30
  )
  $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  try {
    Invoke-WebRequestCompat -Uri $WarmupUrl -WebSession $sess -Headers $Headers -TimeoutSec $TimeoutSec | Out-Null
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
    [Parameter(Mandatory=$true)] [hashtable]$Headers,
    [int]$TimeoutSec = 30
  )
  return Invoke-WebRequestCompat -Uri $Url -WebSession $WebSession -Headers $Headers -TimeoutSec $TimeoutSec
}

function Invoke-GetWithRetry {
  param(
    [Parameter(Mandatory=$true)] [string]$Url,
    [Parameter(Mandatory=$true)] $WebSession,
    [Parameter(Mandatory=$true)] [hashtable]$Headers,
    [int]$MaxRetry = 3,
    [double]$InitialDelaySec = 3.0,
    [double]$Backoff = 1.5,
    [int]$TimeoutSec = 30
  )

  $attempt = 0
  $delay   = [double]$InitialDelaySec

  while ($attempt -lt $MaxRetry) {
    $attemptNum = $attempt + 1
    try {
      return Invoke-Get -Url $Url -WebSession $WebSession -Headers $Headers -TimeoutSec $TimeoutSec
    } catch {
      $attempt++
      $errMsg = $_.Exception.Message

      if ($attempt -ge $MaxRetry) {
        # Final failure – log then give up
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
          Write-Log -Level 'WARN' -Message "  [第 $attemptNum/$MaxRetry 次失敗] 已達重試上限：$errMsg"
        } else {
          Write-Host "[WARN] [第 $attemptNum/$MaxRetry 次失敗] 已達重試上限：$errMsg"
        }
        break
      }

      $sleepSec = [int][math]::Ceiling($delay)
      if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level 'WARN' -Message "  [第 $attemptNum/$MaxRetry 次失敗] $errMsg → ${sleepSec} 秒後進行第 $($attempt + 1)/$MaxRetry 次重試"
      } else {
        Write-Host "[WARN] [第 $attemptNum/$MaxRetry 次失敗] $errMsg → ${sleepSec} 秒後重試"
      }

      Start-Sleep -Seconds $sleepSec
      $delay = [math]::Min($delay * $Backoff, 60.0)
    }
  }
  return $null
}
