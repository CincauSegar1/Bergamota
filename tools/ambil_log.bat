@echo off
title Project Apple - Universal USB Boot Log Grabber
echo ======================================================================
echo   Project Apple / Bergamota - USB Boot Log Grabber
echo ======================================================================
echo.

where python >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    python "%~dp0ambil_log.py"
    goto end
)

where py >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    py "%~dp0ambil_log.py"
    goto end
)

echo [ERROR] Python tidak ditemukan di sistem Windows ini!
echo Silakan download dan install Python dari https://www.python.org/
echo Pastikan mencentang "Add Python to PATH" saat menginstall.
echo.

:end
echo.
echo ======================================================================
echo Program telah selesai. Tekan sembarang tombol untuk keluar...
pause >nul
