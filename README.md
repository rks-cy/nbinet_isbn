# v3.4-fix3
- 修正 PS 5.1 `Join-Path` 只接受兩個位置參數的限制（改為先組 `$libDir`，再 `Join-Path $libDir 'http.ps1'`）。
- 保留 v3.4-fix2 的 `Invoke-WebRequestCompat` 與強制陣列化的 ISBN 清單、log 分流等。
