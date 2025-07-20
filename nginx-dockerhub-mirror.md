# 🚀 如何用 Nginx 搭建飞一般的 Docker Hub 反向代理

还在为 `docker pull` 慢如蜗牛而抓狂吗？或者因为网络问题，关键时刻镜像拉不下来而耽误事？

别担心！通过在**境外服务器**上用 Nginx 搭建一个 Docker Hub 反向代理，就能彻底解决这个问题，让你享受丝般顺滑的镜像拉取体验。本教程将手把手带你配置一个功能完备的代理，完美支持 `docker pull` 和 `docker login`。

---

## 🎯 准备工作

动手之前，你需要准备好以下几样“装备”：

1.  **一台拥有境外公网 IP 的服务器**：这是关键，确保服务器能流畅访问 Docker Hub。
2.  **一个域名**：并将其 DNS 解析到你的服务器 IP。教程中将使用 `your-proxy-domain.com` 作为示例。
3.  **Nginx 已安装并运行**：这是我们的主角。
4.  **SSL 证书**：Docker 客户端要求必须使用 HTTPS。你可以通过 [Let's Encrypt](https://letsencrypt.org/) 免费获取。

---

## 第一步：配置 Nginx

1.  进入 Nginx 配置目录 (通常是 `/etc/nginx/conf.d/`)，创建一个新配置文件，例如 `docker-proxy.conf`。
2.  将下面的配置代码完整复制进去。

> ⚠️ **重要提示：** 配置文件中有 **两处** 需要将 `your-proxy-domain.com` 替换为你的域名，千万别漏了！

### Nginx 配置文件 (`docker-proxy.conf`)

```nginx
server {
    # 监听 443 端口，启用 SSL 和 HTTP/2
    listen 443 ssl http2;
    server_name your-proxy-domain.com; # <-- (1) 在这里替换为你的域名

    # --- SSL 证书配置 ---
    ssl_certificate /path/to/your/fullchain.pem; # <-- 替换为你的证书路径
    ssl_certificate_key /path/to/your/privkey.pem; # <-- 替换为你的私钥路径

    # --- SSL 性能优化 ---
    ssl_session_timeout 24h;
    ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # 设置较大的临时文件大小，防止拉取大镜像时出错
    proxy_max_temp_file_size 1024m;

    # 核心 location, 代理所有镜像相关请求
    location / {
        proxy_pass https://registry-1.docker.io;
        
        # --- 基础代理头设置 ---
        proxy_set_header Host registry-1.docker.io;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # --- 认证和缓存设置 ---
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header  Authorization;
        proxy_buffering off; # 关闭缓存，直接转发，减少延迟
        
        # --- 关键：重写认证请求的地址 ---
        # 当 Docker Hub 返回 401 时，它会告诉客户端去哪里获取 token
        # 我们必须把这个地址重写为我们自己的代理地址
        proxy_hide_header www-authenticate;
        add_header www-authenticate 'Bearer realm="https://your-proxy-domain.com/token",service="registry.docker.io"' always; # <-- (2) 在这里替换为你的域名
        
        # --- 捕获并处理重定向 ---
        # 镜像层(layer)的下载地址通常是重定向到云存储的，需要捕获并继续代理
        proxy_intercept_errors on;
        recursive_error_pages on;
        error_page 301 302 307 = @handle_redirect;
    }

    # 处理 Docker Token 认证请求
    location /token {
        resolver 8.8.8.8 1.1.1.1 valid=600s; # 使用公共 DNS，稳定
        resolver_timeout 5s;
        proxy_pass https://auth.docker.io;
        
        # --- 转发必要的头信息 ---
        proxy_set_header Host auth.docker.io;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header Authorization;
        proxy_buffering off;
    }

    # 处理重定向请求
    location @handle_redirect {
        resolver 8.8.8.8 1.1.1.1 valid=300s;
        set $saved_redirect_location '$upstream_http_location';
        proxy_pass $saved_redirect_location; # 代理到上游返回的重定向地址

        # --- 转发必要的头信息 ---
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Authorization ""; # 下载层文件时，云存储通常不需要 Authorization
        proxy_buffering off;
    }
}
```
### 重启 Nginx

保存好配置文件后，先检查一下语法有没有问题，然后平滑地重启 Nginx 让配置生效。

```bash
# 检查配置语法
sudo nginx -t

# 如果显示 "syntax is ok" 和 "test is successful"，则重启
sudo systemctl reload nginx
```
## 第二步：使用你的 Docker 代理

大功告成！现在，你有两种“姿势”来享用你的专属加速器。

### 方法一：全局配置 (👍 推荐)

**优点：** 一劳永逸，所有 `docker pull` 命令自动走代理，无需额外操作。

1.  **修改 Docker 配置文件**
    编辑或创建 `/etc/docker/daemon.json` 文件。
    ```bash
    sudo nano /etc/docker/daemon.json
2.  **添加镜像加速器地址**
    写入以下内容，如果文件已存在内容，请确保是合法的 JSON 格式。
    ```json
    {
      "registry-mirrors": ["https://your-proxy-domain.com"]
    }
3.  **重启 Docker 服务**
    ```bash
    sudo systemctl restart docker
    ```
    > 别忘了把 your-proxy-domain.com 换成你的域名！
4.  验证配置 ✅
运行 docker info，看到你的域名出现在 Registry Mirrors 列表中就说明成功了！
    ```bash
    docker info | grep "Registry Mirrors"
    # 输出应类似于:
    #  Registry Mirrors:
    #   https://your-proxy-domain.com/
5.  开始使用
像往常一样拉取镜像，体验飞一般的感觉吧！
    ```bash
    docker pull ubuntu:22.04
    docker pull redis
### 方法二：手动指定镜像地址

**优点：** 灵活，适合临时使用或不想修改全局配置的场景。

**语法:** `docker pull <你的域名>/<仓库名>/<镜像名>:<标签>`

> 💡 **核心注意点：** 拉取 Docker **官方镜像** (如 `ubuntu`, `nginx` 等) 时，必须在镜像名前加上 `library/` 前缀，这绝对不能省略！对于非官方镜像（如 `bitnami/mongodb`），则直接使用其完整名称。

#### 示例：

1.  **拉取官方镜像 `ubuntu`**:
    ```bash
    # 正确方式 (必须包含 library)
    docker pull your-proxy-domain.com/library/ubuntu:22.04
2.  **拉取官方镜像 `nginx`**:
    ```bash
    docker pull your-proxy-domain.com/library/nginx:latest
3.  **拉取组织镜像 `bitnami/mongodb`**:
    ```bash
    docker pull your-proxy-domain.com/bitnami/mongodb:latest
🎉 **恭喜！** 你现在拥有了一个属于自己的、速度飞快的 Docker 镜像加速器。从此告别龟速 `pull`，享受开发的乐趣吧！




