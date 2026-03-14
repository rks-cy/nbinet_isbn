#Requires -Version 3.0

function Get-DocOrNull {
  param([Parameter(Mandatory=$true)] $Response)
  try { return $Response.ParsedHtml } catch { return $null }
}

function HtmlDecode {
  param([string]$s)
  try { return [System.Web.HttpUtility]::HtmlDecode($s) } catch { try { return [System.Net.WebUtility]::HtmlDecode($s) } catch { return $s } }
}

function Test-NoResult {
  param([Parameter(Mandatory=$true)] $Response)
  $html = $Response.Content
  if ($html -match '沒有查獲符合查詢條件的館藏') { return $true }

  $doc = Get-DocOrNull -Response $Response
  if ($doc -ne $null) {
    try { $a = $doc.querySelector('span.briefcitTitle a'); return ($a -eq $null) } catch {
      $pattern = '<span[^>]*class=["'']briefcitTitle["''][^>]*>\s*<a[^>]*href=["'']([^"'']+)["'']'
      $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      return -not $m.Success
    }
  } else {
    $pattern = '<span[^>]*class=["'']briefcitTitle["''][^>]*>\s*<a[^>]*href=["'']([^"'']+)["'']'
    $m = [regex]::Match($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return -not $m.Success
  }
}

function Test-HasPagination {
  param([Parameter(Mandatory=$true)] $Response)
  $html = $Response.Content
  if ($html -match '>(\s*)Prev(\s*)<' -or $html -match '>(\s*)Next(\s*)<') { return $true }
  if ($html -match 'href=["''][^"'']*(\?|&)(offset|page)=\d+') { return $true }
  return $false
}

function Get-FirstResultLink {
  param(
    [Parameter(Mandatory=$true)] $Response,
    [Parameter(Mandatory=$true)] [string]$BaseOrigin
  )
  $doc = Get-DocOrNull -Response $Response
  if ($doc -ne $null) {
    try {
      $anchor = $doc.querySelector('span.briefcitTitle a')
      if ($anchor -ne $null) {
        $href = $anchor.getAttribute('href'); if (-not $href) { $href = $anchor.href }
        if ($href) { $href = HtmlDecode $href; if ($href -like 'about:*') { $href = $href.Substring(6) }; return (Build-AbsoluteUrl -BaseOrigin $BaseOrigin -Href $href) }
      }
      $spans = $doc.getElementsByTagName('span')
      if ($spans) {
        for ($i=0; $i -lt $spans.length; $i++) {
          $s = $spans.item($i); $cls = $s.className
          if ($cls -and ($cls -match '(^|\s)briefcitTitle(\s|$)')) {
            $as = $s.getElementsByTagName('a')
            if ($as -and $as.length -gt 0) {
              $href = $as.item(0).getAttribute('href'); if (-not $href) { $href = $as.item(0).href }
              if ($href) { $href = HtmlDecode $href; if ($href -like 'about:*') { $href = $href.Substring(6) }; return (Build-AbsoluteUrl -BaseOrigin $BaseOrigin -Href $href) }
            }
          }
        }
      }
    } catch { }
  }
  $pattern = '<span[^>]*class=["'']briefcitTitle["''][^>]*>\s*<a[^>]*href=["'']([^"'']+)["'']'
  $m = [regex]::Match($Response.Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) { $href = HtmlDecode $m.Groups[1].Value; if ($href -like 'about:*') { $href = $href.Substring(6) }; return (Build-AbsoluteUrl -BaseOrigin $BaseOrigin -Href $href) }
  return $null
}

function Get-MarcLink {
  param(
    [Parameter(Mandatory=$true)] $Response,
    [Parameter(Mandatory=$true)] [string]$DetailUrl,
    [Parameter(Mandatory=$true)] [string]$BaseOrigin
  )
  $html = $Response.Content
  $doc  = Get-DocOrNull -Response $Response

  if ($doc -ne $null) {
    try {
      $imgs = $doc.getElementsByTagName('img')
      if ($imgs) {
        for ($i=0; $i -lt $imgs.length; $i++) {
          $img = $imgs.item($i); $alt = $img.getAttribute('alt')
          if ($alt -and $alt -like '*MARC*顯示*') {
            $parent = $img.parentElement
            if ($parent -and $parent.tagName -eq 'A') {
              $href = $parent.getAttribute('href'); if (-not $href) { $href = $parent.href }
              if ($href) { $href = HtmlDecode $href; if ($href -like 'about:*') { $href = $href.Substring(6) }; return (Build-AbsoluteUrl -BaseOrigin $BaseOrigin -Href $href) }
            }
          }
        }
      }
      $as = $doc.getElementsByTagName('a')
      if ($as) {
        for ($i=0; $i -lt $as.length; $i++) {
          $a = $as.item($i); $title = $a.getAttribute('title')
          if ($title -and $title -like '*MARC*顯示*') {
            $href = $a.getAttribute('href'); if (-not $href) { $href = $a.href }
            if ($href) { $href = HtmlDecode $href; if ($href -like 'about:*') { $href = $href.Substring(6) }; return (Build-AbsoluteUrl -BaseOrigin $BaseOrigin -Href $href) }
          }
        }
      }
    } catch { }
  }

  $m = [regex]::Match($html, '<a[^>]+href=["'']([^"'']*/marc[^"'']*)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) { $href = HtmlDecode $m.Groups[1].Value; if ($href -like 'about:*') { $href = $href.Substring(6) }; return (Build-AbsoluteUrl -BaseOrigin $BaseOrigin -Href $href) }

  if ($DetailUrl -like '*/frameset*') { return ($DetailUrl -replace '/frameset','/marc') }

  $fm = [regex]::Matches($html, '<frame[^>]+src=["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  for ($i=0; $i -lt $fm.Count; $i++) {
    $src = $fm[$i].Groups[1].Value; $src = HtmlDecode $src
    if ($src -match '/marc') { return (Build-AbsoluteUrl -BaseOrigin $BaseOrigin -Href $src) }
  }

  return $null
}

function Get-PreText {
  param([Parameter(Mandatory=$true)] $Response)
  $doc = Get-DocOrNull -Response $Response
  if ($doc -ne $null) {
    try { $pres = $doc.getElementsByTagName('pre'); if ($pres -and $pres.length -gt 0) { $text = $pres.item(0).innerText; if ($text) { return $text } } } catch { }
  }
  $m = [regex]::Match($Response.Content, '<pre[^>]*>([\s\S]*?)</pre>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) {
    $inner = $m.Groups[1].Value
    $inner = $inner -replace '&nbsp;',' '
    $inner = $inner -replace '&amp;','&'
    $inner = $inner -replace '&#x0D;',''
    return $inner
  }
  return $null
}
