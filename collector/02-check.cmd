@echo off
setlocal
chcp 65001 >nul
set PYTHONUTF8=1
py -3 -c "import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)" >nul 2>&1
if not errorlevel 1 goto use_py
python -c "import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)" >nul 2>&1
if not errorlevel 1 goto use_python
echo Python not found. Install Python 3.11+ from https://www.python.org/downloads/windows/
echo Then run this file again.
pause
exit /b 1
:use_py
py -3 "%~dp0install_windows.py" check
set "MONITOR_EXIT=%ERRORLEVEL%"
goto done
:use_python
python "%~dp0install_windows.py" check
set "MONITOR_EXIT=%ERRORLEVEL%"
:done
echo.
if not "%MONITOR_EXIT%"=="0" echo Not completed. See the message above and WINDOWS-README.md.
pause
exit /b %MONITOR_EXIT%
