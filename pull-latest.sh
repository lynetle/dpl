#!/bin/bash

# ===================================================================================
# 智能 Docker Compose 镜像更新脚本 (v2.1 - 稳定最终版)
#
# 核心逻辑:
# 1. 始终以 Docker Hub 上按时间顺序最新发布的标签为最终更新目标。
# 2. 直接对比 "最新发布的标签" 和 "当前使用的标签"。
# 3. 如果两者标签名不同，则直接触发更新。
# 4. 仅在两者标签名相同时 (例如都是'latest')，才对这类动态标签执行 digest 检查，
#    以判断其内容本身是否被覆盖更新。
# 5. 自动处理架构检测、配置文件修改和容器重启。
# ===================================================================================

# 在遇到错误时立即退出
set -e

# --- 配置 ---
# 定义动态标签列表，这些标签的内容可能会改变而标签名不变
DYNAMIC_TAGS=("latest" "beta" "dev" "nightly" "edge" "unstable")


# --- 初始化与环境检查 ---
echo "🚀 开始执行智能镜像更新脚本..."

# 自动判断 docker-compose 配置文件名
if [[ -f "docker-compose.yml" ]]; then
  COMPOSE_FILE="docker-compose.yml"
elif [[ -f "docker-compose.yaml" ]]; then
  COMPOSE_FILE="docker-compose.yaml"
else
  echo "❌ 错误: 当前目录没有找到 docker-compose.yml 或 docker-compose.yaml，脚本退出。"
  exit 1
fi
echo "ℹ️ 使用配置文件: $COMPOSE_FILE"

# --- 函数定义 ---

# 定义 docker compose 命令的兼容函数
# 自动检测并使用 'docker compose' (v2) 或 'docker-compose' (v1)
function docker_compose_cmd() {
  # 将所有传入参数原样传递给找到的命令
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    docker compose "$@"
  elif command -v docker-compose &>/dev/null; then
    docker-compose "$@"
  else
    echo "❌ 错误: 找不到可执行的 'docker-compose' 或 'docker compose' 命令。"
    return 1 # 返回错误码
  fi
}

# 检查一个值是否存在于数组中
# 用法: contains_element "要检查的值" "${数组[@]}"
function contains_element() {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

# --- 1. 获取本地配置信息 ---

echo "🔎 正在解析本地配置..."
# 提取 image 行，并分别获取仓库名和当前标签
IMAGE_LINE=$(grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n1 | sed -E "s/^\s*image:\s*['\"]?//;s/['\"]?$//")
IMAGE_REPO=$(echo "$IMAGE_LINE" | cut -d: -f1)
CURRENT_TAG=$(echo "$IMAGE_LINE" | cut -d: -f2)

if [[ -z "$IMAGE_REPO" || -z "$CURRENT_TAG" ]]; then
    echo "❌ 错误: 无法从 $COMPOSE_FILE 中解析出有效的 'image: repository:tag'。"
    exit 1
fi

echo "  - 当前仓库: $IMAGE_REPO"
echo "  - 当前标签: $CURRENT_TAG"

# --- 2. 获取远程仓库的最新信息 ---

echo "📡 正在从 Docker Hub 获取最新标签信息..."
# 使用 curl 和 jq 获取按时间排序的最新标签
# -s 静默模式, -L 跟随重定向
# --connect-timeout 5 设置连接超时
# --max-time 10 设置最大请求时间
LATEST_RELEASE_TAG=$(curl --connect-timeout 5 --max-time 10 -s -L "https://hub.docker.com/v2/repositories/${IMAGE_REPO}/tags/?page_size=5&ordering=last_updated" | \
                  jq -r '.results[0].name' 2>/dev/null)

if [[ -z "$LATEST_RELEASE_TAG" || "$LATEST_RELEASE_TAG" == "null" ]]; then
  echo "⚠️ 警告: 无法从 Docker Hub 获取 '${IMAGE_REPO}' 的标签信息。"
  echo "   请检查网络连接或仓库名称是否正确。脚本将尝试使用已拉取的镜像进行 digest 比较。"
  # 在这种情况下，我们无法判断是否有更新的标签，只能依赖后续的digest比较
  LATEST_RELEASE_TAG=$CURRENT_TAG # 假设当前的就是最新的，以便后续逻辑能继续
else
  echo "  - 远程最新标签: $LATEST_RELEASE_TAG"
fi
# --- 3. 核心决策：判断是否需要更新 ---

UPDATE_NEEDED=false

# 决策 1: 如果远程最新发布的标签和当前使用的标签名不同，则必须更新。
# 这是最优先的判断，例如从 'latest' 更新到 'test.amd'。
if [[ "$LATEST_RELEASE_TAG" != "$CURRENT_TAG" ]]; then
    echo "🔄 更新决策: 远程最新标签 ($LATEST_RELEASE_TAG) 与当前标签 ($CURRENT_TAG) 不同。"
    UPDATE_NEEDED=true

# 决策 2: 如果标签名相同，我们再检查它是否是一个动态标签 (如 'latest')。
# 只有动态标签才需要进一步通过 digest 判断其内容是否有变。
elif contains_element "$CURRENT_TAG" "${DYNAMIC_TAGS[@]}"; then
    echo "🔎 正在检查动态标签 '$CURRENT_TAG' 的内容是否有更新..."

    # 获取本地镜像的 digest (内容指纹)
    # 使用 --quiet 只输出ID，然后用 inspect 获取 digest
    LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_REPO}:${CURRENT_TAG}" 2>/dev/null || echo "")
    
    # 主动拉取镜像以获取最新的远程 digest
    echo "  - 正在尝试拉取 ${IMAGE_REPO}:${CURRENT_TAG} 以获取最新信息..."
    # 我们只拉取服务，不立即重启，以获取最新的镜像信息
    docker_compose_cmd -f "$COMPOSE_FILE" pull > /dev/null 2>&1
    REMOTE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_REPO}:${CURRENT_TAG}" 2>/dev/null || echo "")

    # 如果本地或远程 digest 为空，说明镜像不存在或有异常，为安全起见标记为需要更新
    if [[ -z "$LOCAL_DIGEST" || -z "$REMOTE_DIGEST" ]]; then
        echo "   - 警告: 无法获取本地或远程的 Digest，将执行更新以确保一致。"
        UPDATE_NEEDED=true
    elif [[ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]]; then
        echo "🔄 更新决策: 动态标签 '$CURRENT_TAG' 的内容已更新 (Digest不匹配)。"
        echo "  - 旧 Digest: $LOCAL_DIGEST"
        echo "  - 新 Digest: $REMOTE_DIGEST"
        UPDATE_NEEDED=true
    fi
fi

# --- 4. 执行更新 ---

if [[ "$UPDATE_NEEDED" == "true" ]]; then
    echo "🚀 检测到新版本，开始执行更新流程！"

    # 获取要更新的服务名 (docker-compose.yml中的第一个服务)
    SERVICE_NAME=$(docker_compose_cmd -f "$COMPOSE_FILE" config --services | head -n1)
    
    # 步骤 1: 如果需要，更新 docker-compose.yml 文件中的标签
    if [[ "$LATEST_RELEASE_TAG" != "$CURRENT_TAG" ]]; then
        echo "🔧 正在更新 $COMPOSE_FILE..."
        # 使用 sed 进行原地替换 (兼容 macOS 和 Linux)
        sed -i.bak "s|image: ${IMAGE_REPO}:${CURRENT_TAG}|image: ${IMAGE_REPO}:${LATEST_RELEASE_TAG}|g" "$COMPOSE_FILE"
        echo "  - 已将标签从 '$CURRENT_TAG' 更新为 '$LATEST_RELEASE_TAG'。"
        echo "  - 原始文件已备份为 ${COMPOSE_FILE}.bak"
    fi

    # 步骤 2: 停止并重新拉取镜像并启动容器
    echo "🔄 正在使用 'docker compose up' 拉取新镜像并重启服务..."
    # up -d 会自动完成 pull, stop, rm, create, start 的过程
    # --force-recreate 强制重新创建容器
    # --no-deps 不重启依赖的服务 (如果你的服务有依赖)
    # 指定服务名更新，避免影响同一compose文件中的其他服务
    docker_compose_cmd -f "$COMPOSE_FILE" up -d --force-recreate --no-deps "$SERVICE_NAME"

    # 步骤 3: 清理旧的、未使用的镜像
    echo "🧹 正在清理旧的、悬空未用的镜像..."
    docker image prune -f

    # 最终确认使用的镜像名
    FINAL_IMAGE_TAG=$LATEST_RELEASE_TAG
    if [[ -z "$FINAL_IMAGE_TAG" || "$FINAL_IMAGE_TAG" == "null" ]]; then
      FINAL_IMAGE_TAG=$CURRENT_TAG
    fi

    echo "✅ 更新成功！服务 '${SERVICE_NAME}' 已使用最新镜像 (${IMAGE_REPO}:${FINAL_IMAGE_TAG}) 重新启动。"

else
    echo "✅ 配置已是最新，无需执行任何操作。"
fi

echo "🎉 脚本执行完毕。"
