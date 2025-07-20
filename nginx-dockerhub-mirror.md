# 如何使用 Nginx 反向代理 Docker Hub 镜像源

在国内或网络不佳的环境下，直接从 Docker Hub 拉取镜像可能会非常缓慢甚至失败。通过在自己的服务器上搭建一个反向代理，可以有效加速 Docker 镜像的拉取。

本教程将指导你如何使用 Nginx 配置一个功能完善的 Docker Hub 反向代理，该配置支持认证和重定向，确保 `docker pull` 和 `docker login` 等命令都能正常工作。

## 准备工作

在开始之前，请确保你已准备好：

1.  **一台拥有公网 IP 的服务器**：用于运行 Nginx 反向代理。
2.  **一个域名**：并将其解析到你的服务器 IP。本教程中将使用 `your-proxy-domain.com` 作为占位符。
3.  **安装好 Nginx**：确保 Nginx 已经成功安装并运行。
4.  **SSL 证书**：为了让 Docker 客户端信任你的代理，必须启用 HTTPS。你可以通过 Let's Encrypt 等服务免费获取。

## 第一步：配置 Nginx

1.  在 Nginx 的配置目录（通常是 `/etc/nginx/conf.d/` 或 `/etc/nginx/sites-available/`）下创建一个新的配置文件，例如 `docker-proxy.conf`。
2.  将以下**已脱敏**的配置内容复制到该文件中。

### Nginx 配置文件 (`docker-proxy.conf`)

```nginx
server {
    # 监听 443 端口，启用 SSL
    listen 443 ssl http2;
    server_name your-proxy-domain.com; # <-- 请替换为你的域名

    # SSL 证书配置
    ssl_certificate /path/to/your/fullchain.pem; # <-- 请替换为你的证书路径
    ssl_certificate_key /path/to/your/privkey.pem; # <-- 请替换为你的私钥路径

    # SSL 性能优化
    ssl_session_timeout 24h;
    ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # 设置较大的 proxy_max_temp_file_size 以避免 "upstream sent too big header" 错误
    proxy_max_temp_file_size 1024m;

    # 根路径，代理 Docker 镜像数据拉取请求
    location / {
        # 代理到 Docker Hub 的官方镜像仓库
        proxy_pass https://registry-1.docker.io;
        
        # 设置请求头
        proxy_set_header Host registry-1.docker.io;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 转发认证相关的头部
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header  Authorization;
        
        # 关闭缓存，对于二进制流数据，关闭缓存可以减少磁盘 I/O
        proxy_buffering off;
        
        # 关键步骤：重写 www-authenticate 头，将其中的认证地址指向我们的反代服务器
        # Docker 客户端在收到 401 Unauthorized 响应时，会解析这个头部来找到获取 token 的地址
        proxy_hide_header www-authenticate;
        add_header www-authenticate 'Bearer realm="https://your-proxy-domain.com/token",service="registry.docker.io"' always; # <-- 替换域名
        
        # 捕获上游（Docker Hub）的错误，特别是重定向
        proxy_intercept_errors on;
        recursive_error_pages on; # 允许递归处理错误页面
        # 当上游返回 301/302/307 重定向时，交由 @handle_redirect location 处理
        error_page 301 302 307 = @handle_redirect;
    }

    # 处理 Docker OAuth2 Token 认证请求
    location /token {
        # 使用公共 DNS 解析器，避免本地 DNS 污染问题
        resolver 8.8.8.8 1.1.1.1 valid=600s;
        resolver_timeout 5s;

        # 代理到 Docker 的官方认证服务器
        proxy_pass https://auth.docker.io;
        
        # 设置请求头
        proxy_set_header Host auth.docker.io;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 传递认证信息
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header Authorization;

        # 关闭缓存
        proxy_buffering off;
    }

    # 处理上游返回的重定向
    location @handle_redirect {
        # Docker Hub 在下载镜像层(layer)时，会返回一个指向云存储的临时 URL
        # 我们需要捕获这个 URL 并继续代理请求
        resolver 8.8.8.8 1.1.1.1 valid=300s;
        set $saved_redirect_location '$upstream_http_location';
        proxy_pass $saved_redirect_location;

        # 同样需要设置这些头部
        proxy_set_header Host $host; # 注意这里使用 $host 而不是硬编码的地址
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Authorization ""; # 清空认证头，因为请求的是云存储的临时 URL，不需要认证
        proxy_buffering off;
    }
}
```

### 配置说明

-   **`your-proxy-domain.com`**: 必须替换为你自己的域名。
-   **`/path/to/your/fullchain.pem`**: 必须替换为你的 SSL 证书文件（通常是 `fullchain.pem`）的绝对路径。
-   **`/path/to/your/privkey.pem`**: 必须替换为你的 SSL 证书私钥文件（通常是 `privkey.pem`）的绝对路径。

### 3. 重启 Nginx

保存配置文件后，检查 Nginx 配置语法是否正确，然后重新加载或重启 Nginx 服务。

```bash
# 检查配置语法
sudo nginx -t

# 如果语法正确，则重新加载配置
sudo systemctl reload nginx
```

## 第二步：使用你的 Docker 代理

配置完成后，你有两种方式来使用这个代理。

### 方法一：全局配置（推荐）

这种方法会将你的代理设置为 Docker 的默认镜像加速器。所有 `docker pull` 命令都会自动通过你的代理。

1.  **修改 Docker 配置文件**

    编辑或创建 Docker 的配置文件 `/etc/docker/daemon.json`。

    ```bash
    sudo nano /etc/docker/daemon.json
    ```

2.  **添加 `registry-mirrors`**

    如果文件是空的，直接添加以下内容。如果文件已有内容，请确保将 `registry-mirrors` 添加到 JSON 对象中。

    ```json
    {
      "registry-mirrors": ["https://your-proxy-domain.com"]
    }
    ```
    > **注意**：请将 `your-proxy-domain.com` 替换为你的域名。

3.  **重启 Docker 服务**

    保存文件后，必须重启 Docker 服务才能使配置生效。

    ```bash
    sudo systemctl restart docker
    ```

4.  **验证配置**

    运行 `docker info` 命令，在输出中查找 `Registry Mirrors` 部分，如果能看到你的域名，则表示配置成功。

    ```bash
    docker info | grep "Registry Mirrors"
    # 输出应类似于:
    #  Registry Mirrors:
    #   https://your-proxy-domain.com/
    ```

5.  **使用**

    现在你可以像平常一样拉取镜像了，Docker 会自动通过你的代理。

    ```bash
    docker pull ubuntu:22.04
    docker pull redis
    ```

### 方法二：手动指定镜像地址

如果你不想修改全局配置，或者只是想临时使用代理，可以在拉取镜像时手动指定完整的镜像路径。

**语法**: `docker pull <你的域名>/<仓库名>/<镜像名>:<标签>`

**关键点**:

-   对于 Docker 官方镜像（如 `ubuntu`, `nginx`, `redis` 等），它们的默认仓库名是 `library`。**在使用代理时，`library` 这个前缀不能省略！**
-   对于其他用户或组织的镜像（如 `bitnami/mongodb`），仓库名就是用户名或组织名（`bitnami`）。

#### 示例：

1.  **拉取官方镜像 `ubuntu`**:

    ```bash
    # 错误的方式，这样会失败
    # docker pull your-proxy-domain.com/ubuntu:22.04

    # 正确的方式，必须包含 "library"
    docker pull your-proxy-domain.com/library/ubuntu:22.04
    ```

2.  **拉取官方镜像 `nginx`**:

    ```bash
    docker pull your-proxy-domain.com/library/nginx:latest
    ```

3.  **拉取组织镜像 `bitnami/mongodb`**:

    ```bash
    docker pull your-proxy-domain.com/bitnami/mongodb:latest
    ```

通过以上步骤，你就成功搭建并可以使用一个私有的 Docker Hub 反向代理了。这不仅能提升镜像拉取速度，还能在一定程度上绕开 Docker Hub 的速率限制。
