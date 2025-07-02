#!/bin/bash

set -e

# 先判断 docker-compose.yml 或 docker-compose.yaml 是否存在
if [[ ! -f "docker-compose.yml" && ! -f "docker-compose.yaml" ]]; then
  echo "❌ 当前目录没有找到 docker-compose.yml 或 docker-compose.yaml，脚本退出。"
  exit 1
fi

# 如果是 yml 版本的，优先使用 docker-compose.yml，没有则用 docker-compose.yaml
if [[ -f "docker-compose.yml" ]]; then
  COMPOSE_FILE="docker-compose.yml"
else
  COMPOSE_FILE="docker-compose.yaml"
fi

LAST_TAG_FILE=".last_tag"
ARCH_TAG_FILE=".last_checked_arch_tag"

# 提取 image 行，并剥离前后空格和引号，兼容单双引号或无引号
IMAGE_LINE=$(grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n1 | sed -E "s/^\s*image:\s*['\"]?([^'\"]+)['\"]?.*/\1/")

# 拆分镜像名和 tag（tag 可能为空）
IMAGE=$(echo "$IMAGE_LINE" | cut -d':' -f1)
CURRENT_TAG=$(echo "$IMAGE_LINE" | cut -d':' -f2-)

# 如果没有指定 tag，默认用 "latest"
if [ "$IMAGE_LINE" = "$IMAGE" ]; then
  CURRENT_TAG="latest"
fi

# 自动获取当前平台架构信息
REQUIRED_ARCH=$(docker version -f '{{.Client.Arch}}')
REQUIRED_OS=$(docker version -f '{{.Client.Os}}')

# 获取 Docker Hub 最新 tag（按更新时间排序）
TAGS_JSON=$(curl -s "https://hub.docker.com/v2/repositories/${IMAGE}/tags?page_size=100")
LATEST_TAG=$(echo "$TAGS_JSON" | jq -r '.results | sort_by(.last_updated) | reverse | .[0].name')

# 校验 tag 是否成功获取
if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
  echo "❌ 无法获取最新 tag，请检查镜像名是否正确。"
  exit 1
fi

echo "📌 最新 tag：$LATEST_TAG"

# 跳过重复 tag
if [[ -f "$LAST_TAG_FILE" ]]; then
  LAST_TAG=$(cat "$LAST_TAG_FILE")
  if [[ "$LATEST_TAG" == "$LAST_TAG" ]]; then
    echo "⏳ 镜像未更新（仍为 $LATEST_TAG），跳过执行。"
    exit 0
  fi
fi

# 架构检查缓存命中，跳过检查
if [[ -f "$ARCH_TAG_FILE" && $(cat "$ARCH_TAG_FILE") == "$LATEST_TAG" ]]; then
  echo "✅ 架构检查已缓存，镜像 ${IMAGE}:${LATEST_TAG} 支持 ${REQUIRED_OS}/${REQUIRED_ARCH}"
else
  echo "🔍 使用 docker manifest inspect 检查镜像架构：${IMAGE}:${LATEST_TAG}"

  ARCH_MATCH=$(docker manifest inspect "${IMAGE}:${LATEST_TAG}" 2>/dev/null | \
    jq -e --arg arch "$REQUIRED_ARCH" --arg os "$REQUIRED_OS" \
    '.manifests[]? | select(.platform.architecture == $arch and .platform.os == $os)')

  if [[ -z "$ARCH_MATCH" ]]; then
    echo "❌ 镜像 ${IMAGE}:${LATEST_TAG} 不支持 ${REQUIRED_OS}/${REQUIRED_ARCH} 架构，跳过更新。"
    exit 0
  fi

  echo "$LATEST_TAG" > "$ARCH_TAG_FILE"
  echo "✅ 架构检查通过，镜像支持 ${REQUIRED_OS}/${REQUIRED_ARCH}"
fi

# 拉取镜像
echo "📥 拉取镜像：${IMAGE}:${LATEST_TAG}"
if ! docker pull "${IMAGE}:${LATEST_TAG}"; then
  echo "❌ 镜像拉取失败，请检查网络或权限。"
  exit 1
fi

# 备份并更新 compose 文件
if [[ -f "$COMPOSE_FILE" ]]; then
  cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
  sed -i -E "s|(image:\s*${IMAGE}:)[^\s]+|\1${LATEST_TAG}|" "$COMPOSE_FILE"
  echo "✅ docker-compose.yml 已更新为使用最新 tag：${LATEST_TAG}"

  # 重启服务
  echo "🚀 使用 docker compose 重启服务..."
  docker compose -f "$COMPOSE_FILE" up -d

  if [[ $? -eq 0 ]]; then
    echo "✅ 服务已成功重启，使用镜像：${IMAGE}:${LATEST_TAG}"
    echo "$LATEST_TAG" > "$LAST_TAG_FILE"
  else
    echo "❌ docker-compose 启动失败，请手动检查日志。"
  fi
else
  echo "⚠️ 找不到 ${COMPOSE_FILE}，无法替换镜像 tag 或重启服务。"
fi
