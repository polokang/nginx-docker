# 部署：Nginx + Let's Encrypt（HTTP-01 临时开 80 方案）

把现有 HTTP-only 反代升级到 HTTPS，证书由 Let's Encrypt 免费签发。**服务保持只在公司内网可访问**，仅在签发那几秒钟把 80 端口临时对外开放。

发布方式沿用既有工作流：**所有配置烧进 image，服务器上只放一个 `docker-compose.yml`**。

**当前域名策略**：

| 域名 | 协议 | 用途 |
|---|---|---|
| `pro.aquareporter.com.au` | **HTTPS**（Let's Encrypt 证书） | Aquareporter（Passkey 需要 secure context） |
| `aquadev.aquareporter.com.au` | **HTTP** | adminpage 内网访问，不做 TLS 终结 |

Image：`adminpage.azurecr.io/nginx-docker:https`

---

## 0. 前置准备

| 项 | 要求 |
|---|---|
| DNS | `pro.aquareporter.com.au` 的 A 记录指向本机公网 IP（不开 Cloudflare Proxy）；aquadev 同上但不签证书 |
| 防火墙 | TCP 80 能临时打开（签发用）、TCP 443 长期对内网开放 |
| 时间 | 服务器时间正确（NTP 同步） |
| 邮箱 | 一个 Let's Encrypt 通知用邮箱 |
| ACR 登录 | 本地能 `docker push` 到 `adminpage.azurecr.io` |

---

## 1️⃣ 本地构建 + 推送"阶段 1" image（HTTP-only）

```powershell
cd D:\workspace\nginx-docker

# 当前仓库内的 nginx.conf 默认就是阶段 1（HTTP + ACME challenge）
docker build -t adminpage.azurecr.io/nginx-docker:https .
docker push adminpage.azurecr.io/nginx-docker:https
```

> 这次推送的 image 内包含阶段 1 的 nginx.conf，让 80 端口能响应 Let's Encrypt 的 ACME challenge。

---

## 2️⃣ 服务器准备目录 + 起 nginx

服务器上**只需要一个文件** `docker-compose.yml`，其他配置全在 image 里。

```bash
mkdir -p ~/nginx-docker/{certs,acme,logs}
cd ~/nginx-docker

# 把本地的 docker-compose.yml 内容粘贴过去
vi docker-compose.yml
# :set paste -> i -> 鼠标粘贴 -> Esc -> :set ff=unix -> :wq

docker compose pull
docker compose up -d
docker compose ps          # nginx-reverse-proxy 应为 Up
```

内网验证业务还能访问：

```bash
curl -I http://pro.aquareporter.com.au
curl -I http://aquadev.aquareporter.com.au
```

---

## 3️⃣ 临时放行 80 端口

公司防火墙 / 云安全组里给 TCP 80 加一条"任意来源允许"入站规则。

**用手机 4G/5G**（脱离公司 WiFi）访问 `http://pro.aquareporter.com.au`，能看到任意响应（不超时）即可。

---

## 4️⃣ 签发证书（仅 pro）

```bash
cd ~/nginx-docker

# pro
docker compose run --rm --entrypoint certbot certbot \
  certonly --webroot -w /var/www/certbot \
  -d pro.aquareporter.com.au \
  --email YOUR_EMAIL@example.com --agree-tos --no-eff-email -n
```

看到 `Successfully received certificate` 后验证：

```bash
ls certs/live/pro.aquareporter.com.au/
# cert.pem  chain.pem  fullchain.pem  privkey.pem  README
```

> aquadev 保持 HTTP，不需要证书。如果之前已经签过 aquadev 的证书，证书文件留在 `certs/` 里不影响，也可以执行
> `docker compose run --rm --entrypoint certbot certbot delete --cert-name aquadev.aquareporter.com.au` 主动清理。

---

## 5️⃣ 立刻关闭 80 端口

回防火墙控制台，**删除**第 3 步那条临时规则。

手机再次访问 `http://pro.aquareporter.com.au` 应**超时**，证明已对外关闭。

---

## 6️⃣ 本地构建 + 推送"阶段 2" image（HTTPS）

```powershell
cd D:\workspace\nginx-docker

# 把阶段 2 配置覆盖到 nginx.conf
copy /Y nginx.https.conf nginx.conf

# 同一个 :https tag 覆盖推
docker build -t adminpage.azurecr.io/nginx-docker:https .
docker push adminpage.azurecr.io/nginx-docker:https

# 还原本地仓库（让源码树里的 nginx.conf 回到阶段 1 干净状态）
git checkout nginx.conf
```

服务器拉新 image + 起：

```bash
cd ~/nginx-docker
docker compose pull
docker compose up -d
docker compose ps
```

---

## 7️⃣ 验证 HTTPS + 切换应用层

**内网验证**：

```bash
# pro：HTTPS
curl -I https://pro.aquareporter.com.au          # HTTP/2 200
curl -I http://pro.aquareporter.com.au           # 301 → https

# aquadev：仍走 HTTP
curl -I http://aquadev.aquareporter.com.au       # HTTP/1.1 200（不跳转）
```

浏览器打开 `https://pro.aquareporter.com.au` 应有**绿色锁**，无警告。

**改后端 `aquareporter-api/.env`**（仅 aquareporter，**adminpage 不动**）：

```bash
PASSKEY_RP_ID=pro.aquareporter.com.au
PASSKEY_RP_NAME=Aquareporter
PASSKEY_ORIGINS=https://pro.aquareporter.com.au

# 如果有 Google OAuth，同步改
GOOGLE_CALLBACK_URL=https://pro.aquareporter.com.au/api/auth/google/callback
FRONTEND_URL=https://pro.aquareporter.com.au
```

记得到 Google Cloud Console 把 OAuth 回调 URL 加上 HTTPS 版本。

重启后端进程。

---

## ✅ 验收：Passkey 端到端

1. 浏览器访问 `https://pro.aquareporter.com.au` 用密码登录
2. 进 **Settings → Security Settings**
3. 点 **Add a passkey** → Touch ID / Face ID / Windows Hello → 列表出现新条目
4. 退出登录 → 登录页点 **Sign in with passkey** → 一键完成登录

至此 Passkey 在生产环境跑通。

---

## ⚠️ 90 天后的续签（本次不做，做记录）

证书 90 天到期。届时（提前 30 天内）只需重做一次步骤 3 → 4 → 5，把 `certonly` 命令换成 `renew` 即可。**不需要重新 build image**：

```bash
# 在服务器上
sudo ufw allow 80/tcp
docker compose run --rm --entrypoint certbot certbot renew --webroot -w /var/www/certbot
sudo ufw delete allow 80/tcp
docker exec nginx-reverse-proxy nginx -s reload
```

仓库里附带的 `renew.sh` 已经把这套流程脚本化，将来要自动化时直接挂 cron 即可。

---

## 文件清单

| 文件 | 用途 | 烧进 image？ | 服务器需要？ |
|---|---|---|---|
| `Dockerfile` | 构建 image | ✅ | ❌ |
| `nginx.conf` | 阶段 1：HTTP + ACME | ✅ | ❌ |
| `nginx.https.conf` | 阶段 2 模板：HTTPS | ⚠️ 临时覆盖 nginx.conf 再 build | ❌ |
| `docker-compose.yml` | 编排（image + 端口 + bind mount） | ❌ | ✅ vi 粘贴 |
| `renew.sh` | 续签脚本（将来用） | ❌ | 续签时再传 |
| `DEPLOY.md` | 本文档 | ❌ | ❌ |

---

## 回滚

如果切到 HTTPS 之后业务异常：

1. 本地把仓库还原到推阶段 1 之前的状态（或者直接基于当前 nginx.conf = 阶段 1 重新 build push 一次 `:https`），覆盖 ACR
2. 服务器 `docker compose pull && docker compose up -d`
3. `certs/` 和 `acme/` 目录保留，下次重新切 HTTPS 不必重新签发
