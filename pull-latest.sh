#!/bin/bash
# --- Docker 镜像智能更新脚本 (v5.0 - 绝对最新版) ---
# 功能:
# 本脚本遵循最简、最直接的更新逻辑：永远寻找并更新到可用的最新版本。
# 1. 它会获取远程仓库中所有的镜像标签，不做任何“稳定版”或“测试版”的区分。
# 2. 通过版本排序，找到版本号最高的那个标签。
# 3. 从最高版本开始，向下寻找第一个与本机架构兼容的标签，并将其锁定为“绝对最新版”。
# 4. 如果“绝对最新版”与当前版本不同，则更新。
# 5. 如果标签相同，则会通过内容指纹(Digest)来判断镜像是否被重新发布过，确保总能更新到最新内容。
#
# 变更 (v5.0):
# - [最终简化] 彻底废除所有稳定版/测试版的逻辑，目标只有一个：绝对的最新版。
# - [通用性] 此逻辑适用于任何标签命名规范。

# --- 安全设置 ---
set -eo pipefail 

# --- 1. 用户配置 ---
COMPOSE_FILE="./docker-compose.yml"

# --- 2. 初始化与环境检查 ---
echo "▶️  开始执行 Docker 镜像智能更新脚本 (v5.0 - 绝对最新版)..."

command -v docker >/dev/null 2>&1 || { echo >&2 "❌ 错误: 'docker' 命令未找到。请先安装 Docker。"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "❌ 错误: 'curl' 命令未找到。请安装 curl。"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "❌ 错误: 'jq' 命令未找到。请安装 jq。"; exit 1; }

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ 错误: Docker Compose 文件未找到: $COMPOSE_FILE"
    exit 1
fi

docker_compose_cmd() {
    if docker compose version &> /dev/null; then
        docker compose "$@"
    elif docker-compose version &> /dev/null; then
        docker-compose "$@"
    else
        echo >&2 "❌ 错误: 'docker compose' 或 'docker-compose' 命令均未找到。"
        exit 1
    fi
}

# --- 3. 核心功能函数 ---

verify_image_architecture() {
    local image_repo=$1
    local tag=$2
    local target_arch=$3
    echo -n "    🔍 验证镜像 ${image_repo}:${tag} 的架构..." >&2

    local inspect_output; inspect_output=$(docker manifest inspect "${image_repo}:${tag}" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo " ⚠️ 警告: 无法 inspect (可能需要登录或镜像不存在)。跳过。" >&2
        return 1
    fi
    
    local supported_archs; supported_archs=$(echo "$inspect_output" | jq -r '.. | .architecture? | select(.)')

    while IFS= read -r arch; do
        if [[ "$arch" == "$target_arch" ]]; then
            echo " ✅ 支持 ($target_arch)" >&2
            return 0
        fi
    done <<< "$supported_archs"

    echo " ❌ 不支持 (需要 $target_arch)" >&2
    return 1
}

get_remote_digest() {
    local full_image=$1
    local image_repo; image_repo=$(echo "$full_image" | cut -d: -f1)
    local image_tag; if [[ "$full_image" != *":"* ]]; then image_tag="latest"; else image_tag=$(echo "$full_image" | cut -d: -f2); fi
    if [[ "$image_repo" != *"/"* ]]; then image_repo="library/$image_repo"; fi

    echo "    🔄 正在从 Docker Hub 获取 '$full_image' 的远程 Digest..." >&2
    local token; token=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image_repo}:pull" | jq -r .token)
    local digest; digest=$(curl -s --head -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer $token" "https://registry-1.docker.io/v2/${image_repo}/manifests/${image_tag}" | grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r')
    echo "$digest"
}

get_local_digest() {
    local full_image=$1
    echo "    ℹ️  正在获取 '$full_image' 的本地 Digest..." >&2
    docker image inspect --format='{{range .RepoDigests}}{{.}}{{end}}' "$full_image" 2>/dev/null | cut -d'@' -f2
}

get_all_tags() {
    local image_repo=$1
    if [[ "$image_repo" != *"/"* ]]; then image_repo="library/$image_repo"; fi

    echo "    🔄 正在从 Docker Hub 获取 '$image_repo' 的所有标签..." >&2
    local token; token=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image_repo}:pull" | jq -r .token)
    # 获取所有标签，并使用 sort -V 进行自然版本排序
    curl -s -H "Authorization: Bearer $token" "https://registry-1.docker.io/v2/${image_repo}/tags/list?n=2000" | jq -r '.tags[]' | sort -V
}


# --- 4. 主执行逻辑 ---
echo "🔎 正在解析 $COMPOSE_FILE..."
IMAGE_LINE=$(grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n 1)
IMAGE_VALUE=$(echo "$IMAGE_LINE" | sed -E "s/^\s*image:\s*['\"]?//;s/['\"]?\s*$//")

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

echo "🔄 正在查找网络上最新的、且架构兼容的版本..."
ALL_TAGS=$(get_all_tags "$IMAGE_REPO")
LATEST_VALID_TAG=""

if [ -z "$ALL_TAGS" ]; then
    echo "🤷 未能找到任何可用的标签进行检查。"
else
    # 从版本号最高的开始，倒序循环，找到第一个架构匹配的即为最新版
    while IFS= read -r tag_to_check; do
        if verify_image_architecture "$IMAGE_REPO" "$tag_to_check" "$ARCH"; then
            LATEST_VALID_TAG=$tag_to_check
            break
        fi
    done <<< "$(echo "$ALL_TAGS" | tac)"
fi

if [ -z "$LATEST_VALID_TAG" ]; then
    echo "🤷 在远程仓库中，未能找到任何与本机 '$ARCH' 架构兼容的版本。"
    echo "✅ 无需任何操作，脚本执行完毕。"
    exit 0
fi

echo "📌 已找到的绝对最新兼容版本为: $LATEST_VALID_TAG"

NEEDS_UPDATE=false
NEW_TAG=""

if [ "$LATEST_VALID_TAG" != "$CURRENT_TAG" ]; then
    echo "⬆️  发现新版本！"
    echo "    - 当前版本: $CURRENT_TAG"
    echo "    - 最新版本: $LATEST_VALID_TAG"
    NEEDS_UPDATE=true
    NEW_TAG=$LATEST_VALID_TAG
else
    echo "🔄 标签与最新版一致 ($CURRENT_TAG)，开始检查内容指纹 (Digest)..."
    REMOTE_DIGEST=$(get_remote_digest "${IMAGE_REPO}:${CURRENT_TAG}")
    LOCAL_DIGEST=$(get_local_digest "${IMAGE_REPO}:${CURRENT_TAG}")

    if [ -z "$REMOTE_DIGEST" ]; then
        echo "🤷 无法获取远程 Digest，跳过更新检查。"
    elif [ -z "$LOCAL_DIGEST" ] || [ "$REMOTE_DIGEST" != "$LOCAL_DIGEST" ]; then
        echo "⬆️  检测到内容更新！远程 Digest 与本地不同。"
        NEEDS_UPDATE=true
        NEW_TAG=$CURRENT_TAG # 标签不变，但需要重新拉取
    else
        echo "✅ 内容指纹一致，确认无需更新。"
    fi
fi

# --- 5. 执行更新 ---
if [ "$NEEDS_UPDATE" = true ]; then
    echo "🚀 开始执行更新流程..."
    
    echo "1/4: 正在更新 $COMPOSE_FILE..."
    sed -i.bak -E "s|image:\s*['\"]?${IMAGE_VALUE}['\"]?|image: \"${IMAGE_REPO}:${NEW_TAG}\"|" "$COMPOSE_FILE"
    echo "    ✅ 文件更新成功, 已创建备份文件 $COMPOSE_FILE.bak"

    echo "2/4: 正在拉取新镜像: ${IMAGE_REPO}:${NEW_TAG}..."
    docker pull "${IMAGE_REPO}:${NEW_TAG}"

    echo "3/4: 正在使用新镜像重启服务..."
    docker_compose_cmd -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans
    echo "    ✅ 服务已成功重启！"

    echo "4/4: 正在清理旧的、无用的 Docker 镜像..."
    docker image prune -af
    echo "    ✅ 清理完成。"
    
    echo "--------------------------------------------------"
    echo "🎉 全部更新操作已成功完成！"
    echo "--------------------------------------------------"
else
    echo "✅ 无需任何操作，脚本执行完毕。"
fi

exit 0
