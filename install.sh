#!/bin/bash

set -e

sudo apt update
sudo apt install -y jq

# 设置变量：目标文件名和 GitHub 地址
SCRIPT_NAME="pull-latest.sh"
GITHUB_RAW_URL="https://github.makkle.com/https://raw.githubusercontent.com/tuosujie/dpl/main/${SCRIPT_NAME}"

# 检查 docker-compose 文件是否存在
if [[ -f "docker-compose.yml" || -f "docker-compose.yaml" ]]; then
  echo "✅ 检测到 docker-compose 文件。"
else
  echo "❌ 当前目录未找到 docker-compose.yml 或 docker-compose.yaml，安装终止。"
  exit 1
fi

# 下载 pull-latest.sh
echo "🌐 正在从 GitHub 下载更新脚本：$SCRIPT_NAME"
curl -fsSL "$GITHUB_RAW_URL" -o "$SCRIPT_NAME"

# 检查下载是否成功
if [[ ! -f "$SCRIPT_NAME" ]]; then
  echo "❌ 下载失败，请检查 GitHub 地址是否正确。"
  exit 1
fi

# 添加执行权限
chmod +x "$SCRIPT_NAME"
echo "✅ 下载完成，已赋予执行权限：./$SCRIPT_NAME"

# 询问是否设置定时任务
read -rp "🕒 是否设置每天凌晨 3 点自动运行该脚本？[y/N] " yn
case "$yn" in
  [yY][eE][sS]|[yY])
    CRON_CMD="0 3 * * * $(pwd)/$SCRIPT_NAME >> $(pwd)/docker-update.log 2>&1"
    
    # 判断是否已存在相同命令
    if crontab -l 2>/dev/null | grep -Fq "$SCRIPT_NAME"; then
      echo "⚠️ 已存在相同定时任务，跳过添加。"
    else
      (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
      echo "✅ 定时任务已添加：每天凌晨 3 点执行 $SCRIPT_NAME"
    fi
    ;;
  *)
    echo "⏭️ 已跳过定时任务配置。你可以手动执行：./$SCRIPT_NAME"
    ;;
esac
