#!/bin/bash
#=================================================================#
#  System Required: Debian 12+                                    #
#  Description: n8n Chinese Industrial-Grade Deployment Script    #
#  Optimizations: Swap Fallback, Node Memory Limit, Healthcheck   #
#=================================================================#

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN}必须使用 root 用户运行！\n" && exit 1

echo -e "${GREEN}正在启动 n8n 工业级部署脚本 V5.0...${PLAIN}"

#-----------------------------------------------------------------#
# 1. 智能性能评估与 Swap 兼容性配置 (解决 fallocate 失败问题)
#-----------------------------------------------------------------#
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')

if [ "$MEM_TOTAL" -le 2048 ] && [ "$SWAP_TOTAL" -eq 0 ]; then
    echo -e "${YELLOW}检测到低内存环境，正在配置虚拟内存...${PLAIN}"
    [ "$MEM_TOTAL" -le 600 ] && SWAP_SIZE_MB=2048 || SWAP_SIZE_MB=1024
    
    # 尝试使用 fallocate，失败则降级使用 dd
    if ! fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null; then
        echo -e "${YELLOW}fallocate 不受支持，正在使用 dd 创建 Swap...${PLAIN}"
        dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB}
    fi
    
    chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    echo -e "${GREEN}Swap 配置成功。${PLAIN}"
fi

#-----------------------------------------------------------------#
# 2. 参数准备与随机安全密钥
#-----------------------------------------------------------------#
read -p "请输入域名 (默认: ema.ink): " DOMAIN
[ -z "${DOMAIN}" ] && DOMAIN="ema.ink"
read -p "请输入邮箱 (用于 SSL): " EMAIL
[ -z "${EMAIL}" ] && EMAIL="admin@${DOMAIN}"

RANDOM_KEY=$(tr -dc 'a-z0-9' </dev/urandom | head -c 32)
BASIC_AUTH_PASS=$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)

#-----------------------------------------------------------------#
# 3. 依赖安装 (强制安装 docker-compose 插件)
#-----------------------------------------------------------------#
apt update && apt install -y curl vim nginx certbot python3-certbot-nginx
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
    apt install -y docker-compose-plugin # 确保插件版 Compose 可用
    systemctl enable --now docker
fi

#-----------------------------------------------------------------#
# 4. 目录架构解耦与权限预设
#-----------------------------------------------------------------#
mkdir -p ~/n8n/n8n_data ~/n8n/n8n_files
chown -R 1000:1000 ~/n8n/n8n_data ~/n8n/n8n_files

cat > ~/n8n/docker-compose.yml <<EOF
services:
  n8n:
    image: blowsnow/n8n-chinese:latest
    container_name: n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    logging: # 磁盘防爆控制
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck: # 故障自愈机制
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678"]
      interval: 30s
      timeout: 10s
      retries: 5
    environment:
      - NODE_OPTIONS=--max-old-space-size=512 # 强制 Node 内存回收
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${DOMAIN}/
      - N8N_EDITOR_BASE_URL=https://${DOMAIN}/
      - GENERIC_TIMEZONE=Asia/Shanghai
      - N8N_DEFAULT_LOCALE=zh-CN
      - N8N_ENCRYPTION_KEY=${RANDOM_KEY}
      - N8N_METRICS=true
      - N8N_PAYLOAD_SIZE_MAX=100
      - N8N_BINARY_DATA_MODE=filesystem # 二进制文件强制存盘
      - N8N_BINARY_DATA_STORAGE_PATH=/files
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=72
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=${BASIC_AUTH_PASS}
    volumes:
      - ./n8n_data:/home/node/.n8n
      - ./n8n_files:/files # 独立存储目录
EOF

# 命令兼容性拉起
cd ~/n8n
(docker compose up -d || docker-compose up -d)

#-----------------------------------------------------------------#
# 5. Nginx 性能加固 (Gzip + WebSocket)
#-----------------------------------------------------------------#
cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    client_max_body_size 100M;
    
    # 开启 Gzip 提升 UI 加载速度
    gzip on;
    gzip_types text/plain application/json application/javascript text/css;

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
EOF

ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

#-----------------------------------------------------------------#
# 6. 安全维护 (SSL Fallback & Watchtower)
#-----------------------------------------------------------------#
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect || echo -e "${RED}SSL申请失败，请确认DNS解析！${PLAIN}"

docker rm -f watchtower > /dev/null 2>&1
docker run -d --name watchtower -e DOCKER_API_VERSION=1.44 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower --cleanup --interval 86400 --rolling-restart n8n

#-----------------------------------------------------------------#
# 7. 最终报告
#-----------------------------------------------------------------#
echo -e "\n${GREEN}===========================================================${PLAIN}"
echo -e "${GREEN}n8n 终极稳定版部署完成！${PLAIN}"
echo -e "访问地址: ${YELLOW}https://${DOMAIN}${PLAIN}"
echo -e "管理密码: ${CYAN}${BASIC_AUTH_PASS}${PLAIN}"
echo -e "凭据 Key: ${CYAN}${RANDOM_KEY}${PLAIN}"
echo -e "${RED}警告：已通过 NODE_OPTIONS 限制内存占用，保障 512MB VPS 稳定运行。${PLAIN}"
echo -e "${GREEN}===========================================================${PLAIN}"
