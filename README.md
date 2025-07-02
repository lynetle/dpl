
# pull-latest.sh

一个用于自动拉取 Docker Hub 镜像最新版本并更新 `docker-compose.yml` 的 Bash 脚本。  
支持镜像多架构判断、自动替换 tag、服务平滑重启，并可结合 crontab 自动定时更新。

---

## ✨ 功能特性

- ✅ 自动获取镜像的最新 tag（从 Docker Hub）
- ✅ 自动判断是否有更新，避免重复拉取
- ✅ 自动判断镜像是否支持当前平台架构（如 amd64、arm64）
- ✅ 自动更新 `docker-compose.yml` 或 `docker-compose.yaml` 中的镜像 tag
- ✅ 自动执行 `docker compose up -d` 实现无缝重启
- ✅ 可设置为定时任务，每天自动更新

---

## 📦 前置要求

- 已安装 [Docker](https://docs.docker.com/get-docker/) 和 [Docker Compose](https://docs.docker.com/compose/install/)
- 当前目录下存在 `docker-compose.yml` 或 `docker-compose.yaml` 文件，且包含 `image:` 字段
- 网络可访问 Docker Hub（如 `hub.docker.com`）
- Bash 环境（Linux / WSL / macOS）
- 安装 [`jq`](https://stedolan.github.io/jq/) 工具（用于解析 JSON）

安装 jq（以 Ubuntu 为例）：

```bash
sudo apt update
sudo apt install -y jq
```

---

## 🚀 使用方法

项目提供两种使用方式：**一键安装** 和 **手动安装**，任选其一。

---

### ✅ 一键安装（推荐）

适合首次部署或希望快速配置环境的用户。

直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tuosujie/dpl/main/install.sh)
```
中国访问推荐：
```bash
bash <(curl -fsSL https://github.makkle.com/https://raw.githubusercontent.com/tuosujie/dpl/main/install.sh)
```

#### 🛠️ 脚本功能

`install.sh` 将自动：

- 🔧 检查并安装必要依赖（如 jq）
- 🔄 下载或更新 `pull-latest.sh` 脚本
- 📂 初始化项目目录结构
- 🚀 可选：设置定时执行任务

#### ⚠️ 注意事项

- 需要具备 `sudo` 权限
- 适用于常见的 Linux 发行版（如 Ubuntu、Debian 等）
- 安装过程中有交互提示，请根据实际需求操作

---

### 🔧 手动安装

如果你更希望按步骤自主操作，可参考以下流程：

####  下载更新脚本

```bash
curl -fsSL https://raw.githubusercontent.com/tuosujie/dpl/main/pull-latest.sh -o pull-latest.sh
chmod +x pull-latest.sh
```
中国访问推荐：
```bash
bash <(curl -fsSL https://github.makkle.comhttps://raw.githubusercontent.com/tuosujie/dpl/main/pull-latest.sh -o pull-latest.sh
chmod +x pull-latest.sh
```

###  执行脚本

```bash
./pull-latest.sh
```

脚本会自动：

- 🚀 获取镜像最新版本
- 🖥️ 检查是否支持本机架构
- 📝 替换 `docker-compose.yml` 或 `docker-compose.yaml` 中的镜像 tag
- 🔄 重启服务

---

## ⏰ 设置定时自动更新（可选）

你可以将该脚本加入系统的 `crontab`，实现每日自动检查更新。

### 步骤如下：

1. 打开 crontab 编辑器：

```bash
crontab -e
```

2. 添加如下定时任务（每天凌晨 3 点执行）：

```
0 3 * * * /full/path/to/pull-latest.sh >> /full/path/to/docker-update.log 2>&1
```

请将 `/full/path/to/` 替换为你脚本实际所在的路径。

---

## 📁 文件说明

| 文件名                     | 用途                                       |
|----------------------------|--------------------------------------------|
| `pull-latest.sh`           | 主脚本，执行自动检查、更新和重启服务       |
| `.last_tag`                | 记录上一次使用的镜像 tag，避免重复拉取     |
| `.last_checked_arch_tag`  | 缓存架构支持检查结果，提升后续运行速度     |
| `docker-compose.yml.bak`  | 原 compose 文件的备份（执行前生成）        |

---

## 📬 联系 & 反馈

欢迎访问本项目作者的 GitHub：

👉 [tuosujie](https://github.com/tuosujie)

如有建议或问题欢迎提 issue 或 PR！
