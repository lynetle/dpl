#!/bin/bash
# --- Docker 镜像智能更新脚本 (V8.5.1) ---
#
# 工作原理:
# 1. 创建一个临时目录来存储分页的 API 响应。
# 2. 循环获取 Docker Hub API 的所有标签页。
# 3. 将每一页的有效数据 (`.results` 数组) 保存为一个独立的 JSON 文件。
# 4. 使用 `jq -s 'add'` 命令将所有临时文件合并，确保可靠处理大量数据。
# 5. 在合并后的完整数据中，进行架构筛选和时间排序，找到最新版本。
# 6. 该方法牺牲了微小的 I/O 性能，换取了在所有情况下的最高级别鲁棒性。

# 增加了自动故障转移功能。
# 当网络环境无法直连 Docker Hub API 时，会自动切换到配置好的反向代理。

# 此版本修复了因 `set -e` 导致的、在本地无镜像时脚本提前终止的致命错误。
# 同时保留了 v8.3 的所有功能和 v8.3 优化版的逻辑。

# V8.5 优化: 将镜像清理逻辑从“全部清理”改为“仅清理被替换的旧镜像”，操作更精确安全。

# V8.5.1 新增改进：
#   ✅ 自动识别 compose 文件 (yml / yaml / compose.yml / compose.yaml)
#   ✅ 完整保留 v8.5 的精准清理逻辑与代理自动切换功能

# --- 安全设置 ---
set -eo pipefail

# --- 1. 用户配置 ---
COMPOSE_FILE="./docker-compose.yml"       # 默认配置文件路径，可被检测逻辑自动替换
PROXY_MODE="auto"                         # auto | force_on | force_off
PROXY_DOMAIN="dock.makkle.com"

# --- 2. 初始化与环境检查 ---
printf "\n=== %s ===\n" "$(date '+%Y-%m-%d %H:%M:%S')"
echo "▶️  开始执行 Docker 镜像智能更新脚本 (v8.5.1 - 自动识别版)..."

# 基础命令检测
command -v docker >/dev/null 2>&1 || { echo >&2 "❌ 错误: 'docker' 命令未找到。请先安装 Docker。"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "❌ 错误: 'curl' 命令未找到。请安装 curl。"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "❌ 错误: 'jq' 命令未找到。请安装 jq。"; exit 1; }

# --- Compose 文件自动识别 ---
if [ ! -f "$COMPOSE_FILE" ]; then
    if [ -f "./docker-compose.yaml" ]; then
        COMPOSE_FILE="./docker-compose.yaml"
    elif [ -f "./compose.yml" ]; then
        COMPOSE_FILE="./compose.yml"
    elif [ -f "./compose.yaml" ]; then
        COMPOSE_FILE="./compose.yaml"
    else
        echo "❌ 错误: 未找到任何 Compose 文件。"
        echo "💡 支持文件名: docker-compose.yml / docker-compose.yaml / compose.yml / compose.yaml"
        exit 1
    fi
fi
echo "✅ 已检测到 Compose 文件: $COMPOSE_FILE"

# Compose 命令封装
docker_compose_cmd() {
    if docker compose version &>/dev/null; then
        docker compose "$@"
    elif docker-compose version &>/dev/null; then
        docker-compose "$@"
    else
        echo >&2 "❌ 错误: 'docker compose' 或 'docker-compose' 命令均未找到。"
        exit 1
    fi
}

# --- 3. 核心功能函数 ---
check_api_connectivity() {
    echo "    -> 正在测试直连 Docker Hub API (超时 5 秒)..." >&2
    if curl --connect-timeout 5 -s -f -o /dev/null "https://hub.docker.com"; then
        echo "    -> ✅ 直连测试成功。" >&2
        return 0
    else
        echo "    -> ⚠️ 直连测试失败。" >&2
        return 1
    fi
}

# 代理控制逻辑
USE_PROXY_EFFECTIVE=false
case "$PROXY_MODE" in
    "auto")
        echo "ℹ️  代理模式: 自动。正在检测网络连通性..."
        if ! check_api_connectivity; then
            echo "‼️  检测到无法直连 API，已自动启用代理: $PROXY_DOMAIN"
            USE_PROXY_EFFECTIVE=true
        else
            echo "✅  网络检测正常，将使用直连方式。"
            USE_PROXY_EFFECTIVE=false
        fi
        ;;
    "force_on")
        echo "ℹ️  代理模式: 强制开启。所有 API 请求将通过 $PROXY_DOMAIN"
        USE_PROXY_EFFECTIVE=true
        ;;
    "force_off")
        echo "ℹ️  代理模式: 强制关闭。将尝试直连所有 API。"
        USE_PROXY_EFFECTIVE=false
        ;;
    *)
        echo >&2 "❌ 错误: 无效的 PROXY_MODE 设置: '$PROXY_MODE'。"
        exit 1
        ;;
esac

if [ "$USE_PROXY_EFFECTIVE" = true ]; then
    AUTH_BASE_URL="https://${PROXY_DOMAIN}/auth"
    REGISTRY_BASE_URL="https://${PROXY_DOMAIN}/registry"
    HUB_BASE_URL="https://${PROXY_DOMAIN}/hub"
else
    AUTH_BASE_URL="https://auth.docker.io"
    REGISTRY_BASE_URL="https://registry-1.docker.io"
    HUB_BASE_URL="https://hub.docker.com"
fi

get_remote_digest() {
    local full_image=$1
    local image_repo
    image_repo=$(echo "$full_image" | cut -d: -f1)
    local image_tag
    if [[ "$full_image" != *":"* ]]; then
        image_tag="latest"
    else
        image_tag=$(echo "$full_image" | cut -d: -f2)
    fi
    if [[ "$image_repo" != *"/"* ]]; then
        image_repo="library/$image_repo"
    fi
    echo "    🔄 正在从 API 获取 '$full_image' 的远程 Digest..." >&2
    local token
    token=$(curl -s "${AUTH_BASE_URL}/token?service=registry.docker.io&scope=repository:${image_repo}:pull" | jq -r .token)
    local digest
    digest=$(curl -s --head -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Authorization: Bearer $token" "${REGISTRY_BASE_URL}/v2/${image_repo}/manifests/${image_tag}" |
        grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r')
    echo "$digest"
}

get_local_digest() {
    local full_image=$1
    echo "    ℹ️  正在获取 '$full_image' 的本地 Digest..." >&2
    docker image inspect --format='{{range .RepoDigests}}{{.}}{{end}}' "$full_image" 2>/dev/null | cut -d'@' -f2 || true
}

get_latest_compatible_tag() {
    local image_repo=$1
    local target_arch=$2
    local repo_name=$image_repo
    if [[ "$repo_name" != *"/"* ]]; then repo_name="library/$repo_name"; fi
    echo "    🔄 正在从 API 获取并处理所有标签..." >&2
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf -- "$tmp_dir"' EXIT
    local next_page_url="${HUB_BASE_URL}/v2/repositories/${repo_name}/tags?page_size=100"
    local index=0
    while [ -n "$next_page_url" ] && [ "$next_page_url" != "null" ]; do
        echo -n "        - 正在获取分页: ${next_page_url#*//*/}" >&2
        local page_data
        page_data=$(curl -sL "$next_page_url")
        echo " (ok)" >&2
        if ! echo "$page_data" | jq -e '.results' >/dev/null 2>&1; then
            echo "    ⚠️ 警告: API 返回格式无效或为空。" >&2
            break
        fi
        echo "$page_data" | jq '.results' >"$tmp_dir/page_$index.json"
        next_page_url=$(echo "$page_data" | jq -r '.next')
        if [ "$USE_PROXY_EFFECTIVE" = true ] && [ -n "$next_page_url" ] && [ "$next_page_url" != "null" ]; then
            next_page_url=$(echo "$next_page_url" | sed "s|https://hub.docker.com|${HUB_BASE_URL}|")
        fi
        index=$((index + 1))
    done
    if [ ! -f "$tmp_dir/page_0.json" ]; then
        echo ""
        return
    fi
    jq -s 'add' "$tmp_dir"/page_*.json |
        jq -r --arg target_arch "$target_arch" \
        'map(select(.images[]?.architecture == $target_arch)) | sort_by(.last_updated) | reverse | .[0].name | select(. != null)'
}

# --- 4. 主逻辑 ---
echo "🔎 正在解析 $COMPOSE_FILE..."
IMAGE_LINE=$(grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n 1)
IMAGE_VALUE=$(echo "$IMAGE_LINE" | sed -E "s/^\s*image:\s*['\"]?//;s/['\"]?\s*$//")

if [[ "$IMAGE_VALUE" == *".dkr.ecr."* || "$IMAGE_VALUE" == *"gcr.io"* || "$IMAGE_VALUE" == *"ghcr.io"* ]]; then
    echo "🟡 警告: 检测到非 Docker Hub 镜像 ($IMAGE_VALUE)。跳过检查。"
    echo "✅ 无需任何操作，脚本执行完毕。"
    exit 0
fi

IMAGE_REPO=$(echo "$IMAGE_VALUE" | cut -d: -f1)
CURRENT_TAG=$(echo "$IMAGE_VALUE" | grep -q ':' && echo "$IMAGE_VALUE" | cut -d: -f2 || echo "latest")

ARCH=$(uname -m)
case "$ARCH" in
x86_64) ARCH="amd64" ;;
aarch64) ARCH="arm64" ;;
armv7l) ARCH="arm" ;;
esac

echo "--------------------------------------------------"
echo "ℹ️  当前配置信息:"
echo "    - Compose 文件: $COMPOSE_FILE"
echo "    - 镜像仓库:     $IMAGE_REPO"
echo "    - 当前标签:     $CURRENT_TAG"
echo "    - 本机架构:     $ARCH"
echo "--------------------------------------------------"

echo "🔄 正在查找网络上时间最新的、且架构兼容的版本..."
LATEST_VALID_TAG=$(get_latest_compatible_tag "$IMAGE_REPO" "$ARCH")
if [ -z "$LATEST_VALID_TAG" ] || [ "$LATEST_VALID_TAG" == "null" ]; then
    echo "🤷 未找到与本机架构兼容的版本。"
    echo "✅ 无需任何操作，脚本执行完毕。"
    exit 0
fi
echo "📌 最新兼容版本为: $LATEST_VALID_TAG"

NEEDS_UPDATE=false
NEW_TAG=""

if [ "$LATEST_VALID_TAG" != "$CURRENT_TAG" ]; then
    echo "⬆️  发现新版本！"
    echo "    - 当前版本: $CURRENT_TAG"
    echo "    - 最新版本: $LATEST_VALID_TAG"
    NEEDS_UPDATE=true
    NEW_TAG=$LATEST_VALID_TAG
else
    echo "🔄 标签一致，检查内容指纹..."
    LOCAL_DIGEST=$(get_local_digest "${IMAGE_REPO}:${CURRENT_TAG}")
    if [ -z "$LOCAL_DIGEST" ]; then
        echo "🟡 本地镜像不存在，需要拉取。"
        NEEDS_UPDATE=true
        NEW_TAG=$CURRENT_TAG
    else
        REMOTE_DIGEST=$(get_remote_digest "${IMAGE_REPO}:${CURRENT_TAG}")
        if [ -z "$REMOTE_DIGEST" ]; then
            echo "🤷 无法获取远程 Digest，跳过内容检查。"
        elif [ "$REMOTE_DIGEST" != "$LOCAL_DIGEST" ]; then
            echo "⬆️  内容更新！远程 Digest 不同。"
            NEEDS_UPDATE=true
            NEW_TAG=$CURRENT_TAG
        else
            echo "✅ 内容一致，无需更新。"
        fi
    fi
fi

if [ "$NEEDS_UPDATE" = true ]; then
    echo "🚀 开始执行更新流程..."

    echo "0/5: 记录当前镜像ID..."
    OLD_IMAGE_ID=$(docker image inspect --format='{{.Id}}' "$IMAGE_VALUE" 2>/dev/null || true)
    [ -n "$OLD_IMAGE_ID" ] && echo "    -> 旧镜像ID: $OLD_IMAGE_ID"

    echo "1/5: 更新 Compose 文件..."
    ORIGINAL_IMAGE_LINE_IN_FILE=$(grep -E "^\s*image:\s*['\"]?${IMAGE_VALUE}['\"]?" "$COMPOSE_FILE")
    sed -i.bak -E "s|image:\s*['\"]?${IMAGE_VALUE}['\"]?|image: \"${IMAGE_REPO}:${NEW_TAG}\"|" "$COMPOSE_FILE"
    echo "    ✅ 文件更新成功, 已创建备份: $COMPOSE_FILE.bak"

    echo "2/5: 拉取新镜像 ${IMAGE_REPO}:${NEW_TAG}..."
    if ! docker pull "${IMAGE_REPO}:${NEW_TAG}"; then
        echo "❌ 拉取失败，正在恢复文件..."
        sed -i -E "s|image:\s*['\"]?${IMAGE_REPO}:${NEW_TAG}['\"]?|${ORIGINAL_IMAGE_LINE_IN_FILE}|" "$COMPOSE_FILE"
        echo "✅ 文件已恢复。"
        exit 1
    fi

    echo "3/5: 重启服务..."
    docker_compose_cmd -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans
    echo "    ✅ 服务已成功重启！"

    echo "4/5: 精确清理旧镜像..."
    if [ -n "$OLD_IMAGE_ID" ]; then
        NEW_IMAGE_ID=$(docker image inspect --format='{{.Id}}' "${IMAGE_REPO}:${NEW_TAG}" 2>/dev/null)
        if [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
            echo "    -> 删除旧镜像 ($OLD_IMAGE_ID)..."
            docker rmi -f "$OLD_IMAGE_ID" >/dev/null 2>&1 && echo "    ✅ 已删除旧镜像。"
        fi
    fi

    echo "5/5: 清理悬空镜像..."
    docker image prune -f >/dev/null
    echo "    ✅ 清理完成。"

    echo "--------------------------------------------------"
    echo "🎉 更新流程完成！"
    echo "--------------------------------------------------"
else
    echo "✅ 无需任何操作，脚本执行完毕。"
fi

exit 0
