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
