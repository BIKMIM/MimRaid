@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title MimRaid Deploy

echo ================================
echo    MimRaid GitHub Deploy
echo ================================
echo.

set "TOC_PATH=%~dp0MimRaid.toc"
set "LUA_PATH=%~dp0Settings.lua"

rem Read current version from TOC (## Version: X.Y.Z)
powershell -NoProfile -Command "$m = Select-String -Path '%TOC_PATH%' -Pattern '^##\s*Version:\s*(\S+)' | Select-Object -First 1; if ($m) { $m.Matches[0].Groups[1].Value | Out-File -Encoding ascii '%TEMP%\mimraid_ver.txt' -NoNewline }"
set CURRENT_VER=
if exist "%TEMP%\mimraid_ver.txt" (
    set /p CURRENT_VER=<"%TEMP%\mimraid_ver.txt"
    del "%TEMP%\mimraid_ver.txt" >nul 2>&1
)
if "%CURRENT_VER%"=="" (
    echo [ERROR] Cannot read version from MimRaid.toc
    pause
    exit /b 1
)

rem Suggest next patch version (X.Y.Z -> X.Y.Z+1)
echo %CURRENT_VER%| findstr /R /C:"^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo [WARN] Current version not SEMVER: %CURRENT_VER%
    set SUGGESTED_VER=%CURRENT_VER%
) else (
    for /f "tokens=1-3 delims=." %%a in ("%CURRENT_VER%") do (
        set /a NEXT_PATCH=%%c + 1
        set SUGGESTED_VER=%%a.%%b.!NEXT_PATCH!
    )
)

rem Show last commit subject
set LAST_COMMIT=
for /f "delims=" %%i in ('git log -1 --format^=%%s 2^>nul') do set LAST_COMMIT=%%i

rem === Compute suggested commit message ===
rem 1순위: .deploy-msg 파일 (Claude 가 작업 끝낼 때 구체 메시지 박아둠)
rem 2순위: git status --short 의 변경 .lua/.xml/.toc 파일명 → "Update file1, file2"
rem        MimRaid.toc / Settings.lua 는 매 deploy 마다 자동 변경되므로 잡음 회피 차원 제외.
set "SUGGESTED="
if exist "%~dp0.deploy-msg" (
    set /p SUGGESTED=<"%~dp0.deploy-msg"
)
if "!SUGGESTED!"=="" (
    powershell -NoProfile -Command "$f = git status --short | ForEach-Object { ($_ -replace '^...','').Trim() } | Where-Object { $_ -match '\.(lua|xml|toc)$' -and $_ -notmatch '(MimRaid\.toc|Settings\.lua)$' } | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique; if ($f) { 'Update ' + ($f -join ', ') } | Out-File -Encoding utf8 '%TEMP%\mimraid_msg.txt' -NoNewline" 2>nul
    if exist "%TEMP%\mimraid_msg.txt" (
        set /p SUGGESTED=<"%TEMP%\mimraid_msg.txt"
        del "%TEMP%\mimraid_msg.txt" >nul 2>&1
    )
)

if not "!LAST_COMMIT!"=="" echo Last deploy  : !LAST_COMMIT!
echo Current ver  : %CURRENT_VER%
echo Next version : !SUGGESTED_VER!
if not "!SUGGESTED!"=="" echo Suggested msg: !SUGGESTED!
echo.

rem === Version prompt ===
set /p NEW_VER=New version [Enter = !SUGGESTED_VER!]:
if "%NEW_VER%"=="" (
    set NEW_VER=!SUGGESTED_VER!
    echo Use: !NEW_VER!
) else (
    if /i "!NEW_VER:~0,1!"=="v" set NEW_VER=!NEW_VER:~1!
    echo Change: %CURRENT_VER% -^> !NEW_VER!
)

rem Safety: must be X.Y.Z
echo !NEW_VER!| findstr /R /C:"^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo.
    echo [ERROR] Version must be X.Y.Z ^(e.g. 0.9.95^). Got: !NEW_VER!
    pause
    exit /b 1
)
echo.

rem === Commit message prompt ===
rem   Enter       = 추천 메시지 그대로 사용 (없으면 vX.Y.Z 만)
rem   Space+Enter = 빈 메시지 (vX.Y.Z 만 commit 메시지로)
rem   그 외 텍스트 = 입력한 텍스트 그대로
if not "!SUGGESTED!"=="" (
    echo  ----- Suggested commit message -----
    echo    !SUGGESTED!
    echo  ------------------------------------
    set /p COMMIT_MSG=Commit message [Enter = use suggested / Space = empty]:
    if "!COMMIT_MSG!"=="" set COMMIT_MSG=!SUGGESTED!
) else (
    set /p COMMIT_MSG=Commit message [example: fix bid validation / Space = empty]:
)
rem 공백 한 칸만 입력하면 "메시지 비우기" 의도로 간주
if "!COMMIT_MSG!"==" " set COMMIT_MSG=
echo.

echo ================================
echo   Deploy Info
echo ================================
echo   Version : !NEW_VER!
if "!COMMIT_MSG!"=="" (
    echo   Message : v!NEW_VER!
) else (
    echo   Message : v!NEW_VER! !COMMIT_MSG!
)
echo ================================
echo.
echo Deploy?  [Enter] = Yes  /  [Esc] = Cancel
powershell -NoProfile -Command "do { $k=[Console]::ReadKey($true) } until ($k.Key -eq 'Enter' -or $k.Key -eq 'Escape'); if ($k.Key -eq 'Escape') { exit 1 } else { exit 0 }"
if errorlevel 1 (
    echo Cancelled.
    pause
    exit /b 0
)
echo.

rem -- Step 1: Version update (TOC + Settings.lua)
if "!NEW_VER!"=="%CURRENT_VER%" (
    echo [1/3] No version change - skip
    goto :step2
)

echo [1/3] Updating version files...

rem TOC: line "## Version: X.Y.Z"
powershell -NoProfile -Command "$c=(Get-Content '%TOC_PATH%' -Raw -Encoding UTF8) -replace '(?m)^##\s*Version:.*$', '## Version: !NEW_VER!'; [System.IO.File]::WriteAllText('%TOC_PATH%', $c, (New-Object System.Text.UTF8Encoding $false))"
if errorlevel 1 (
    echo.
    echo [ERROR] Failed to update TOC
    pause
    exit /b 1
)

rem Settings.lua: MR.VERSION = "X.Y.Z"
rem [char]34 트릭으로 큰따옴표 동적 생성, 패턴은 \S* 사용 (cmd 의 ^ escape 회피)
powershell -NoProfile -Command "$q=[char]34; $c=(Get-Content '%LUA_PATH%' -Raw -Encoding UTF8) -replace ('MR\.VERSION\s*=\s*' + $q + '\S*' + $q), ('MR.VERSION = ' + $q + '!NEW_VER!' + $q); [System.IO.File]::WriteAllText('%LUA_PATH%', $c, (New-Object System.Text.UTF8Encoding $false))"
if errorlevel 1 (
    echo.
    echo [ERROR] Failed to update Settings.lua
    pause
    exit /b 1
)

echo [1/3] Version updated to !NEW_VER!

:step2
echo.

rem -- Step 2: Git pull + commit
echo [2/3] Git commit...
git pull --rebase --autostash origin main
if errorlevel 1 (
    echo.
    echo [ERROR] Git pull failed. Resolve conflicts then retry.
    pause
    exit /b 1
)
git add .
git status --short
echo.
if "!COMMIT_MSG!"=="" (
    git commit -m "v!NEW_VER!"
) else (
    git commit -m "v!NEW_VER! !COMMIT_MSG!"
)
if errorlevel 1 (
    echo.
    echo [ERROR] Nothing to commit or commit failed.
    pause
    exit /b 1
)
echo [2/3] Commit done
echo.

rem -- Step 3: Push to GitHub
echo [3/3] Pushing to GitHub...
git push origin main
if errorlevel 1 (
    echo.
    echo [ERROR] Push failed. Check network or GitHub access.
    pause
    exit /b 1
)
echo [3/3] Push done
echo.

rem 추천 메시지 파일 소비 후 삭제 (다음 배포에 재사용 방지)
if exist "%~dp0.deploy-msg" del "%~dp0.deploy-msg" >nul 2>&1

echo ================================
echo    Done^^!  v!NEW_VER!
echo ================================
echo.
pause
