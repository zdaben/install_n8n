#!/bin/bash
#=================================================================#
#  System Required: Debian 12+                                    #
#  Description: n8n Production Deployment & Maintenance Script    #
#  Version: V5.5 (Auto-Inherit Config, Backups, Fail-Fast)        #
#=================================================================#

set -e # 开启 Fail-Fast

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

N8N_DIR="$HOME/n8n"
DOCKER_COMPOSE_CMD=""
DOMAIN=""
EMAIL=""
N8N_PORT=""
RANDOM_KEY=""
BASIC_AUTH_PASS=""

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：必须使用 root 用户运行。${PLAIN}"
        exit 1
    fi
}

init_docker_compose() {
    if command -v docker compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo -e "${YELLOW}尚未安装 Docker Compose，将由依赖模块处理。${PLAIN}"
    fi
}

install_dependencies() {
    echo -e "${GREEN}检查并安装系统依赖...${PLAIN}"
    apt update && apt install -y curl vim nginx certbot python3-certbot-nginx jq tar cron dnsutils iproute2
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh || true
        apt install -y docker-compose-plugin
        systemctl enable --now docker
    fi
    init_docker_compose
}

setup_swap() {
    MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}' || true)
    SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}' || true)
    if [ "$MEM_TOTAL" -le 2048 ] && [ "$SWAP_TOTAL" -eq 0 ] && [ ! -f /swapfile ]; then
        echo -e "${GREEN}配置虚拟内存 (Swap)...${PLAIN}"
        [ "$MEM_TOTAL" -le 600 ] && SWAP_SIZE_MB=2048 || SWAP_SIZE_MB=1024
        if ! fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null; then
            dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB}
        fi
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    fi
}

# V5.5 核心机制：旧配置提取
extract_existing_config() {
    if [ -f "${N8N_DIR}/docker-compose.yml" ]; then
        echo -e "${YELLOW}检测到已有 n8n 部署，正在提取历史配置...${PLAIN}"
        EXISTING_DOMAIN=$(grep -E 'N8N_HOST=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"' | tr -d '\r' || true)
        EXISTING_KEY=$(grep -E 'N8N_ENCRYPTION_KEY=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"' | tr -d '\r' || true)
        EXISTING_PASS=$(grep -E 'N8N_BASIC_AUTH_PASSWORD=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"' | tr -d '\r' || true)
        EXISTING_PORT=$(grep -E '127.0.0.1:' "${N8N_DIR}/docker-compose.yml" | awk -F':' '{print $2}' || true)
        
        if [ -n "$EXISTING_KEY" ]; then
            echo -e "${GREEN}成功继承原加密密钥，确保凭据不丢失。${PLAIN}"
            DOMAIN=${EXISTING_DOMAIN}
            RANDOM_KEY=${EXISTING_KEY}
            BASIC_AUTH_PASS=${EXISTING_PASS}
            N8N_PORT=${EXISTING_PORT}
        fi
    fi
}

setup_n8n_config() {
    extract_existing_config

    if [ -z "$DOMAIN" ]; then
        read -p "请输入域名 (默认: ema.ink): " INPUT_DOMAIN
        DOMAIN=${INPUT_DOMAIN:-"ema.ink"}
        read -p "请输入邮箱 (用于 SSL): " INPUT_EMAIL
        EMAIL=${INPUT_EMAIL:-"admin@${DOMAIN}"}
        read -p "请输入 n8n 运行端口 (默认: 5678): " INPUT_PORT
        N8N_PORT=${INPUT_PORT:-5678}
        RANDOM_KEY=$(tr -dc 'a-z0-9' </dev/urandom | head -c 32)
        BASIC_AUTH_PASS=$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)
    else
        EMAIL="admin@${DOMAIN}"
        echo -e "${GREEN}使用继承配置: 域名 ${CYAN}${DOMAIN}${GREEN}, 端口 ${CYAN}${N8N_PORT}${PLAIN}"
    fi

    # 端口检测 (仅针对新装或端口变更的情况)
    if ss -tuln | awk '{print $5}' | grep -E -q ":${N8N_PORT}$" && [ ! -f "${N8N_DIR}/docker-compose.yml" ]; then
        echo -e "${RED}错误：端口 ${N8N_PORT} 已被占用！${PLAIN}"
        exit 1
    fi

    mkdir -p "${N8N_DIR}/n8n_data" "${N8N_DIR}/n8n_files"
    chown -R 1000:1000 "${N8N_DIR}/n8n_data" "${N8N_DIR}/n8n_files"

    cat > "${N8N_DIR}/docker-compose.yml" <<EOF
services:
  n8n:
    image: blowsnow/n8n-chinese:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:5678 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
    environment:
      - TZ=Asia/Shanghai
      - NODE_OPTIONS=--max-old-space-size=512
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_WEBHOOK_URL=https://${DOMAIN}/
      - N8N_EDITOR_BASE_URL=https://${DOMAIN}/
      - GENERIC_TIMEZONE=Asia/Shanghai
      - N8N_DEFAULT_LOCALE=zh-CN
      - N8N_ENCRYPTION_KEY=${RANDOM_KEY}
      - N8N_METRICS=true
      - N8N_PAYLOAD_SIZE_MAX=100
      - N8N_BINARY_DATA_MODE=filesystem
      - N8N_BINARY_DATA_STORAGE_PATH=/files
      - EXECUTIONS_MODE=regular
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=72
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=20000
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=${BASIC_AUTH_PASS}
    volumes:
      - ./n8n_data:/home/node/.n8n
      - ./n8n_files:/files
EOF

    cd "${N8N_DIR}" || exit 1
    $DOCKER_COMPOSE_CMD pull
    $DOCKER_COMPOSE_CMD up -d
}

setup_nginx() {
    echo -e "${GREEN}配置 Nginx 反向代理...${PLAIN}"
    rm -f /etc/nginx/sites-enabled/default || true

    cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    server_tokens off;
    client_max_body_size 100M;
    
    gzip on;
    gzip_types text/plain application/json application/javascript text/css;

    location / {
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        proxy_buffering off;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
}

setup_ssl() {
    echo -e "${GREEN}配置 SSL 与 Watchtower...${PLAIN}"
    DNS_CHECK=$(dig +short ${DOMAIN} || true)
    if [ -z "$DNS_CHECK" ]; then
        echo -e "${YELLOW}警告：域名 ${DOMAIN} 未检测到解析记录。若使用 Cloudflare 代理可能误报，继续执行...${PLAIN}"
    fi

    certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect || echo -e "${YELLOW}SSL 申请跳过或异常（若已有证书请忽略）。${PLAIN}"

    docker rm -f watchtower > /dev/null 2>&1 || true
    docker run -d --name watchtower --restart unless-stopped \
      -e DOCKER_API_VERSION=1.44 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      containrrr/watchtower --cleanup --interval 86400 --rolling-restart n8n
}

setup_backup() {
    echo -e "${GREEN}配置每日自动化备份任务...${PLAIN}"
    cat > /root/n8n_backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR=/root/n8n_backup
mkdir -p $BACKUP_DIR
tar czf $BACKUP_DIR/n8n_$(date +%F).tar.gz /root/n8n/n8n_data /root/n8n/n8n_files
find $BACKUP_DIR -mtime +7 -delete
EOF
    chmod +x /root/n8n_backup.sh
    (crontab -l 2>/dev/null | grep -v "/root/n8n_backup.sh"; echo "0 3 * * * bash /root/n8n_backup.sh") | crontab - || true
}

update_n8n() {
    echo -e "${GREEN}执行智能版本更新...${PLAIN}"
    cd "${N8N_DIR}" || { echo -e "${RED}未找到目录。${PLAIN}"; exit 1; }
    init_docker_compose
    
    LATEST_VERSION=$(curl -sL "https://registry.hub.docker.com/v2/repositories/blowsnow/n8n-chinese/tags?page_size=100" | jq -r '.results[].name' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sort -V | tail -n 1 || true)
    
    [ -z "$LATEST_VERSION" ] && LATEST_VERSION="latest" || echo -e "云端最新版本: ${CYAN}${LATEST_VERSION}${PLAIN}"

    read -p "请输入目标版本号 [默认: ${LATEST_VERSION}]: " INPUT_VERSION
    TARGET_VERSION=${INPUT_VERSION:-$LATEST_VERSION}

    sed -i "s|image: blowsnow/n8n-chinese:.*|image: blowsnow/n8n-chinese:${TARGET_VERSION}|g" "${N8N_DIR}/docker-compose.yml"

    $DOCKER_COMPOSE_CMD pull
    $DOCKER_COMPOSE_CMD up -d
    docker image prune -f
    echo -e "${GREEN}更新完毕，当前版本: ${CYAN}${TARGET_VERSION}${PLAIN}"
    exit 0
}

main() {
    check_root
    if [ "${1:-}" == "update" ]; then
        update_n8n
    fi

    install_dependencies
    setup_swap
    setup_n8n_config
    setup_nginx
    setup_ssl
    setup_backup

    echo -e "\n${GREEN}===========================================================${PLAIN}"
    echo -e "系统环境升级至 v5.5 架构完成。"
    echo -e "管理地址: ${YELLOW}https://${DOMAIN}${PLAIN}"
    echo -e "当前密钥: ${CYAN}${RANDOM_KEY}${PLAIN} (已从旧配置继承)"
    echo -e "新增功能: 每日凌晨3点全量备份 (/root/n8n_backup)、Nginx 超时保活防断连"
    echo -e "${GREEN}===========================================================${PLAIN}"
}

main "$@"
