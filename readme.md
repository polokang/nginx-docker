# Nginx 反向代理服务 (Nginx Reverse Proxy)

本项目是一个基于 Docker 的 Nginx 反向代理服务。主要用于将不同的外网域名请求，路由到宿主机（Server）上的不同端口服务。

## 🌟 主要功能

*   **容器化部署**: 使用 Docker 和 Docker Compose 进行便捷的启动和管理。
*   **宿主机服务转发**: 配置中借助了 `host.docker.internal` 机制，能够顺利地将请求转发到宿主机的本地进程（Localhost）。
*   **日志持久化**: 容器内部的 Nginx `access.log` 和 `error.log` 将被挂载到项目根目录下的 `./logs` 文件夹中以便于排查问题。
*   **自动健康检查**: 在 docker-compose 中配置了通过 curl 轮询进行健康检查 (Healthcheck)，并通过 `restart: always` 策略保证服务高可用。

## 🔀 路由映射规则

我们在 `nginx.conf` 中配置了如下两条最主要的子域名规则，同时支持 WebSocket 协议 (Upgrade)：

| 域名 (Server Name) | 目标地址 (Proxy Pass) | 备注 |
| :--- | :--- | :--- |
| `pro.aquareporter.com.au` | `http://host.docker.internal:8888` | 指向内部 Aquareporter Web (8888 端口) |
| `aquadev.aquareporter.com.au` | `http://host.docker.internal:8000` | 指向内部 Adminpage Web (8000 端口) |

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

*   `docker-compose.yml`: 编排文件，定义了 nginx 服务、网络、健康检查及日志数据卷。
*   `nginx.conf`: 核心的反向代理路由配置文件，如果要增减域名和端口映射请修改此文件。
*   `Dockerfile`: 用于打包自定义 Nginx 镜像的 Docker 配置文件（基于轻量级的 `nginx:alpine` 构建）。
*   `logs/`: 用于持久化存放 Nginx 运行日志的本地目录（会在容器启动后自动生成日志文件）。
