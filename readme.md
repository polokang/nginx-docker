# Nginx 反向代理服务 (Nginx Reverse Proxy)

本项目是一个基于 Docker 的 Nginx 反向代理服务。主要用于将不同的外网域名请求，路由到宿主机（Server）上的不同端口服务。

## 🌟 主要功能

*   **容器化部署**: 使用 Docker 和 Docker Compose 进行便捷的启动和管理。
*   **宿主机服务转发**: 配置中借助了 `host.docker.internal` 机制，能够顺利地将请求转发到宿主机的本地进程（Localhost）。
*   **HTTPS 终结**: 通过 Let's Encrypt 免费证书 + bind-mount 卷，把 TLS 终结放在反代层；启用流程见 [DEPLOY.md](./DEPLOY.md)。
*   **日志持久化**: 容器内部的 Nginx `access.log` 和 `error.log` 将被挂载到项目根目录下的 `./logs` 文件夹中以便于排查问题。
*   **自动健康检查**: 在 docker-compose 中配置了通过 curl 轮询进行健康检查 (Healthcheck)，并通过 `restart: always` 策略保证服务高可用。

## 🔀 路由映射规则

我们在 `nginx.conf` 中配置了如下两条最主要的子域名规则，同时支持 WebSocket 协议 (Upgrade)：

| 域名 (Server Name) | 协议 | 目标地址 (Proxy Pass) | 备注 |
| :--- | :--- | :--- | :--- |
| `pro.aquareporter.com.au` | HTTPS（HTTP 301 跳转） | `http://host.docker.internal:8888` | Aquareporter Web；Passkey/WebAuthn 需要 secure context |
| `aquadev.aquareporter.com.au` | HTTP | `http://host.docker.internal:8000` | adminpage 内网访问，不做 TLS 终结 |

## 🚀 快速启动

1.  **准备环境**: 确保服务器已安装 Docker 和 Docker Compose。
2.  **启动服务**: 在项目根目录下执行以下命令：
    ```bash
    docker-compose up -d
    ```
3.  **查看运行状态**:
    ```bash
    docker-compose ps
    ```
4.  **查看实时日志** (如果排查代理问题可以看这个):
    ```bash
    docker-compose logs -f
    ```

## 📁 目录结构说明

*   `docker-compose.yml`: 编排文件，定义了 nginx 服务、certbot 工具容器、bind mount 卷、健康检查。
*   `nginx.conf`: **阶段 1**（HTTP-only + ACME challenge），用于首次签发期间。
*   `nginx.https.conf`: **阶段 2**（HTTPS 终结 + HTTP→HTTPS 跳转）模板，签完证书后覆盖到 `nginx.conf` 再 build。
*   `Dockerfile`: 自定义 Nginx 镜像构建文件（基于 `nginx:alpine`，`EXPOSE 80 443`）。
*   `renew.sh`: 自动续签脚本，挂 cron 可零人工维护证书。
*   `DEPLOY.md`: HTTPS 启用 / 证书签发的手把手清单。
*   `certs/`: bind mount 到容器的 `/etc/letsencrypt`，存放 Let's Encrypt 证书与续期账本（首次启动前自动创建）。
*   `acme/`: bind mount 到容器的 `/var/www/certbot`，ACME HTTP-01 challenge 交换目录。
*   `logs/`: nginx 日志持久化目录。

发布到生产环境的 image tag：`adminpage.azurecr.io/nginx-docker:https`。
