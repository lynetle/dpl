#!/bin/bash
# --- Docker 镜像智能更新脚本 (V8.0 - 最终稳健版) ---
#
# 核心思想采纳自经过验证的可靠方案，确保在各种环境下的稳定性。
#
# 工作原理:
# 1. 创建一个临时目录来存储分页的 API 响应。
# 2. 循环获取 Docker Hub API 的所有标签页。
# 3. 将每一页的有效数据 (`.results` 数组) 保存为一个独立的 JSON 文件。
# 4. 使用 `jq -s 'add'` 命令将所有临时文件合并，确保可靠处理大量数据。
# 5. 在合并后的完整数据中，进行架构筛选和时间排序，找到最新版本。
# 6. 该方法牺牲了微小的 I/O 性能，换取了在所有情况下的最高级别鲁棒性。

# --- 安全设置 ---
set -eo pipefail

# --- 1. 用户配置 ---
COMPOSE_FILE="./docker-compose.yml"

# --- 2. 初始化与环境检查 ---
echo "▶️  开始执行 Docker 镜像智能更新脚本 (v8.0 - 最终稳健版)..."

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
    local image_repo
    image_repo=$(echo "$full_image" | cut -d: -f1)
    local image_tag
    if [[ "$full_image" != *":"* ]]; then
        image_tag="latest"
    else
        image_tag=$(echo "$full_image" | cut -d: -f2)
    fi
    if [[ "$image_repo" != *"/"* ]]; then image_repo="library/$image_repo"; fi

    echo "    🔄 正在从 Docker Hub 获取 '$full_image' 的远程 Digest..." >&2
    local token
    token=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image_repo}:pull" | jq -r .token)
    local digest
    digest=$(curl -s --head -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Authorization: Bearer $token" "https://registry-1.docker.io/v2/${image_repo}/manifests/${image_tag}" | grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r')
    echo "$digest"
}

get_local_digest() {
    local full_image=$1
    echo "    ℹ️  正在获取 '$full_image' 的本地 Digest..." >&2
    docker image inspect --format='{{range .RepoDigests}}{{.}}{{end}}' "$full_image" 2>/dev/null | cut -d'@' -f2
}

# [V8.0 核心逻辑 - 临时文件法]
get_latest_compatible_tag() {
    local image_repo=$1
    local target_arch=$2
    local repo_name=$image_repo
    if [[ "$repo_name" != *"/"* ]]; then
        repo_name="library/$repo_name"
    fi

    echo "    🔄 正在从 Docker Hub API 获取并处理所有标签..." >&2

    # 创建一个临时目录来安全地处理分页数据
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # 确保在脚本退出时（无论成功或失败）都清理临时目录
    trap 'rm -rf -- "$tmp_dir"' EXIT

    local next_page_url="https://hub.docker.com/v2/repositories/${repo_name}/tags?page_size=100"
    local index=0

    # 循环获取所有分页数据
    while [ -n "$next_page_url" ] && [ "$next_page_url" != "null" ]; do
        echo -n "        - 正 在 获 取: ${next_page_url#*//*/}" >&2
        local page_data
        page_data=$(curl -sL "$next_page_url")
        echo " (ok)" >&2

        # 健壮性检查：如果API响应中没有`.results`字段，则跳过并中止
        if ! echo "$page_data" | jq -e '.results' >/dev/null 2>&1; then
            echo "    ⚠️ 警告: 从 API 获取数据时返回格式无效或为空。可能镜像不存在或 API 异常。" >&2
            break
        fi

        # 将当前页的 .results 数组写入临时文件
        echo "$page_data" | jq '.results' > "$tmp_dir/page_$index.json"
        next_page_url=$(echo "$page_data" | jq -r '.next')
        index=$((index + 1))
    done

    # 检查临时目录中是否有任何文件，避免在无文件时 glob 模式导致错误
    if [ ! -f "$tmp_dir/page_0.json" ]; then
        echo "" # 如果没有下载任何页面，返回空
        return
    fi
    
    # 使用 -s (slurp) 模式将所有临时文件合并成一个大数组，然后进行处理
    jq -s 'add' "$tmp_dir"/page_*.json | jq -r --arg target_arch "$target_arch" '
        # 筛选出所有架构兼容的标签
        map(select(.images[]?.architecture == $target_arch))
        # 按最后更新时间降序排序
        | sort_by(.last_updated) | reverse
        # 获取排序后的第一个结果的名字
        | .[0].name
        # 如果没有结果，返回 null
        | select(. != null)
    '
}

# --- 4. 主执行逻辑 ---
echo "🔎 正在解析 $COMPOSE_FILE..."
IMAGE_LINE=$(grep -E '^\s*image:\s*' "$COMPOSE_FILE" | head -n 1)
IMAGE_VALUE=$(echo "$IMAGE_LINE" | sed -E "s/^\s*image:\s*['\"]?//;s/['\"]?\s*$//")

if [[ "$IMAGE_VALUE" == *"/"* ]] && [[ ! "$IMAGE_VALUE" =~ ^([a-zA-Z0-9.-]+\/){1,}[a-zA-Z0-9.-]+(:[a-zA-Z0-9_.-]+)?$ ]]; then
    if [[ "$IMAGE_VALUE" == *".dkr.ecr."* || "$IMAGE_VALUE" == *"gcr.io"* || "$IMAGE_VALUE" == *"ghcr.io"* ]]; then
        echo "🟡 警告: 检测到非 Docker Hub 镜像 ($IMAGE_VALUE)。跳过检查。"
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
        NEW_TAG=$CURRENT_TAG
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
