@echo off
cd /d "%~dp0"
set "PYTHON310=%LOCALAPPDATA%\Programs\Python\Python310\python.exe"
if exist "%PYTHON310%" (
    "%PYTHON310%" kr_quicksave.py
) else (
    py -3.10 kr_quicksave.py
)
if errorlevel 1 pause
