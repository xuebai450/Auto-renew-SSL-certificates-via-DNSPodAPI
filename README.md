# SSL Auto-Renewal — certbot + DNSPod DNS-01

基于 **certbot + DNSPod API** 的 Let's Encrypt 证书自动续期方案。通过 DNS-01 challenge 验证域名所有权，无需开放 80/443 端口，适合国内服务器环境。

## 架构概览

```
certbot.timer (systemd, 每天两次)
  └─ certbot.service (oneshot)
       └─ certbot renew --no-random-sleep-on-renew
            ├─ dnspod-auth.sh       ← 通过 DNSPod API 创建 _acme-challenge TXT 记录
            ├─ [Let's Encrypt 验证 DNS]
            ├─ dnspod-cleanup.sh    ← 删除 TXT 记录
            └─ nginx-deploy.sh      ← nginx -t && nginx -s reload
```

## 快速开始

### 1. 获取 DNSPod Token

访问 [console.dnspod.cn](https://console.dnspod.cn) → 密钥管理，创建 API Token。格式为 `ID,Token`（注意是逗号分隔，不是腾讯云 AKID 格式）。

### 2. 一键部署

```bash
git clone https://github.com/YOUR_USERNAME/ssl-auto-renewal.git
cd ssl-auto-renewal

# 设置 DNSPod Token
export DNSPOD_TOKEN="12345,abcdef1234567890abcdef1234567890"

# 部署（-E 保留环境变量，使 DNSPOD_TOKEN 可传递到 root）
sudo -E ./deploy.sh your-domain.com admin@example.com
```

> 部署脚本会把 token 自动写入 `/etc/letsencrypt/dnspod.conf`（权限 600）。
> 这是**必须的**：systemd 定时器触发的自动续期在干净环境中运行，
> 读不到部署时的环境变量，hook 脚本会从这个配置文件读取 token。

### 3. 手动部署

如果不想用一键脚本：

```bash
# 安装 certbot
sudo apt install certbot curl python3

# 部署 hook 脚本
sudo mkdir -p /etc/letsencrypt/hooks
sudo cp hooks/dnspod-auth.sh hooks/dnspod-cleanup.sh hooks/lib-dnspod.sh /etc/letsencrypt/hooks/
sudo chmod 755 /etc/letsencrypt/hooks/*.sh

# 部署 nginx reload hook
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo cp hooks/nginx-deploy.sh /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

# 首次申请证书
sudo certbot certonly --manual --preferred-challenges dns \
  --manual-auth-hook /etc/letsencrypt/hooks/dnspod-auth.sh \
  --manual-cleanup-hook /etc/letsencrypt/hooks/dnspod-cleanup.sh \
  -d your-domain.com -m admin@example.com --agree-tos

# 测试续期
sudo certbot renew --dry-run
```

## 文件结构

```
├── README.md
├── LICENSE
├── deploy.sh                        # 一键部署脚本
├── hooks/
│   ├── lib-dnspod.sh               # DNSPod API 公共函数库
│   ├── dnspod-auth.sh              # certbot manual-auth-hook
│   ├── dnspod-cleanup.sh           # certbot manual-cleanup-hook
│   ├── nginx-deploy.sh             # certbot deploy hook（自动 reload nginx）
│   └── dnspod.conf.example         # Token 配置文件模板
├── systemd/
│   ├── certbot.service             # certbot oneshot 服务
│   └── certbot.timer               # 定时器（每天两次，带随机延迟）
├── examples/
│   ├── renewal.conf.example        # certbot 续期配置模板
│   ├── nginx-site.conf.example     # nginx HTTPS 站点配置模板
│   └── cli.ini                     # certbot 全局配置
└── cron-certbot                    # cron 备用方案（systemd 环境不需要）
```

## 配置说明

### 环境变量

Hook 脚本通过以下环境变量获取配置：

| 变量 | 必需 | 说明 |
|------|------|------|
| `DNSPOD_TOKEN` | ✅ | DNSPod API Token，格式 `ID,Token`（一键部署会自动写入 `/etc/letsencrypt/dnspod.conf`） |
| `DOMAIN` | ❌ | 根域名，为空时自动从 `CERTBOT_DOMAIN` 检测 |
| `MAX_RETRIES` | ❌ | API 调用最大重试次数（默认 3） |
| `DNS_WAIT_MAX` | ❌ | DNS 传播最大等待秒数（默认 120） |

certbot 在调用 hook 时会自动设置 `CERTBOT_DOMAIN` 和 `CERTBOT_VALIDATION`。

### 使用配置文件（可选）

一键部署会自动生成 `/etc/letsencrypt/dnspod.conf`。手动部署时按下面操作：

```bash
# 从模板创建
sudo cp hooks/dnspod.conf.example /etc/letsencrypt/dnspod.conf
sudo chmod 600 /etc/letsencrypt/dnspod.conf
# 编辑填入真实 Token
sudo nano /etc/letsencrypt/dnspod.conf
```

hook 脚本优先读取 `DNSPOD_TOKEN` 环境变量，未设置时才 fallback 到该配置文件，所以两种方式可以混用（例如手动测试时用环境变量，定时续期用配置文件）。

## 常见问题

### 为什么用 DNS-01 而不是 HTTP-01？

国内服务器 80 端口常被封锁，HTTP-01 challenge 不可用。DNS-01 只需要能调用 DNSPod API 创建 TXT 记录，无需开放任何入站端口。

### 多段后缀域名（.com.cn / .co.uk 等）怎么办？

脚本内置了常见多段后缀检测：`com.cn`、`net.cn`、`org.cn`、`gov.cn`、`edu.cn`、`co.uk`、`org.uk`、`ac.uk`、`co.jp`、`com.au`、`com.br`、`com.tw`、`com.hk`、`co.nz`、`com.sg`、`com.mx` 会自动识别为注册域。其他非常规后缀（如 `com.xx` 之类的私有后缀）请显式设置根域名：

```bash
export DOMAIN="example.com.cn"
sudo -E ./deploy.sh www.example.com.cn admin@example.com
```

### 申请泛域名 / 多域名证书

DNS-01 challenge 支持通配符。用逗号分隔多个域名传给 deploy.sh 即可，`--cert-name` 会自动取第一个域名（去掉 `*.` 前缀）作为证书名：

```bash
# 申请 5d5d.com 及其所有子域的泛域名证书
export DNSPOD_TOKEN="ID,Token"
sudo -E ./deploy.sh "5d5d.com,*.5d5d.com" admin@example.com
```

签发后证书位于 `/etc/letsencrypt/live/5d5d.com/`，`pve.5d5d.com`、`ikuai.5d5d.com` 等所有子域均被覆盖。
nginx 的 `ssl_certificate` 指向 `live/5d5d.com/fullchain.pem` 即可。
泛域名证书私钥会同时被所有子域服务使用，分发到其他机器（如软路由）时请注意私钥泄露风险。

### Token 安全吗？

- Token 通过环境变量传入，不写在脚本中
- 配置文件权限设为 600（仅 root 可读）
- **不要**把包含真实 Token 的文件提交到 Git

### 续期失败怎么办？

```bash
# 查看日志
journalctl -u certbot.service -n 50

# 检查 Token 是否有效
curl -X POST https://dnsapi.cn/Account.Info \
  -d "login_token=YOUR_ID,YOUR_TOKEN&format=json"

# 手动测试续期
sudo certbot renew --force-renewal --dry-run
```

### DNSPod 免费版 TTL 限制

DNSPod 免费版最低 TTL 为 600 秒。本脚本设置 TTL=600，DNS 传播等待最长 120 秒。如果 Let's Encrypt 验证时 DNS 尚未生效，certbot 会自动重试。

## 依赖

- **certbot** (>= 1.0) — Let's Encrypt 客户端
- **curl** — 调用 DNSPod API
- **python3** — JSON 解析
- **dig** (可选) — DNS 传播检查（dnsutils/bind-utils 包）

## License

MIT — 详见 [LICENSE](LICENSE)
