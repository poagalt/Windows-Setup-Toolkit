@echo off
:: Windows Setup Toolkit launcher.
:: Self-elevates, bypasses execution policy for this process only, and forces
:: STA so the WPF window can start.
::
:: THIS FILE MUST BE SAVED WITHOUT A BYTE ORDER MARK. cmd.exe does not strip
:: one: with a UTF-8 BOM in front of it the first line reads as the command
:: "<BOM>@echo", which fails, and command echoing therefore stays ON for the
:: whole run - which is why every line of this file was once printed to the
:: screen along with the prompt in front of it. That was the whole of that bug.
:: The elevation console below is deliberate and is not it.

setlocal
title Windows Setup Toolkit

if not exist "%~dp0WinSetupToolkit.ps1" (
    echo ERROR: WinSetupToolkit.ps1 was not found next to this launcher.
    echo Keep the whole folder together when copying it to another machine.
    echo.
    call :hold 30
    exit /b 1
)

:: Reading the LocalService hive requires elevation, and reg.exe exists on every
:: Windows install. "net session" needs the Server service running and
:: "openfiles" needs the maintain-objects-list flag, so both can report a false
:: negative and send us into an elevation loop.
reg query HKU\S-1-5-19 >nul 2>&1
if %errorlevel% equ 0 goto :run

:: This console is on purpose and stays up for as long as the UAC prompt does.
:: It was hidden for one revision, along with everything else on screen, and
:: asked for back: a prompt appearing over nothing, with no idea what raised it,
:: is worse than a line of text saying which program is asking.
echo Requesting administrator rights...
:: With no arguments this is the GUI, so elevate PowerShell directly and hidden
:: rather than re-running this script elevated. Re-running it opened a second
:: console that then sat behind the window for the whole session, which is the
:: console nobody wanted. With arguments there is console output to read, so
:: the old route stands.
::
:: Start-Process rejects an empty -ArgumentList, which is why these are separate
:: calls rather than one with '%*' spliced in - passing '' closed the window
:: instantly.
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File','\"%~dp0WinSetupToolkit.ps1\"' -Verb RunAs -WindowStyle Hidden -ErrorAction Stop } catch { exit 1 }"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs -ErrorAction Stop } catch { exit 1 }"
)
if errorlevel 1 (
    echo.
    echo Elevation was canceled or refused. Nothing has been changed.
    echo Right-click this file and choose "Run as administrator" to try again.
    echo.
    call :hold 30
)
exit /b

:run
cd /d "%~dp0"

:: Already elevated. With no arguments this is the GUI: launch it detached and
:: hidden and get out of the way, so this console closes instead of waiting
:: around behind the window. The GUI owns its own errors and its own splash.
if "%~1"=="" (
    start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0WinSetupToolkit.ps1"
    endlocal & exit /b 0
)

:: With arguments there is console output to read, so this one runs in the
:: foreground and keeps its window. Windows PowerShell 5.1 specifically - the
:: Appx and DISM cmdlets are unreliable under PowerShell 7.
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0WinSetupToolkit.ps1" %*
set RC=%errorlevel%

:: A clean exit closes this console with the window that spawned it. Anything
:: else held it open here, so the message stays on screen - but on a timer, not
:: behind a keypress.
if %RC% neq 0 (
    echo.
    echo Exited with code %RC%. See the log folder for details.
    echo.
    call :hold 60
)
:: "endlocal & exit" on one line, because %RC% has to expand before endlocal
:: discards it.
endlocal & exit /b %RC%

:: Keeps a message readable without ever demanding a keypress. Any key skips
:: the wait. Full paths on purpose: "timeout" resolves to a different program
:: under some shells, and the fallback has to be something that cannot block on
:: input, so a silent ping rather than pause.
:hold
%SystemRoot%\System32\timeout.exe /t %~1 2>nul
if not errorlevel 1 exit /b 0
%SystemRoot%\System32\ping.exe -n %~1 127.0.0.1 >nul 2>&1
exit /b 0
