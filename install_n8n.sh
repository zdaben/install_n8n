#!/bin/bash
#=================================================================#
#  System Required: Debian 12+                                    #
#  Description: n8n Production Deployment & Maintenance Script    #
#  Version: V5.3 (Port Check, Fail-Fast, DNS Verify, Auto-Backup) #
#=================================================================#

# 开启 Fail Fast，任何未被捕获的非零返回都会导致脚本立刻停止
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 全局变量初始化
N8N_DIR="$HOME/n8n"
DOCKER_COMPOSE_CMD=""
DOMAIN=""
EMAIL=""
N8N_PORT=""
RANDOM_KEY=""
BASIC_AUTH_PASS=""

#-----------------------------------------------------------------#
# 基础环境检测与初始化
#-----------------------------------------------------------------#
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
        echo -e "${YELLOW}尚未安装 Docker Compose，将由依赖安装模块处理。${PLAIN}"
    fi
}

#-----------------------------------------------------------------#
# 核心功能模块
#-----------------------------------------------------------------#
install_dependencies() {
    echo -e "${GREEN}安装系统依赖与 Docker 环境...${PLAIN}"
    # 新增 dnsutils (提供 dig 命令) 和 iproute2 (提供 ss 命令)
    apt update && apt install -y curl vim nginx certbot python3-certbot-nginx jq tar cron dnsutils iproute2
    
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh || true
        apt install -y docker-compose-plugin
        systemctl enable --now docker
    fi
    init_docker_compose
}

setup_swap() {
    # 增加 || true 防止 awk/grep 异常时触发 set -e 导致脚本退出
    MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}' || true)
    SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}' || true)

    if [ "$MEM_TOTAL" -le 2048 ] && [ "$SWAP_TOTAL" -eq 0 ] && [ ! -f /swapfile ]; then
        echo -e "${GREEN}配置虚拟内存 (Swap)...${PLAIN}"
        if [ "$MEM_TOTAL" -le 600 ]; then
            SWAP_SIZE_MB=2048
        else
            SWAP_SIZE_MB=1024
        fi
        
        if ! fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null; then
            dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB}
        fi
        
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    fi
}

setup_n8n_config() {
    # 交互收集配置
    read -p "请输入域名 (默认: ema.ink): " INPUT_DOMAIN
    DOMAIN=${INPUT_DOMAIN:-"ema.ink"}
    
    read -p "请输入邮箱 (用于 SSL): " INPUT_EMAIL
    EMAIL=${INPUT_EMAIL:-"admin@${DOMAIN}"}

    read -p "请输入 n8n 运行端口 (默认: 5678): " INPUT_PORT
    N8N_PORT=${INPUT_PORT:-5678}

    # 端口占用检测
    if ss -tuln | grep -q ":${N8N_PORT} " || true; then
        # 再次严格匹配，确保不是刚好包含了这个数字
        if ss -tuln | awk '{print $5}' | grep -E -q ":${N8N_PORT}$"; then
            echo -e "${RED}错误：端口 ${N8N_PORT} 已被占用，请更换端口或停止占用程序！${PLAIN}"
            exit 1
        fi
    fi

    RANDOM_KEY=$(tr -dc 'a-z0-9' </dev/urandom | head -c 32)
    BASIC_AUTH_PASS=$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)

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

    cd "${N8N_DIR}" || { echo -e "${RED}无法进入目录 ${N8N_DIR}${PLAIN}"; exit 1; }
    $DOCKER_COMPOSE_CMD pull
    $DOCKER_COMPOSE_CMD up -d
}

setup_nginx() {
    echo -e "${GREEN}配置 Nginx 反向代理...${PLAIN}"
    # 删除默认站点，防止请求被截获
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
    echo -e "${GREEN}配置 SSL 证书与 Watchtower...${PLAIN}"
    
    # DNS 预检 (加入 || true 防止 dig 查不到记录时退出脚本)
    DNS_CHECK=$(dig +short ${DOMAIN} || true)
    if [ -z "$DNS_CHECK" ]; then
        echo -e "${RED}检测失败：域名 ${DOMAIN} 未解析到任何 IP，或 DNS 尚未生效。${PLAIN}"
        echo -e "${YELLOW}由于 Let's Encrypt 校验要求严格，必须确保 DNS 解析正确。请配置 DNS 后重试。${PLAIN}"
        exit 1
    fi

    certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect || echo -e "${YELLOW}SSL 申请异常。${PLAIN}"

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
# 同时备份数据库(n8n_data)和附件(n8n_files)
tar czf $BACKUP_DIR/n8n_$(date +%F).tar.gz /root/n8n/n8n_data /root/n8n/n8n_files
find $BACKUP_DIR -mtime +7 -delete
EOF
    chmod +x /root/n8n_backup.sh
    # 注入 Cron 规则，排重防止重复添加
    (crontab -l 2>/dev/null | grep -v "/root/n8n_backup.sh"; echo "0 3 * * * bash /root/n8n_backup.sh") | crontab - || true
}

update_n8n() {
    echo -e "${GREEN}检测版本更新...${PLAIN}"
    cd "${N8N_DIR}" || { echo -e "${RED}未找到安装目录。${PLAIN}"; exit 1; }
    init_docker_compose
    
    # 采用 Docker Hub v2 API 提取纯数字稳定版本号
    LATEST_VERSION=$(curl -sL "https://registry.hub.docker.com/v2/repositories/blowsnow/n8n-chinese/tags?page_size=100" | jq -r '.results[].name' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sort -V | tail -n 1 || true)
    
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}API 获取失败，默认使用 latest 标签。${PLAIN}"
        LATEST_VERSION="latest"
    else
        echo -e "获取到云端最新版本: ${CYAN}${LATEST_VERSION}${PLAIN}"
    fi

    echo ""
    read -p "请输入目标版本号 [直接回车默认: ${LATEST_VERSION}]: " INPUT_VERSION
    TARGET_VERSION=${INPUT_VERSION:-$LATEST_VERSION}

    sed -i "s|image: blowsnow/n8n-chinese:.*|image: blowsnow/n8n-chinese:${TARGET_VERSION}|g" "${N8N_DIR}/docker-compose.yml"

    echo -e "执行镜像拉取与服务重启..."
    $DOCKER_COMPOSE_CMD pull
    $DOCKER_COMPOSE_CMD up -d
    
    # 仅清理未使用的孤立镜像，保护本地其他服务镜像
    docker image prune -f
    
    echo -e "${GREEN}更新完成。当前版本: ${CYAN}${TARGET_VERSION}${PLAIN}"
    exit 0
}

#-----------------------------------------------------------------#
# 主执行入口
#-----------------------------------------------------------------#
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
    echo -e "系统部署完成。"
    echo -e "管理地址: ${YELLOW}https://${DOMAIN}${PLAIN}"
    echo -e "后端端口: ${YELLOW}127.0.0.1:${N8N_PORT}${PLAIN}"
    echo -e "默认账户: ${CYAN}admin${PLAIN}"
    echo -e "默认密码: ${CYAN}${BASIC_AUTH_PASS}${PLAIN}"
    echo -e "凭据密钥: ${CYAN}${RANDOM_KEY}${PLAIN}"
    echo -e "备份目录: /root/n8n_backup (包含数据库与附件，每日保留7天)"
    echo -e "${GREEN}===========================================================${PLAIN}"
}

main "$@"
