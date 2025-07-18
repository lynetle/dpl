#!/bin/bash
# --- Docker 镜像智能更新脚本 (v7.0 - 时序优先版) ---
#
# 功能:
# 本脚本结合了 v5 的完整更新流程和 v7 的高效 API 查询逻辑。
# 1. 它会通过 Docker Hub Web API 一次性获取所有标签及其元数据（更新时间、支持的架构等）。
# 2. 它会先过滤出所有与本机架构兼容的标签。
# 3. 然后，它将这些兼容的标签按“最后更新时间”进行降序排序。
# 4. 列表顶部的第一个标签，即为“时间上最新且架构兼容”的版本，并锁定为更新目标。
# 5. 如果最新版本与当前版本不同，则更新。
# 6. 如果标签相同，则通过内容指纹(Digest)来判断镜像是否被重新发布过，确保内容也是最新的。
#
# 变更 (v7.0):
# - [核心升级] 替换为 V7 的查询逻辑，使用 Docker Hub Web API (`/v2/repositories/.../tags`)。
# - [排序方式] 从版本号排序 (`sort -V`) 升级为按时间戳 (`last_updated`) 排序，更精准。
# - [性能提升] 原生支持架构过滤，无需对每个标签单独执行 `docker manifest inspect`，速度大幅提升。
# - [功能完善] 增加了完整的 API 分页处理，确保能查询一个镜像的所有标签。
# - [代码重构] 移除了 `get_all_tags` 和 `verify_image_architecture` 函数，整合为单一、高效的查找函数。

# --- 安全设置 ---
set -eo pipefail

# --- 1. 用户配置 ---
COMPOSE_FILE="./docker-compose.yml"

# --- 2. 初始化与环境检查 ---
echo "▶️  开始执行 Docker 镜像智能更新脚本 (v7.0 - 时序优先版)..."

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

# [V7 核心逻辑]
get_latest_compatible_tag() {
    local image_repo=$1
    local target_arch=$2
    local repo_name=$image_repo
    if [[ "$repo_name" != *"/"* ]]; then
        repo_name="library/$repo_name"
    fi

    echo "    🔄 正在从 Docker Hub API 获取并处理所有标签..." >&2

    local next_page_url="https://hub.docker.com/v2/repositories/${repo_name}/tags?page_size=100"
    local all_results="[]"

    # 处理分页，获取所有标签数据
    while [ -n "$next_page_url" ] && [ "$next_page_url" != "null" ]; do
        echo -n "        - 正 在 获 取: ${next_page_url#*//*/}" >&2
        local page_data; page_data=$(curl -sL "$next_page_url")
        echo " (ok)" >&2

        # 检查是否获取到有效数据
        if ! echo "$page_data" | jq -e '.results' >/dev/null 2>&1; then
            echo "    ⚠️ 警告: 从 API 获取数据时返回格式无效或为空。可能镜像不存在或 API 变更。" >&2
            break
        fi

        all_results=$(echo "$all_results" | jq --argjson page_results "$(echo "$page_data" | jq '.results')" '. + $page_results')
        next_page_url=$(echo "$page_data" | jq -r '.next')
    done

    # 从所有结果中，筛选、排序并获取最终的标签名
    echo "$all_results" | jq -r --arg target_arch "$target_arch" '
        # 1. 筛选出所有架构兼容的标签
        map(select(.images[]?.architecture == $target_arch))
        # 2. 按最后更新时间降序排序
        | sort_by(.last_updated) | reverse
        # 3. 获取排序后的第一个结果的名字
        | .[0].name
        # 4. 如果没有结果，返回 null
        | select(. != null)
    '
}


# --- 4. 主执行逻辑 ---
echo "🔎 正在解析 $COMPOSE_FILE..."
IMAGE_LINE=$(grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n 1)
IMAGE_VALUE=$(echo "$IMAGE_LINE" | sed -E "s/^\s*image:\s*['\"]?//;s/['\"]?\s*$//")

# 限制只处理 Docker Hub 的镜像
if [[ "$IMAGE_VALUE" == *"/"* ]] && [[ ! "$IMAGE_VALUE" =~ ^([a-zA-Z0-9.-]+\/){1,}[a-zA-Z0-9.-]+(:[a-zA-Z0-9_.-]+)?$ ]]; then
    if [[ "$IMAGE_VALUE" == *".dkr.ecr."* || "$IMAGE_VALUE" == *"gcr.io"* || "$IMAGE_VALUE" == *"ghcr.io"* ]]; then
        echo "🟡 警告: 检测到非 Docker Hub 镜像 ($IMAGE_VALUE)。此脚本的 API 查询逻辑专为 Docker Hub 设计，将跳过检查。"
        echo "✅ 无需任何操作，脚本执行完毕。"
        exit 0
    fi
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
    echo "🤷 在远程仓库中，未能找到任何与本机 '$ARCH' 架构兼容的版本。"
    echo "✅ 无需任何操作，脚本执行完毕。"
    exit 0
fi

echo "📌 已找到时间上最新且兼容的版本为: $LATEST_VALID_TAG"

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
        echo "    - 本地 Digest: $LOCAL_DIGEST"
        echo "    - 远程 Digest: $REMOTE_DIGEST"
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
    # 使用双引号以支持包含特殊字符的镜像名，并确保替换的精确性
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
