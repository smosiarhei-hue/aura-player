@echo off
chcp 65001 > nul
title Sonivo VideoShot Neural Studio (RTX 4060)

echo ====================================================================
echo     ✨ SONIVO VIDEOSHOT NEURAL STUDIO - RTX 4060 GPU EDITION ✨
echo ====================================================================
echo.
echo [1/3] Проверка рабочего окружения Python и PyTorch CUDA...

where python >nul 2>nul
if %errorlevel% neq 0 (
    echo [ОШИБКА] Python не найден в системе. Убедитесь, что Python установлен.
    pause
    exit /b 1
)

echo [2/3] Запуск локального сервера Neural Studio на порту 5055...
cd /d "%~dp0"

start "" "http://localhost:5055"

echo [3/3] Сервер активен! Открываем веб-интерфейс в браузере...
echo.
echo Доступные адреса:
echo   - Локальный браузер: http://localhost:5055
echo   - Для мобильного приложения Sonivo iOS: http://localhost:5055/api/mobile/render-videoshot
echo.
echo Нажмите Ctrl+C в этом окне для остановки сервера.
echo ====================================================================

python server.py
pause
