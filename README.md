# DPL (Docker Pull Latest) - 智能 Docker 镜像更新器

一个用于自动检查、更新 Docker Hub 镜像并重启关联服务的智能 Bash 脚本。它能自动发现兼容本机构架的最新版本，修改 `docker-compose.yml` 文件，并平滑地重启服务，让你的应用始终保持最新。

项目提供了**一键安装脚本**，可以自动处理环境依赖、网络配置和定时任务，实现真正的“开箱即用”。

---

## ✨ 功能特性

- **一键安装**：提供 `install.sh` 脚本，自动完成依赖安装、脚本下载、镜像加速配置和定时任务设置。
- **智能版本发现**：自动从 Docker Hub API 获取时间上最新的镜像标签。
- **架构兼容性检查**：自动筛选并选择与你服务器架构（如 `amd64`, `arm64`）兼容的镜像版本。
- **内容更新感知**：即使标签名未变（如 `latest`），也能通过检查镜像的 Digest (内容指纹) 来发现并执行更新。
- **代理支持**：内置代理模式（自动/强制），可配置通过反向代理访问 Docker Hub API，完美解决国内访问慢或被速率限制的问题。
- **网络优化**：安装时可自动检测网络，并提示配置国内 Docker 镜像加速。
- **无缝重启服务**：更新 `docker-compose.yml` 文件后，自动执行 `docker compose up -d` 以应用更新。
- **高鲁棒性**：优化了 API 请求逻辑，修复了多个边界情况下的 bug，运行更稳定。
- **定时自动更新**：可轻松设置为 `cron` 定时任务，实现无人值守的自动更新。
- **自动备份**：在修改前会自动备份 `docker-compose.yml` 文件。

## 🔧 工作原理

1.  **解析配置**：读取 `docker-compose.yml` 文件中的 `image` 字段。
2.  **获取本机信息**：确定当前服务器的 CPU 架构（如 `amd64`）。
3.  **查询远程 API**：
    - 访问 Docker Hub API，通过分页获取指定镜像的所有标签。
    - （如果开启代理）所有 API 请求将通过你配置的代理服务器进行。
4.  **筛选最新版本**：在所有标签中，筛选出与本机架构兼容、且发布时间最新的一个有效标签。
5.  **对比版本**：
    - 如果找到的最新标签与当前标签**不同**，则标记为需要更新。
    - 如果标签**相同**，则进一步通过 API 获取远程镜像的 `Digest`，并与本地镜像的 `Digest` 对比。如果 `Digest` 不同，说明镜像内容已更新，同样标记为需要更新。
6.  **执行更新**：
    - 修改 `docker-compose.yml` 文件中的镜像版本。
    - 拉取新的 Docker 镜像。
    - 使用新镜像强制重新创建并启动服务。
    - 清理旧的、无用的镜像以释放空间。

## 📦 前置要求

- 操作系统：Linux (Ubuntu, Debian, CentOS 等), macOS, 或 WSL。
- 已安装 [Docker](https://docs.docker.com/get-docker/) 和 [Docker Compose](https://docs.docker.com/compose/install/) (v1 或 v2 均可)。
- 已安装 `jq` 和 `curl` 工具（**一键安装脚本会自动安装 `jq`**）。
- 当前目录下存在 `docker-compose.yml` 或 `docker-compose.yaml` 文件。
- **重要**：本脚本目前仅支持更新托管在 **Docker Hub** 上的公开镜像。

---

## 🚀 使用方法

### ✅ 一键安装（强烈推荐）

该方式最简单，推荐所有用户使用。它会自动处理所有环境配置。

**标准网络环境：**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lynetle/dpl/main/install.sh)
```

**中国大陆或网络不佳环境推荐：**
```bash
bash <(curl -fsSL https://github.makkle.com/https://raw.githubusercontent.com/lynetle/dpl/main/install.sh)
```

**这个安装脚本会做什么？**

1.  **检查环境**：确认 `docker-compose.yml` 文件是否存在。
2.  **安装依赖**：自动使用 `apt-get` 安装 `jq`。
3.  **检查镜像**：验证 `docker-compose.yml` 中的镜像是否来自 Docker Hub。
4.  **配置加速**：检测 Docker Hub 连接速度，如果过慢，会**交互式地询问**是否要为你配置国内镜像加速。
5.  **下载主脚本**：从 GitHub 下载最新的 `pull-latest.sh` 并赋予执行权限。
6.  **设置定时任务**：**交互式地询问**是否要添加一个 `cron` 任务，以实现每天凌晨3点的自动更新。

### 🔧 手动安装

适合希望完全控制安装过程的高级用户。

1.  **下载更新脚本**

    **标准网络环境：**
    ```bash
    curl -fsSL https://raw.githubusercontent.com/lynetle/dpl/main/pull-latest.sh -o pull-latest.sh
    chmod +x pull-latest.sh
    ```
    **中国大陆或网络不佳环境推荐：**
    ```bash
    curl -fsSL https://github.makkle.com/https://raw.githubusercontent.com/lynetle/dpl/main/pull-latest.sh -o pull-latest.sh
    chmod +x pull-latest.sh
    ```
2.  **安装依赖**

    ```bash
    # 以 Debian/Ubuntu 为例
    sudo apt-get update && sudo apt-get install -y jq
    ```

3.  **执行脚本**

    直接运行即可开始检查和更新：
    ```bash
    ./pull-latest.sh
    ```

---

## ⚙️ 脚本配置

你可以直接编辑 `pull-latest.sh` 文件顶部的配置项来定制其行为。

```bash
# --- 1. 用户配置 ---
COMPOSE_FILE="./docker-compose.yml"
PROXY_MODE="auto"
PROXY_DOMAIN="dock.makkle.com"
```

| 配置项 | 说明 |
| :--- | :--- |
| `COMPOSE_FILE` | 指定你的 docker-compose 文件路径。 |
| `PROXY_MODE` | 代理模式。可选值：<br>- `auto`: 自动检测网络，如果直连 Docker Hub API 失败，则自动启用代理。<br>- `force_on`: 强制所有 API 请求通过代理。<br>- `force_off`: 强制所有 API 请求都直连，不使用代理。 |
| `PROXY_DOMAIN` | 你的反向代理服务器域名。仅在 `PROXY_MODE` 为 `auto` 或 `force_on` 时生效。 |

## 🛰️ 高级功能：配置反向代理

为了彻底解决 Docker Hub 的速率限制和国内访问速度慢的问题，你可以自行搭建一个 Nginx 反向代理。本项目提供了一份经过优化的、带缓存的 Nginx 配置方案。

**详细的部署指南请参考文档：[`nginx.md`](nginx.md)**

配置好你自己的代理服务器后，只需在 `pull-latest.sh` 中修改 `PROXY_MODE` 和 `PROXY_DOMAIN` 即可启用。

## ⏰ 设置定时自动更新

你可以将该脚本加入系统的 `crontab`，实现每日自动检查更新。**（注意：一键安装脚本可自动完成此步骤）**

1.  打开 crontab 编辑器：
    ```bash
    crontab -e
    ```
2.  在文件末尾添加一行（示例为每天凌晨3点执行，并将日志输出到 `docker-update.log`）：
    ```
    0 3 * * * /path/to/your/pull-latest.sh >> /path/to/your/docker-update.log 2>&1
    ```
    **请务必将 `/path/to/your/` 替换为脚本所在的绝对路径。**

## 📁 文件说明

| 文件名 | 用途 |
| :--- | :--- |
| `pull-latest.sh` | **主脚本**，负责执行所有检查、更新和重启逻辑。 |
| `install.sh` | **一键安装脚本**，用于快速部署和配置环境。 |
| `nginx.md` | Nginx 反向代理的详细**部署指南**。 |
| `docker-compose.yml.bak` | 在更新前自动创建的 compose 文件**备份**。 |
| `docker-update.log` | （可选）定时任务的**日志输出文件**。 |

---

## 📬 联系 & 反馈

- **作者**: [lynetle](https://github.com/lynetle)
- 欢迎通过 [GitHub Issues](https://github.com/lynetle/dpl/issues) 提出问题或建议！

