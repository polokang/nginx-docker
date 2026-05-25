#!/usr/bin/env bash
#
# renew.sh — 自动续期 Let's Encrypt 证书
#
#   1. 临时放行 TCP 80（HTTP-01 需要）
#   2. 跑 certbot renew —— 未到期时 certbot 自动 no-op
#   3. 立即关闭 TCP 80
#   4. reload nginx，让新证书（如果有）生效
#
# 推荐用法（cron）：
#   0 3 * * * /home/USER/nginx-docker/renew.sh >> /var/log/cert-renew.log 2>&1
#
# 默认假设 ufw；如果你用 firewalld / iptables / 云安全组 CLI，把 OPEN_80
# 和 CLOSE_80 改成对应命令即可。
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

# ── 防火墙开/关（按需修改） ──────────────────────────────────────────
OPEN_80="sudo ufw allow 80/tcp comment 'letsencrypt-temp'"
CLOSE_80="sudo ufw --force delete allow 80/tcp"

# 不论中途出错都尝试关闭 80，防止意外暴露
cleanup() {
    echo "[$(date -Is)] closing port 80…"
    eval "$CLOSE_80" || true
}
trap cleanup EXIT

echo "[$(date -Is)] opening port 80 for ACME challenge…"
eval "$OPEN_80"
sleep 3   # 让规则生效

echo "[$(date -Is)] running certbot renew…"
docker compose run --rm --entrypoint certbot certbot \
    renew --webroot -w /var/www/certbot --quiet

echo "[$(date -Is)] reloading nginx…"
docker exec nginx-reverse-proxy nginx -s reload || true

echo "[$(date -Is)] done."
