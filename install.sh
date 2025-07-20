#!/bin/bash

set -e

# --- 脚本变量定义 ---
SCRIPT_NAME="pull-latest.sh"
GITHUB_RAW_URL="https://github.makkle.com/https://raw.githubusercontent.com/lynetle/dpl/main/${SCRIPT_NAME}"
DOCKER_MIRROR_URL="https://doc.makkle.com"
DAEMON_JSON_FILE="/etc/docker/daemon.json"
COMPOSE_FILE="" # 用于存储找到的 docker-compose 文件名


# --- 函数定义 ---

# 函数：检查 docker-compose 文件中的镜像是否都来自 Docker Hub
check_compose_images_no_yq() {
  echo "🔎 正在检查 docker-compose 文件中的镜像来源..."
  local images
  images=$(grep -E '^\s*image:' "$COMPOSE_FILE" | grep -v '^\s*#' | sed -e 's/^\s*image:\s*//' -e 's/["'\'']//g')

  if [ -z "$images" ]; then
    echo "⚠️ 在 $COMPOSE_FILE 中未找到任何有效的 'image:' 定义。"
    return
  fi

  while IFS= read -r img; do
    [ -z "$img" ] && continue
    local registry_part
    registry_part=$(echo "$img" | awk -F'/' '{print $1}')

    if [[ "$registry_part" == *.* ]] || [[ "$registry_part" == *:* ]]; then
      echo "❌ 错误：检测到非 Docker Hub 镜像: [$img]"
      echo "   此脚本仅支持更新来自 Docker Hub 的镜像。"
      echo "   请移除或修改该镜像的定义后重试。安装终止。"
      exit 1
    fi
  done <<< "$images"
  echo "✅ 所有镜像均来自 Docker Hub，检查通过。"
}


# 函数：添加 Docker 镜像源
add_docker_mirror() {
  echo "🔧 正在配置 Docker 镜像加速..."
  sudo mkdir -p /etc/docker
  if [ ! -s "$DAEMON_JSON_FILE" ]; then
    echo "{}" | sudo tee "$DAEMON_JSON_FILE" > /dev/null
  fi
  sudo jq --arg mirror "$DOCKER_MIRROR_URL" '.["registry-mirrors"] = [$mirror]' "$DAEMON_JSON_FILE" > daemon.json.tmp && sudo mv daemon.json.tmp "$DAEMON_JSON_FILE"
  echo "✅ 配置文件 $DAEMON_JSON_FILE 已更新。"
  echo "⚙️ 正在重启 Docker 服务以应用新配置..."
  sudo systemctl restart docker
  sleep 5
  echo "✅ Docker 服务已重启。"
  echo "🔎 正在使用新的镜像源重试连接..."
  if docker pull hello-world > /dev/null 2>&1; then
    echo "✅🎉 配置成功！现在可以顺畅连接 Docker Hub。"
    docker rmi hello-world > /dev/null 2>&1 || true
  else
    echo "❌ 警告：添加镜像源后连接 Docker Hub 仍然失败。"
    echo "   请检查网络或确认镜像源 ${DOCKER_MIRROR_URL} 是否可用。"
  fi
}


# --- 主逻辑开始 ---

# 1. 检查 docker-compose 文件是否存在
if [[ -f "docker-compose.yml" ]]; then
  COMPOSE_FILE="docker-compose.yml"
  echo "✅ 检测到文件：docker-compose.yml"
elif [[ -f "docker-compose.yaml" ]]; then
  COMPOSE_FILE="docker-compose.yaml"
  echo "✅ 检测到文件：docker-compose.yaml"
else
  echo "❌ 当前目录未找到 docker-compose.yml 或 docker-compose.yaml，安装终止。"
  exit 1
fi

# 2. 检查并安装依赖 (仅需 jq)
echo "🔎 正在检查所需依赖工具 (jq)..."
if ! command -v jq >/dev/null 2>&1; then
  echo "   - 依赖 'jq' 未安装，正在尝试安装..."
  sudo apt-get update >/dev/null
  if sudo apt-get install -y jq >/dev/null; then
    echo "   ✅ 'jq' 安装成功。"
  else
    echo "   ❌ 'jq' 安装失败。请手动执行 'sudo apt-get install jq' 后重试。"
    exit 1
  fi
else
  echo "   ✅ 依赖 'jq' 已存在。"
fi

# 3. 检查 Compose 文件中的镜像来源
check_compose_images_no_yq

# 4. 检测 Docker Hub API 连接
echo "🔎 正在检测 Docker Hub 直连速度..."
if docker pull hello-world > /dev/null 2>&1; then
  echo "✅ Docker Hub 连接正常。"
  docker rmi hello-world > /dev/null 2>&1 || true
else
  echo "❌ Docker Hub 直连失败或超时。"
  echo "💡 这可能是由于网络问题。建议为 Docker 配置国内镜像加速来解决此问题。"
  read -rp "🕒 是否要将 [${DOCKER_MIRROR_URL}] 添加为 Docker 加速镜像源？[y/N] " yn_mirror
  case "$yn_mirror" in
    [yY][eE][sS]|[yY])
      add_docker_mirror
      ;;
    *)
      echo "⏭️ 已跳过添加镜像源。请注意，后续的 Docker 操作可能会因网络问题而失败。"
      ;;
  esac
fi

# 5. 下载 pull-latest.sh 脚本
echo "🌐 正在从 GitHub 下载更新脚本：$SCRIPT_NAME"
if ! curl -fsSL "$GITHUB_RAW_URL" -o "$SCRIPT_NAME"; then
  echo "❌ 下载失败，请检查网络或 GitHub 地址是否正确：$GITHUB_RAW_URL"
  exit 1
fi

# 6. 添加执行权限
chmod +x "$SCRIPT_NAME"
echo "✅ 下载完成，已赋予执行权限：./$SCRIPT_NAME"

# 7. 检查并设置定时任务 (已优化流程和注释检查)
echo "🔎 正在检查有效的定时任务设置..."
SCRIPT_FULL_PATH="$(pwd)/$SCRIPT_NAME"

# 检查crontab中是否存在【未被注释的】、针对此完整路径的任务
# 'grep -v' 排除注释行, 'grep -Fq' 精确匹配路径
if crontab -l 2>/dev/null | grep -v '^\s*#' | grep -Fq "$SCRIPT_FULL_PATH"; then
  # 如果已存在一个有效的、未被注释的任务，直接告知用户并跳过
  echo "ℹ️ 检测到已存在有效的定时任务，无需重复设置。"
  echo "   路径: $SCRIPT_FULL_PATH"
else
  # 如果不存在有效任务（可能被注释了，或根本没有），才询问用户是否要添加
  read -rp "🕒 未检测到有效的定时任务，是否设置每天凌晨 3 点自动运行更新脚本？[y/N] " yn_cron
  case "$yn_cron" in
    [yY][eE][sS]|[yY])
      CRON_CMD="0 3 * * * cd $(pwd) && $SCRIPT_FULL_PATH >> $(pwd)/docker-update.log 2>&1"
      (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
      echo "✅ 定时任务已添加：每天凌晨 3 点在目录 $(pwd) 执行 $SCRIPT_NAME"
      ;;
    *)
      echo "⏭️ 已跳过定时任务配置。你可以随时通过手动执行 ./$SCRIPT_NAME 来更新 Docker 镜像。"
      ;;
  esac
fi

echo "🎉 安装完成！"
