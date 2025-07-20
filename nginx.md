# Nginx Docker Hub Mirror - 高性能缓存代理

这是一个使用 Nginx 搭建的高性能、带缓存的 Docker Hub 代理/镜像解决方案。主要用于解决 Docker Hub 的 API 速率限制（Rate Limiting）问题，并加速在中国大陆或其他网络不佳地区与 Docker Hub 的交互速度。

## ✨ 特性

- **API 缓存**: 智能缓存镜像元数据请求（如标签列表），大幅减少对 Docker Hub API 的直接请求，有效避免速率限制。
- **高性能**: 利用 Nginx 的 `proxy_cache` 模块，对于已缓存的请求实现毫秒级响应。
- **支持 IPv4 & IPv6**: 全面支持双栈网络环境。
- **安全**: 默认配置强制使用 HTTPS。
- **透明代理**: 同时代理以下三个关键 Docker Hub 端点：
    - `hub.docker.com` (元数据和标签，带缓存)
    - `auth.docker.io` (认证，不缓存)
    - `registry-1.docker.io` (镜像层下载，不缓存)
- **重要**:只是为了配合pull-latest.sh脚本查询镜像使用，不能当加速镜像使用

## 🚀 部署指南

### 先决条件

1.  一台拥有公网 IP 的服务器（VPS 或物理机）。
2.  一个域名，并将其解析到你的服务器 IP。
3.  服务器上已安装 Nginx。
4.  拥有该域名的 SSL 证书（推荐使用 Let's Encrypt 免费获取）。

### 步骤 1: 配置 Nginx 主文件

打开 Nginx 的主配置文件（通常是 `/etc/nginx/nginx.conf`），在 `http` 块内添加 `proxy_cache_path` 指令来定义缓存区域。

```nginx
# /etc/nginx/nginx.conf

http {
    # ... 其他 http 配置 ...

    ##
    # Docker 代理缓存配置
    # 定义一个名为 'docker_hub_cache' 的缓存区域
    # 路径: /var/cache/nginx/docker_hub - Nginx需要对此目录有读写权限
    # keys_zone: 共享内存区域，10MB 大约可存储 80,000 个 key
    # inactive: 缓存文件在 6 小时内未被访问则删除
    # max_size: 缓存目录的最大尺寸，这里设置为 10GB
    ##
    proxy_cache_path /var/cache/nginx/docker_hub levels=1:2 keys_zone=docker_hub_cache:10m inactive=6h max_size=10g;

    # ... 其他 http 配置 ...
}
```

### 步骤 2: 创建缓存目录

执行以下命令创建缓存目录并设置正确的权限（`www-data` 是 Debian/Ubuntu 的默认 Nginx 用户，请根据你的系统进行调整）。

```bash
sudo mkdir -p /var/cache/nginx/docker_hub
sudo chown www-data:www-data /var/cache/nginx/docker_hub
```

### 步骤 3: 添加站点配置

在 Nginx 的站点配置目录（如 `/etc/nginx/conf.d/`）中，创建一个新的配置文件，例如 `docker-proxy.conf`，然后将下面的内容粘贴进去。

**重要**: 请务必将 `your-proxy-domain.com` 和 SSL 证书路径替换为你自己的信息。

**文件**: `docker-proxy.conf`
```nginx
# /etc/nginx/conf.d/docker-proxy.conf (v1.3 - Cache Optimized)

# 定义一个 map 来判断是否绕过缓存 (方便调试)
map $http_x_cache_bypass $cache_bypass {
    default 0;
    1 1;
}

# HTTP 到 HTTPS 的永久重定向
server {
    listen 80;
    listen [::]:80;
    server_name your-proxy-domain.com; # <<< 修改为你的域名
    return 301 https://$host$request_uri;
}

# 主代理服务器
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name your-proxy-domain.com; # <<< 修改为你的域名

    # --- SSL 证书配置 ---
    ssl_certificate /path/to/your/ssl/fullchain.pem; # <<< 修改为你的证书路径
    ssl_certificate_key /path/to/your/ssl/privkey.pem; # <<< 修改为你的私钥路径

    # --- 安全与性能优化 ---
    ssl_protocols TLSv1.2 TLSv1.3;
    
    # --- DNS 解析器 ---
    # 使用公共 DNS 解析上游服务地址，增强稳定性
    resolver 8.8.8.8 1.1.1.1 valid=300s;
    resolver_timeout 5s;

    # --- 缓存状态响应头 ---
    # 在响应头中添加 X-Proxy-Cache 字段，显示缓存状态 (HIT, MISS, BYPASS 等)
    add_header X-Proxy-Cache $upstream_cache_status;

    # --- 通用代理头设置 ---
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    # --- 代理规则 ---

    # 规则 1: 代理 hub.docker.com (带缓存)
    # 处理镜像元数据和标签列表
    location ~ ^/hub/(.*)$ {
        # --- 缓存配置 ---
        proxy_cache docker_hub_cache;
        proxy_cache_key "$scheme$proxy_host$request_uri";
        proxy_cache_valid 200 302 1h;      # 对 200/302 响应缓存 1 小时
        proxy_cache_valid 404 1m;          # 对 404 响应缓存 1 分钟
        proxy_cache_valid any 5m;          # 对其他任何响应缓存 5 分钟
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504; # 上游错误时使用旧缓存
        proxy_cache_lock on;               # 防止缓存穿透 (Cache Stampede)

        # 允许通过 HTTP 头绕过缓存
        proxy_cache_bypass $cache_bypass;
        proxy_no_cache $cache_bypass;

        proxy_pass https://hub.docker.com/$1$is_args$args;
        proxy_set_header Host "hub.docker.com";
    }

    # 规则 2: 代理 auth.docker.io (不缓存)
    # 处理认证和 Token 获取
    location ~ ^/auth/(.*)$ {
        proxy_pass https://auth.docker.io/$1$is_args$args;
        proxy_set_header Host "auth.docker.io";
    }

    # 规则 3: 代理 registry-1.docker.io (不缓存)
    # 处理镜像层 (blob) 下载
    location ~ ^/registry/(.*)$ {
        proxy_pass https://registry-1.docker.io/$1$is_args$args;
        proxy_set_header Host "registry-1.docker.io";
        # 将客户端的认证头传递给上游
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header Authorization;
    }

    # 根路径测试响应
    location = / {
        add_header Content-Type text/plain;
        return 200 'Docker API Proxy is running (v1.3 - Cache Optimized).';
    }
}
```

### 步骤 4: 测试并重载 Nginx

```bash
# 测试配置文件语法是否正确
sudo nginx -t

# 如果测试通过，则平滑重载 Nginx
sudo systemctl reload nginx
```
部署完成后，你的 Nginx 代理服务器就已经准备就绪了。

## 🧪 验证缓存

你可以使用 `curl` 命令来直接测试 Nginx 代理服务器的缓存功能是否生效。这可以独立于任何 Docker 客户端进行验证。

```bash
# 第一次请求
# 将 your-proxy-domain.com 替换为你的域名
curl -I "https://your-proxy-domain.com/hub/v2/repositories/library/ubuntu/tags"
```
查看响应头，其中应包含 `x-proxy-cache: MISS`，表示这次请求穿透了缓存，到达了上游服务器。

```
HTTP/2 200
...
x-proxy-cache: MISS
...
```

```bash
# 立即再次请求
curl -I "https://your-proxy-domain.com/hub/v2/repositories/library/ubuntu/tags"
```
再次查看响应头，其中应包含 `x-proxy-cache: HIT`，表示这次请求已由 Nginx 缓存直接响应，没有再次访问上游服务器。

```
HTTP/2 200
...
x-proxy-cache: HIT
...
```

出现 `HIT` 状态即表明您的 Nginx 缓存代理已成功配置并正常工作。

## 📄 许可证

本项目采用 [MIT License](LICENSE)。
