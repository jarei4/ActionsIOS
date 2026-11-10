@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo.
echo   ╭──────────────────────────────────────────────╮
echo   │   Aurora Console · 极光控制台                │
echo   ╰──────────────────────────────────────────────╯
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo   [x] 找不到 node。请先装 Node.js 22.5+ https://nodejs.org
  echo.
  pause
  exit /b 1
)

if not exist "data" mkdir "data"

echo   正在启动服务端（新窗口）。窗口里的「局域网」一行就是手机要填的地址。
echo   本机控制台会在 2 秒后自动打开浏览器。
echo.

start "Aurora Server" cmd /k "node server/index.js"
timeout /t 2 >nul
start "" "http://127.0.0.1:8787"

echo   手机安装步骤（无需签名、不会掉签）：
echo     1. iPhone 连同一个 Wi-Fi
echo     2. Safari 打开上面窗口里的「局域网」地址
echo     3. 创建账号登录
echo     4. 分享 → 添加到主屏幕 → 添加
echo   主屏上就会出现「极光」，点开是全屏运行，和 App 一样。
echo.
timeout /t 8 >nul
