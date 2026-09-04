# Nginx 反向代理服务 (Nginx Reverse Proxy)

本项目是一个基于 Docker 的 Nginx 反向代理服务，把不同域名的请求路由到宿主机（Server）上的不同端口服务，并在反代层完成 HTTPS（TLS）终结。

服务器：Azure VM `AquaDev`，公网 IP `4.147.162.158`
生产 image：`adminpage.azurecr.io/nginx-docker:https`

## 🌟 主要功能

*   **容器化部署**: 使用 Docker 和 Docker Compose 进行便捷的启动和管理。
*   **宿主机服务转发**: 借助 `host.docker.internal` 机制，把请求转发到宿主机的本地进程（Localhost）。
*   **HTTPS 终结**: 通过 Let's Encrypt 免费证书 + bind-mount 卷，把 TLS 终结放在反代层（见下方[证书签发](#-证书签发仅-pro)）。
*   **配置烧进 image**: 所有 nginx 配置打包进镜像，服务器上只需要一个 `docker-compose.yml`。
*   **日志持久化**: 容器内的 `access.log` 和 `error.log` 挂载到项目根目录的 `./logs`。
*   **自动健康检查**: docker-compose 中配置了 curl 轮询健康检查，配合 `restart: always` 保证高可用。

## 🔀 路由映射规则

配置在 `nginx.conf` 中，同时支持 WebSocket 协议 (Upgrade)：

| 域名 (Server Name) | 协议 | 目标地址 (Proxy Pass) | 备注 |
| :--- | :--- | :--- | :--- |
| `pro.aquareporter.com.au` | **HTTPS**（HTTP 301 跳转） | `http://host.docker.internal:8888` | Aquareporter Web；Passkey/WebAuthn 需要 secure context |
| `pro.aquareporter.com.au/api/` | **HTTPS** | `http://host.docker.internal:8088` | Aquareporter API；同源同端口，避免 Mixed Content |
| `aquadev.aquareporter.com.au` | HTTP | `http://host.docker.internal:8000` | adminpage 内网访问，不做 TLS 终结 |

80 端口上 `pro` 只保留 `/.well-known/acme-challenge/`（供 Let's Encrypt 验证），其余一律 301 到 HTTPS；`aquadev` 全部走 80 不跳转。

## 🚀 快速启动

1.  **准备环境**: 确保服务器已安装 Docker 和 Docker Compose。
2.  **启动服务**: 在项目根目录下执行：
    ```bash
    docker compose up -d
    ```
3.  **查看运行状态**:
    ```bash
    docker compose ps
    ```
4.  **查看实时日志**:
    ```bash
    docker compose logs -f
    ```

---

# 📦 发布流程

发布方式：**所有配置烧进 image，服务器上只放一个 `docker-compose.yml`**。

## 本地构建 + 推送

```powershell
cd D:\workspace\nginx-docker
docker build -t adminpage.azurecr.io/nginx-docker:https .
docker push adminpage.azurecr.io/nginx-docker:https
```

前提：本地已 `docker login adminpage.azurecr.io`。

## 服务器拉取 + 部署

首次部署需要先建目录：

```bash
mkdir -p ~/nginx-docker/{certs,acme,logs}
```

然后把本地的 `docker-compose.yml` 内容粘贴到服务器（`vi docker-compose.yml`，注意 `:set paste` 和 `:set ff=unix`），之后：

```bash
cd ~/nginx-docker && docker compose pull && docker compose up -d && docker compose ps
```

> ⚠️ 这会**重建 nginx 容器**，pro 和 aquadev 有几秒中断。adminpage / aquareporter 那些容器不在本 compose project 里，不受影响 —— 但**不要加 `--remove-orphans`**。
>
> 只是想让新证书生效的话，用 `docker exec nginx-reverse-proxy nginx -s reload` 平滑重载，零中断。

---

# 🔐 HTTPS / Let's Encrypt 证书

证书由 Let's Encrypt 免费签发，有效期 **90 天**。服务保持只在公司内网可访问，**仅在签发 / 续签那几分钟把 80 端口临时对公网开放**。

## 前置准备

| 项 | 要求 |
|---|---|
| DNS | `pro.aquareporter.com.au` 的 A 记录指向 `4.147.162.158`（不开 Cloudflare Proxy） |
| 防火墙 | Azure NSG 里 TCP 80 能临时对 `Any` 开放（见下节） |
| 时间 | 服务器时间正确（NTP 同步） |
| 邮箱 | 一个 Let's Encrypt 通知用邮箱 |
| ACR 登录 | 本地能 `docker push` 到 `adminpage.azurecr.io` |

> **这台服务器上没有主机级防火墙**：`ufw` 是 inactive，`firewall-cmd` 不存在。唯一的闸门是 **Azure NSG**。
> 千万不要为了「放行端口」去执行 `sudo ufw enable` —— ufw 默认 deny incoming，会当场切断你正在用的 SSH。

## 🔴 证书签发（仅 pro）

### 第 0 步（最关键）· 在 Azure NSG 放行 80 端口给 `Any`

> ## ⚠️ 不做这一步，后面所有 certbot 命令都会以 `Timeout during connect (likely firewall problem)` 失败。
>
> Azure NSG 里现有的规则 **1000「HTTP」虽然放行了 80 端口，但 Source 被限定在公司出口 IP `103.17.250.78, 220.233.36.27`**。
> Let's Encrypt 的验证服务器**不在这个白名单里，而且它的源 IP 不公布、不固定，无法加白名单** —— 必须临时对 `Any` 开放。

Azure Portal → VM `AquaDev` → **Networking** → **Network settings** → **Add inbound port rule**：

| 字段 | 值 |
|---|---|
| Source | **`Any`** ← 重点，不能填公司 IP |
| Source port ranges | `*` |
| Destination | `Any` |
| Service | `Custom` |
| Destination port ranges | `80` |
| Protocol | `TCP` |
| Action | `Allow` |
| **Priority** | `900`（排在现有 1000「HTTP」之前，好认、事后不会漏删） |
| Name | `letsencrypt-temp` |

命令行版：

```bash
az network nsg rule create --resource-group <资源组> --nsg-name <NSG名> --name letsencrypt-temp --priority 900 --source-address-prefixes '*' --destination-port-ranges 80 --access Allow --protocol Tcp --direction Inbound
```

**两个必须注意的点**：

1. **不要直接修改现有的 1000「HTTP」规则**把 Source 改成 `Any` 再改回来 —— 改回来时要手工重输那两个 IP，敲错一个字符就把公司访问弄断了，而且不容易立刻发现。加一条独立的临时规则、用完删掉，原规则全程不动。
2. **NSG 可能同时绑在网卡（NIC）和子网（Subnet）两层**，入站流量要两层都放行才能到达。在 **Network settings** 页面确认这两处绑的是不是同一个 NSG；是两个不同的 NSG 就都要加这条规则。

### 第 1 步 · 验证 80 端口真的从公网可达

> ### ⚠️ 不要用手机浏览器验证。
> 现代手机浏览器（Chrome / Safari）默认开启 HTTPS-First，会把你输入的 `http://` **悄悄升级成 `https://`**。而 443 只对公司 IP 开放，手机走 4G 一样超时 —— 看起来像「80 没开」，实际上根本没测到 80。**这个坑已经浪费过一轮排查时间。**

用 certbot 自带的 `--dry-run`：它走 Let's Encrypt **staging** 服务器做一次完整的真实验证，同样从公网回连你的 80 端口，但不消耗正式环境限速额度，失败也无副作用：

```bash
cd ~/nginx-docker && docker compose run --rm --entrypoint certbot certbot renew --cert-name pro.aquareporter.com.au --webroot -w /var/www/certbot --dry-run
```

看到 `The dry run was successful` 再往下走。

> 首次签发（`certs/` 还是空的、没有续签账本）时 `renew --dry-run` 无从跑起，改用：
> `certonly --dry-run --webroot -w /var/www/certbot -d pro.aquareporter.com.au --email 你的邮箱 --agree-tos --no-eff-email -n`

### 第 2 步 · 正式签发 / 续签

**续签**（`certs/renewal/pro.aquareporter.com.au.conf` 存在时，把上一条去掉 `--dry-run` 即可）：

```bash
cd ~/nginx-docker && docker compose run --rm --entrypoint certbot certbot renew --cert-name pro.aquareporter.com.au --webroot -w /var/www/certbot
```

**首次签发**（或续签账本丢失时）：

```bash
cd ~/nginx-docker && docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot -d pro.aquareporter.com.au --email 你的邮箱 --agree-tos --no-eff-email -n
```

成功标志：`Congratulations, all renewals succeeded` / `Successfully received certificate`。

加 `--cert-name pro.aquareporter.com.au` 是为了只处理 pro —— aquadev 现在是 HTTP-only 不需要证书，让它跟着一起跑只会多一条必然失败的记录。

> 证书**已经过期也照样能续**，`renew` 不要求证书仍在有效期内。

### 第 3 步 · reload nginx

```bash
docker exec nginx-reverse-proxy nginx -s reload
```

**这步必须做** —— nginx 只在启动和 reload 时读证书文件，不 reload 的话内存里还是旧的那张。

`reload` 是平滑重载：监听 socket 全程不关闭，起一批新 worker 读新证书，老 worker 处理完手上请求再退出，**pro 和 aquadev 都零中断**。它还有个安全兜底：新配置有问题时 reload 会失败并在 `logs/error.log` 报错，但老 worker 继续服务；而 `docker restart` 遇到同样问题会让 nginx 直接起不来，两个域名一起挂。**所以永远用 reload，不要用 restart。**

### 第 4 步 · 立刻关闭 80 端口

回 Azure Portal **删除** `letsencrypt-temp`（priority 900）那条规则：

```bash
az network nsg rule delete --resource-group <资源组> --nsg-name <NSG名> --name letsencrypt-temp
```

> 这个窗口期里 `aquadev.aquareporter.com.au`（HTTP-only、不跳转）也会对公网可见。签完立刻关，别开着走开。

### 第 5 步 · 验证

查 nginx **当前实际吐出来的**证书（不是磁盘上的文件），这是最有说服力的一条：

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername pro.aquareporter.com.au 2>/dev/null | openssl x509 -noout -dates -subject
```

`notAfter` 应该是约 90 天后。再补几条：

```bash
curl -I https://pro.aquareporter.com.au          # HTTP/2 200
curl -I http://pro.aquareporter.com.au           # 301 → https
curl -I http://aquadev.aquareporter.com.au       # HTTP/1.1 200（不跳转）
```

浏览器（从公司网络）打开 `https://pro.aquareporter.com.au` 应有**绿色锁**、无警告。

## 🩺 排错

| 现象 | 原因 / 处理 |
|---|---|
| `Timeout during connect (likely firewall problem)` | 80 端口没有对 `Any` 开放。回第 0 步；注意 NIC 和 Subnet 两层 NSG |
| `Connection refused` | nginx 没在监听 80。用 `sudo ss -lntp` 过滤 `:80` 应看到 `0.0.0.0:80` |
| `unauthorized` 或 404 | challenge 文件没被 nginx 读到。`docker exec nginx-reverse-proxy ls -la /var/www/certbot/.well-known/acme-challenge/` |
| `No renewals were attempted` | 续签账本丢失（`certs/renewal/` 为空），改用 `certonly` |
| 手机 4G 访问 `http://` 超时 | 浏览器 HTTPS 自动升级导致的**误判**，不代表 80 不通。用 `--dry-run` 判断 |

手工验证 nginx 侧是否正常（可切开「nginx 问题」和「网络问题」）：

```bash
mkdir -p ~/nginx-docker/acme/.well-known/acme-challenge && echo ok > ~/nginx-docker/acme/.well-known/acme-challenge/testfile
```

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -H "Host: pro.aquareporter.com.au" http://127.0.0.1/.well-known/acme-challenge/testfile
```

`HTTP 200` 说明 nginx 完全正常，问题纯在网络层。测完记得删掉 `~/nginx-docker/acme/.well-known/acme-challenge/testfile`。

## 🔁 90 天续签清单

证书 90 天到期，提前 30 天内可续。**不需要重新 build / push image**，走上面第 0 → 4 步即可：

1. Azure NSG 加 `letsencrypt-temp`（80 / TCP / Source `Any` / Priority 900）
2. `certbot renew --cert-name pro.aquareporter.com.au --webroot -w /var/www/certbot --dry-run` 确认可达
3. 去掉 `--dry-run` 正式续
4. `docker exec nginx-reverse-proxy nginx -s reload`
5. Azure Portal 删除 `letsencrypt-temp`

> ⚠️ 仓库里的 `renew.sh` 目前**不能直接用** —— 它的 `OPEN_80` / `CLOSE_80` 写死成 `ufw` 命令，而这台机器上 ufw 根本没启用。挂 cron 会静默地什么都不开、然后每次续签超时失败。要自动化必须先把这两行换成 `az network nsg rule create/delete`，并在服务器上装 az CLI + 配好服务主体（cron 里无法交互登录）。

---

# ⚙️ 应用层配置

切到 HTTPS 后，后端 `aquareporter-api/.env` 需同步（**仅 aquareporter，adminpage 不动**）：

```bash
PASSKEY_RP_ID=pro.aquareporter.com.au
PASSKEY_RP_NAME=Aquareporter
PASSKEY_ORIGINS=https://pro.aquareporter.com.au

# 如果有 Google OAuth，同步改
GOOGLE_CALLBACK_URL=https://pro.aquareporter.com.au/api/auth/google/callback
FRONTEND_URL=https://pro.aquareporter.com.au
```

改完重启后端进程，并到 Google Cloud Console 把 OAuth 回调 URL 加上 HTTPS 版本。

## ✅ 验收：Passkey 端到端

1. 浏览器访问 `https://pro.aquareporter.com.au` 用密码登录
2. 进 **Settings → Security Settings**
3. 点 **Add a passkey** → Touch ID / Face ID / Windows Hello → 列表出现新条目
4. 退出登录 → 登录页点 **Sign in with passkey** → 一键完成登录

---

# 📁 文件清单

| 文件 / 目录 | 用途 | 烧进 image | 服务器需要 |
|---|---|:---:|:---:|
| `Dockerfile` | 镜像构建（基于 `nginx:alpine`，`EXPOSE 80 443`） | ✅ | ❌ |
| `nginx.conf` | **当前生效配置**：pro 走 HTTPS + 80 保留 ACME 路径，aquadev 走 HTTP | ✅ | ❌ |
| `nginx.https.conf` | 历史模板，内容与 `nginx.conf` 相同（仅注释不同） | ❌ | ❌ |
| `docker-compose.yml` | 编排：nginx 服务 + certbot 工具容器 + bind mount + 健康检查 | ❌ | ✅ |
| `renew.sh` | 续签脚本（**当前不可用**，见上方说明） | ❌ | ❌ |
| `readme.md` | 本文档 | ❌ | ❌ |
| `certs/` | bind mount → 容器 `/etc/letsencrypt`，证书与续签账本 | ❌ | ✅ |
| `acme/` | bind mount → 容器 `/var/www/certbot`，ACME challenge 交换目录 | ❌ | ✅ |
| `logs/` | nginx 日志持久化 | ❌ | ✅ |

`certs/` `acme/` `logs/` 已在 `.gitignore` 中，证书和私钥不会被提交。

> **已知缺口**：`nginx.conf` 需要 `certs/live/pro.aquareporter.com.au/` 下的证书存在才能启动。在一台 `certs/` 为空的全新机器上，这个 image 会起不来，无法完成首次签发。真要重新做首次部署，得先准备一份 HTTP-only 的引导配置（把 443 server 块注释掉）先跑起来，签完证书再换回完整配置。

---

# ↩️ 回滚

如果切到 HTTPS 之后业务异常：

1. 本地准备一份去掉 443 server 块的 `nginx.conf`，重新 build 并推同一个 `:https` tag 覆盖 ACR
2. 服务器 `docker compose pull && docker compose up -d`
3. `certs/` 和 `acme/` 目录保留，下次重新切 HTTPS 不必重新签发

---

# 🔒 已知的安全问题（待处理）

以下是排查证书问题时在 Azure NSG 里顺带发现的，不影响证书流程，但值得收敛：

*   **规则 1002「ssh」把 22 端口对 `0.0.0.0/0` 开放** —— SSH 全网可达，优先级最高的一条。建议改成和 HTTP/HTTPS 一样的公司 IP 白名单。
*   **Defender JIT 规则实际未生效** —— `MicrosoftDefenderForCloud-JITRule`（priority 4096，Deny 22）排在 1002 之后，而 NSG 是**优先级数字小的先匹配、命中即停**，所以它被 1002 完全绕过了。
*   **规则 1003（8080-8084）和 1005（mqtt 1883/8083 等）的 Source 是 `Any`** —— 如果这些服务只给内网用，同样应收到白名单。
