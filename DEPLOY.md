# 部署：Nginx + Let's Encrypt（HTTP-01 临时开 80 方案）

本文档手把手把现有的 HTTP-only 反代升级到 HTTPS，证书由 Let's Encrypt
免费签发，**不需要把服务长期对公网开放** —— 仅在签发 / 续期那几秒钟
临时打开 80 端口。

适用范围：
- 内网用户（出公司就访问不了）的内部业务系统
- 已有自建 Nginx 镜像 + Docker Compose 部署架构
- 需要浏览器原生信任的证书（例如启用 Passkey / WebAuthn）

---

## 0. 前置准备

| 项 | 要求 |
|---|---|
| DNS | `pro.aquareporter.com.au` 与 `aquadev.aquareporter.com.au` 的 A 记录指向本机公网 IP（不开 Cloudflare Proxy） |
| 防火墙 | TCP 80、TCP 443 入站规则能临时打开（签发时 80 短暂开放，关闭后 443 长期开放给内网） |
| 时间 | 服务器时间正确（NTP 同步） |
| 邮箱 | 一个可接收续期失败通知的邮箱 |

> ⚠️ 如果服务器在公司防火墙后无法对外暴露 80，本方案不适用，请改用
> DNS-01 challenge（需要 DNS 服务商 API token）。

---

## 1. 同步代码

在服务器上：

```bash
cd ~/nginx-docker
git pull
ls
# 应该看到：DEPLOY.md  Dockerfile  docker-compose.yml  nginx.conf
#           nginx.https.conf  renew.sh  readme.md  logs/
```

首次还需要：

```bash
chmod +x renew.sh
mkdir -p certs acme
```

---

## 2. 构建并推到 ACR（如果你的部署是从 ACR 拉镜像）

> 如果你在生产服务器**直接构建本地用**，跳过 push 那步即可。

```bash
cd ~/nginx-docker
docker build -t adminpage.azurecr.io/nginx-docker:latest .
docker push adminpage.azurecr.io/nginx-docker:latest
```

---

## 3. 拉起 nginx（阶段 1：HTTP-only + ACME challenge）

```bash
docker compose pull           # 如果是从 ACR 拉
docker compose up -d
docker compose ps             # nginx-reverse-proxy 应该是 Up (healthy)
```

验证业务可访问（内网即可）：

```bash
curl -I http://pro.aquareporter.com.au
curl -I http://aquadev.aquareporter.com.au
```

---

## 4. 临时放行 80 端口

> ⚠️ 这一步会让你的服务**短暂暴露在公网**。务必接下来几分钟内完成签发并关闭。

打开公司防火墙 / 云安全组，对 TCP 80 添加"任意来源允许"入站规则。

**从外网手机 4G/5G** 验证 80 能被外面访问到：

```
访问  http://pro.aquareporter.com.au
应看到正常业务页面（或任意非"连接超时"的响应）
```

---

## 5. 用 staging 环境先跑一次（避免触发正式 Let's Encrypt 限速）

```bash
docker compose run --rm --entrypoint certbot certbot \
  certonly --webroot -w /var/www/certbot \
  --staging \
  -d pro.aquareporter.com.au \
  --email YOUR_EMAIL@example.com --agree-tos --no-eff-email -n
```

成功输出包含 `Successfully received certificate`。然后清掉 staging 证书：

```bash
docker compose run --rm --entrypoint certbot certbot \
  delete --cert-name pro.aquareporter.com.au -n
```

---

## 6. 正式签发两个域名

**pro：**

```bash
docker compose run --rm --entrypoint certbot certbot \
  certonly --webroot -w /var/www/certbot \
  -d pro.aquareporter.com.au \
  --email YOUR_EMAIL@example.com --agree-tos --no-eff-email -n
```

**aquadev：**

```bash
docker compose run --rm --entrypoint certbot certbot \
  certonly --webroot -w /var/www/certbot \
  -d aquadev.aquareporter.com.au \
  --email YOUR_EMAIL@example.com --agree-tos --no-eff-email -n
```

验证证书已落盘：

```bash
ls certs/live/
# pro.aquareporter.com.au/    aquadev.aquareporter.com.au/

ls certs/live/pro.aquareporter.com.au/
# cert.pem  chain.pem  fullchain.pem  privkey.pem  README
```

---

## 7. 立即关闭 80 端口

回防火墙 / 云安全组，**删除**第 4 步那条临时入站规则。

外网手机再次 `curl http://pro.aquareporter.com.au` 应**连接失败 / 超时**，证明 80 已对外关闭。

---

## 8. 切到阶段 2 配置（启用 HTTPS）

```bash
cd ~/nginx-docker
cp nginx.conf nginx.http.conf.bak   # 留一份阶段 1 备份
cp nginx.https.conf nginx.conf
docker build -t adminpage.azurecr.io/nginx-docker:latest .
docker push adminpage.azurecr.io/nginx-docker:latest   # 如适用
docker compose pull
docker compose up -d
docker compose ps
```

---

## 9. 验证 HTTPS

**内网机器**：

```bash
curl -I https://pro.aquareporter.com.au
# HTTP/2 200

curl -I http://pro.aquareporter.com.au
# HTTP/1.1 301 Moved Permanently
# Location: https://pro.aquareporter.com.au/
```

浏览器打开 `https://pro.aquareporter.com.au` 应看到地址栏**绿色锁**，没有警告。

---

## 10. 应用层同步切换（关键！）

### 10-1 后端 aquareporter-api 的 `.env`

```bash
PASSKEY_RP_ID=pro.aquareporter.com.au
PASSKEY_RP_NAME=Aquareporter
PASSKEY_ORIGINS=https://pro.aquareporter.com.au
```

改完后重启后端进程。

### 10-2 Google OAuth 回调

```bash
GOOGLE_CALLBACK_URL=https://pro.aquareporter.com.au/api/auth/google/callback
FRONTEND_URL=https://pro.aquareporter.com.au
```

并到 [Google Cloud Console](https://console.cloud.google.com/) 把 OAuth
回调 URL 改成 HTTPS 版本。

### 10-3 adminpage 一侧同理

如果 adminpage 项目也用了类似的 RP_ID / FRONTEND_URL，把 aquadev 的也改成 https。

---

## 11. 配置自动续期 cron

在服务器上：

```bash
crontab -e
```

添加一行（每天 03:00 跑一次；certbot 自己判断到期）：

```
0 3 * * * /home/aquacentosadmin/nginx-docker/renew.sh >> /var/log/cert-renew.log 2>&1
```

> 注意：`renew.sh` 默认用 `ufw` 开关 80。如果你不用 ufw，编辑脚本里的
> `OPEN_80` / `CLOSE_80` 改成你的防火墙命令（firewalld / iptables /
> 云 CLI）。
>
> 如果 cron 用 root 跑就不需要 `sudo`；用 aquacentosadmin 跑需要为
> `ufw` 加 `NOPASSWD` 到 sudoers。

查看续期日志：

```bash
tail -f /var/log/cert-renew.log
```

第一次手动跑一遍验证：

```bash
~/nginx-docker/renew.sh
# 应该看到 certbot 输出"Certificate not yet due for renewal"，然后 nginx reload
```

---

## 12. 回滚预案

如果切到 HTTPS 之后业务异常：

```bash
cd ~/nginx-docker
cp nginx.http.conf.bak nginx.conf    # 还原阶段 1 配置
docker build -t adminpage.azurecr.io/nginx-docker:latest .
docker compose up -d
```

证书 / acme bind mount 全部保留，下次重新切 HTTPS 时无需重新签发。

---

## 文件清单

| 文件 | 用途 |
|---|---|
| `docker-compose.yml` | nginx + certbot 编排；bind mount `./certs` 和 `./acme` |
| `Dockerfile` | EXPOSE 80 443 的自定义 nginx 镜像构建脚本 |
| `nginx.conf` | **当前生效**配置（默认是阶段 1 HTTP-only） |
| `nginx.https.conf` | 阶段 2 HTTPS 配置（签完证书后复制到 nginx.conf） |
| `renew.sh` | 自动续期脚本，被 cron 调用 |
| `certs/` | bind mount，证书目录（容器内 `/etc/letsencrypt`） |
| `acme/` | bind mount，ACME challenge 交换目录 |
| `logs/` | nginx 日志持久化 |
