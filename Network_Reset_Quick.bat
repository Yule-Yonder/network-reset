@echo off
setlocal EnableDelayedExpansion

if /i "%~1"=="/ROUTEFIX" goto ROUTEFIX

:MENU
cls
echo ========================================
echo  Network Reset Tool
echo ========================================
echo.
echo  [1] Quick reset: disable system proxy + flush DNS   (no admin)
echo  [2] Deep reset: WinHTTP proxy + VPN/proxy leftover routes  (admin)
echo  [3] Exit
echo.
choice /c 123 /n /m "Select [1/2/3]: "
if errorlevel 3 goto END
if errorlevel 2 goto ELEVATE
goto QUICK

:QUICK
cls
echo ========================================
echo Network Reset Script (Quick Mode)
echo ========================================
echo.

echo [1/4] Checking current proxy settings...
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer
echo.

echo [2/4] Disabling system proxy...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f
echo System proxy disabled.
echo.

echo [3/4] Flushing DNS cache...
ipconfig /flushdns
echo DNS cache flushed.
echo.

echo [4/4] Verifying proxy is disabled...
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable
echo.

echo ========================================
echo Network reset completed!
echo ========================================
echo.

echo Current IP Configuration:
ipconfig
echo.

echo Testing network connection (pinging baidu.com)...
ping -n 4 www.baidu.com
echo.

choice /c 12 /n /m "Back to menu [1] or exit [2]: "
if errorlevel 2 goto END
goto MENU

:ELEVATE
echo Requesting administrator privileges (confirm the UAC prompt)...
powershell -NoProfile -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '/ROUTEFIX' -Verb RunAs } catch { exit 1 }"
if errorlevel 1 (
    echo.
    echo UAC prompt was cancelled or failed. Deep reset was NOT run.
    timeout /t 4 >nul
)
goto END

:ROUTEFIX
cls
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: Administrator privileges are required for deep reset.
    pause
    goto END
)
echo ========================================
echo  Deep Network Reset (WinHTTP + Routes)
echo ========================================
echo.
echo Resets WinHTTP proxy to direct access and removes leftover
echo routes of VPN/Proxy software (typical leftovers of Clash TUN /
echo WireGuard / VPN after an abnormal exit), so traffic falls back
echo to the physical NIC.
echo.
echo Removed here: (a) orphaned routes bound to missing/dead
echo adapters, (b) default routes on non-physical adapters.
echo Routes on healthy physical adapters are always kept. If no
echo physical default route exists, the lowest-metric default route
echo is kept as a safety net so you stay online.
echo.

echo [1/6] WinHTTP proxy status:
netsh winhttp show proxy
echo.
echo  Resetting WinHTTP proxy to direct access...
netsh winhttp reset proxy
echo.

echo [2/6] Network adapters and their status:
powershell -NoProfile -Command "Get-NetAdapter -IncludeHidden | Sort-Object ifIndex | Format-Table ifIndex, Status, Name -AutoSize | Out-String -Width 200"
echo.

echo [3/6] Current IPv4 route table:
route print -4
echo.

echo [4/6] Scanning and removing orphaned routes...
echo.
powershell -NoProfile -Command ^
    "$ErrorActionPreference='SilentlyContinue';" ^
    "$live=@{};" ^
    "Get-NetAdapter -IncludeHidden | ForEach-Object { $live[$_.ifIndex] = [string]$_.Status };" ^
    "$dead = @('Disconnected','Not Present','Disabled','Broken');" ^
    "$orphans = @(Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.Protocol -ne 'Local' -and $_.InterfaceIndex -ne 1 } | Where-Object { $st = $live[$_.InterfaceIndex]; ($null -eq $st) -or ($dead -contains $st) });" ^
    "if ($orphans.Count -eq 0) { Write-Host 'No orphaned routes found. Route table looks clean.' }" ^
    "else {" ^
    "  $orphans | ForEach-Object {" ^
    "    Write-Host ('ORPHAN ROUTE: {0}   next-hop: {1}   ifIndex: {2}   adapter: {3}' -f $_.DestinationPrefix, $_.NextHop, $_.InterfaceIndex, $live[$_.InterfaceIndex]);" ^
    "    Remove-NetRoute -DestinationPrefix $_.DestinationPrefix -InterfaceIndex $_.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue" ^
    "  };" ^
    "  Write-Host ('Removed {0} orphaned route(s).' -f $orphans.Count)" ^
    "}"
echo.

echo [5/6] Scanning and removing suspicious default routes...
echo.
powershell -NoProfile -Command ^
    "$ErrorActionPreference='SilentlyContinue';" ^
    "$physUp = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | ForEach-Object { [int]$_.ifIndex } | Select-Object -Unique);" ^
    "Write-Host ('Active physical NIC ifIndex: {0}' -f $(if ($physUp.Count) { $physUp -join ', ' } else { '(none)' }));" ^
    "$suspects = @();" ^
    "foreach ($af in @('IPv4','IPv6')) {" ^
    "  $pfx = '0.0.0.0/0'; if ($af -eq 'IPv6') { $pfx = '::/0' }" ^
    "  $defs = @(Get-NetRoute -AddressFamily $af -DestinationPrefix $pfx | Where-Object { $_.InterfaceIndex -ne 1 });" ^
    "  if ($defs.Count -eq 0) { continue }" ^
    "  foreach ($g in @($defs | Group-Object InterfaceIndex)) {" ^
    "    $best = @($g.Group | Sort-Object { $_.RouteMetric + $_.InterfaceMetric })[0];" ^
    "    if ($physUp -notcontains [int]$g.Name) {" ^
    "      $suspects += @($g.Group);" ^
    "    } else {" ^
    "      $suspects += @($g.Group | Where-Object { $_.NextHop -ne $best.NextHop });" ^
    "    }" ^
    "  }" ^
    "  $left = @($defs | Where-Object { $physUp -contains [int]$_.InterfaceIndex });" ^
    "  if ($left.Count -eq 0) {" ^
    "    $best = $defs | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1;" ^
    "    $suspects = @($suspects | Where-Object { [int]$_.InterfaceIndex -ne [int]$best.InterfaceIndex });" ^
    "    Write-Host ('SAFETY KEEP: {0} on ifIndex {1} (no physical default route; lowest metric kept to stay online)' -f $pfx, $best.InterfaceIndex);" ^
    "  }" ^
    "}" ^
    "if ($suspects.Count -eq 0) { Write-Host 'No suspicious default routes. Default route looks clean.' }" ^
    "else {" ^
    "  foreach ($r in $suspects) {" ^
    "    Write-Host ('SUSPECT DEFAULT ROUTE: {0}   next-hop: {1}   ifIndex: {2}   adapter: {3}   metric: {4}' -f $r.DestinationPrefix, $r.NextHop, $r.InterfaceIndex, $r.InterfaceAlias, ($r.RouteMetric + $r.InterfaceMetric));" ^
    "    Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $r.InterfaceIndex -NextHop $r.NextHop -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue;" ^
    "    Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $r.InterfaceIndex -NextHop $r.NextHop -PolicyStore PersistentStore -Confirm:$false -ErrorAction SilentlyContinue" ^
    "  };" ^
    "  Write-Host ('Removed {0} suspicious default route(s), active + persistent.' -f $suspects.Count)" ^
    "}"
echo.

echo [6/6] Verifying after reset...
ipconfig /flushdns
echo.
netsh winhttp show proxy
echo.
route print -4
echo.

echo Testing network connection (pinging baidu.com)...
ping -n 4 www.baidu.com
echo.

echo Done. Press any key to close...
pause >nul
goto END

:END
endlocal
exit /b 0
