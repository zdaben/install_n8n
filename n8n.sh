#!/bin/bash
#=================================================================#
#  System Required: Debian 12+                                    #
#  Description: n8n CLI Management Tool                           #
#  Author: zdaben                                                 #
#=================================================================#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

N8N_DIR="/root/n8n"
BACKUP_DIR="${N8N_DIR}/backup"
DOCKER_COMPOSE_CMD=""

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：必须使用 root 用户运行。${PLAIN}"
        exit 1
    fi
}

init_docker_compose() {
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo -e "${RED}错误：Docker Compose 未安装或无法运行。${PLAIN}"
        exit 1
    fi
}

cmd_show_panel() {
    if [ ! -f "${N8N_DIR}/docker-compose.yml" ]; then
        echo -e "${YELLOW}n8n 尚未配置，请执行 n8n install 开始。${PLAIN}"
        exit 0
    fi
    
    local DOMAIN=$(grep -E 'N8N_HOST=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || echo "未知")
    local PASS=$(grep -E 'N8N_BASIC_AUTH_PASSWORD=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || echo "未知")
    local KEY=$(grep -E 'N8N_ENCRYPTION_KEY=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || echo "未知")
    
    local PORT=$(grep -oE '127\.0\.0\.1:[0-9]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 | head -n 1 || true)
    if [ -z "$PORT" ]; then
        PORT="5678"
    fi

    echo -e "\n${GREEN}===========================================================${PLAIN}"
    echo -e "${GREEN}n8n 管理面板${PLAIN}"
    echo -e "-----------------------------------------------------------"
    echo -e "访问地址: ${YELLOW}https://${DOMAIN}${PLAIN}"
    echo -e "管理账号: ${CYAN}admin${PLAIN}"
    echo -e "管理密码: ${CYAN}${PASS}${PLAIN}"
    echo -e "加密密钥: ${CYAN}${KEY}${PLAIN} ${YELLOW}(务必妥善保存)${PLAIN}"
    echo -e "映射端口: ${CYAN}${PORT}${PLAIN}"
    echo -e "-----------------------------------------------------------"
    echo -e "${GREEN}命令列表:${PLAIN}"
    echo -e "  ${YELLOW}n8n status${PLAIN}    - 查看服务状态与资源占用"
    echo -e "  ${YELLOW}n8n top${PLAIN}       - 查看实时资源监控"
    echo -e "  ${YELLOW}n8n update${PLAIN}    - 更新官方引擎与汉化补丁"
    echo -e "  ${YELLOW}n8n restart${PLAIN}   - 重启容器服务"
    echo -e "  ${YELLOW}n8n backup${PLAIN}    - 执行数据与配置备份"
    echo -e "  ${YELLOW}n8n recover${PLAIN}   - 从历史备份恢复"
    echo -e "  ${YELLOW}n8n install${PLAIN}   - 安装或修改配置"
    echo -e "  ${RED}n8n uninstall${PLAIN} - 卸载并清理数据"
    echo -e "-----------------------------------------------------------"
    echo -e "数据目录: ${CYAN}${N8N_DIR}${PLAIN}"
    echo -e "${GREEN}===========================================================${PLAIN}"
}

cmd_install() {
    check_root
    echo -e "${GREEN}==> 准备环境与依赖...${PLAIN}"
    apt update && apt install -y curl vim nginx certbot python3-certbot-nginx jq tar cron dnsutils iproute2 util-linux
    
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh || true
        apt install -y docker-compose-plugin
        systemctl enable --now docker
        rm -f get-docker.sh
    fi
    init_docker_compose

    MEM_TOTAL=$(free -m | awk '/Mem/{print $2}')
    if [ "$MEM_TOTAL" -le 2048 ] && [ ! -f /swapfile ]; then
        echo -e "${GREEN}==> 配置虚拟内存...${PLAIN}"
        if [ "$MEM_TOTAL" -le 600 ]; then
            SWAP_SIZE_MB=2048
        else
            SWAP_SIZE_MB=1024
        fi
        fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB}
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab || true
    fi

    mkdir -p "${N8N_DIR}/n8n_data" "${N8N_DIR}/n8n_files" "${BACKUP_DIR}"
    chown -R 1000:1000 "${N8N_DIR}/n8n_data" "${N8N_DIR}/n8n_files"

    local OLD_DOMAIN="" OLD_PORT="" OLD_KEY="" OLD_PASS=""
    if [ -f "${N8N_DIR}/docker-compose.yml" ]; then
        OLD_DOMAIN=$(grep -E 'N8N_HOST=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || true)
        OLD_KEY=$(grep -E 'N8N_ENCRYPTION_KEY=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || true)
        OLD_PASS=$(grep -E 'N8N_BASIC_AUTH_PASSWORD=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || true)
        OLD_PORT=$(grep -oE '127\.0\.0\.1:[0-9]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 | head -n 1 || true)
    fi

    read -p "请输入域名 (默认: ${OLD_DOMAIN:-ema.ink}): " INPUT_DOMAIN
    DOMAIN=${INPUT_DOMAIN:-${OLD_DOMAIN:-"ema.ink"}}
    read -p "请输入邮箱 (默认: admin@${DOMAIN}): " INPUT_EMAIL
    EMAIL=${INPUT_EMAIL:-"admin@${DOMAIN}"}
    read -p "请输入宿主机端口 (默认: ${OLD_PORT:-5678}): " INPUT_PORT
    N8N_PORT=${INPUT_PORT:-${OLD_PORT:-5678}}

    RANDOM_KEY=${OLD_KEY:-$(tr -dc 'a-z0-9' </dev/urandom | head -c 32)}
    BASIC_AUTH_PASS=${OLD_PASS:-$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)}

    echo -e "${GREEN}==> 检测 DNS 解析...${PLAIN}"
    SERVER_IP=$(curl -s4 ifconfig.me || true)
    DNS_IP=$(dig +short "$DOMAIN" | tail -n1 || true)
    if [ -n "$SERVER_IP" ] && [ -n "$DNS_IP" ] && [ "$SERVER_IP" != "$DNS_IP" ]; then
        echo -e "${YELLOW}提示：域名解析 IP ($DNS_IP) 与本机 IP ($SERVER_IP) 不一致。${PLAIN}"
        echo -e "如使用 CDN 代理，此为正常现象。"
        read -p "是否继续？(y/n) [默认: y]: " FORCE_DNS
        if [[ "$FORCE_DNS" =~ ^[Nn]$ ]]; then
            echo "已终止。"
            exit 1
        fi
    fi

    LATEST_API=$(curl -sL "https://api.github.com/repos/other-blowsnow/n8n-i18n-chinese/releases/latest" || true)
    TARGET_VERSION=$(echo "$LATEST_API" | jq -r '.tag_name' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "2.14.2")

    mkdir -p "${N8N_DIR}/n8n_ui"
    DL_URL="https://github.com/other-blowsnow/n8n-i18n-chinese/releases/download/n8n%40${TARGET_VERSION}/editor-ui.tar.gz"
    if curl -sLf -o /tmp/editor-ui.tar.gz "$DL_URL"; then
        rm -rf "${N8N_DIR}/n8n_ui/dist" && tar -xzf /tmp/editor-ui.tar.gz -C "${N8N_DIR}/n8n_ui"
        chown -R 1000:1000 "${N8N_DIR}/n8n_ui" && rm -f /tmp/editor-ui.tar.gz
    fi

    cat > "${N8N_DIR}/docker-compose.yml" <<EOF
services:
  n8n:
    image: n8nio/n8n:${TARGET_VERSION}
    container_name: n8n
    restart: unless-stopped
    ports: ["127.0.0.1:${N8N_PORT}:5678"]
    logging:
      driver: "json-file"
      options: { max-size: "50m", max-file: "5" }
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
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
      - N8N_BINARY_DATA_MODE=filesystem
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=72
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=20000
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=${BASIC_AUTH_PASS}
    volumes:
      - ./n8n_data:/home/node/.n8n
      - ./n8n_files:/files
      - ./n8n_ui/dist:/usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist
EOF

    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD pull && $DOCKER_COMPOSE_CMD up -d

    rm -f /etc/nginx/sites-enabled/default || true
    cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    server_tokens off;
    client_max_body_size 100M;
    
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy strict-origin-when-cross-origin;

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

    echo -e "${GREEN}==> 配置 SSL 证书...${PLAIN}"
    certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect --keep-until-expiring || echo -e "${YELLOW}警告：SSL 配置异常，请后续手动执行 certbot --nginx 修复。${PLAIN}"
    
    (crontab -l 2>/dev/null | grep -v "n8n backup"; echo "0 3 * * * /usr/local/bin/n8n backup > /dev/null 2>&1") | crontab - || true

    cmd_show_panel
}

cmd_update() {
    check_root; init_docker_compose
    echo -e "${GREEN}==> 检测版本信息...${PLAIN}"
    
    local CURRENT_VERSION=$(grep -oE 'n8nio/n8n:[a-zA-Z0-9.-]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 || echo "未知")
    echo -e "当前本地版本: ${CYAN}${CURRENT_VERSION}${PLAIN}"

    echo "正在拉取云端最新稳定版信息..."
    local LATEST_API=$(curl -sL "https://api.github.com/repos/other-blowsnow/n8n-i18n-chinese/releases/latest" || true)
    local TARGET_VERSION=$(echo "$LATEST_API" | jq -r '.tag_name' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "latest")
    echo -e "云端最新稳定版: ${YELLOW}${TARGET_VERSION}${PLAIN}"

    if [ "$CURRENT_VERSION" == "$TARGET_VERSION" ] && [ "$CURRENT_VERSION" != "未知" ]; then
        echo -e "\n${GREEN}当前已经是最新稳定版本，无需更新。${PLAIN}"
        read -p "是否强制重新拉取并覆盖安装？(y/n) [默认: n]: " FORCE_UPDATE
        if [[ ! "$FORCE_UPDATE" =~ ^[Yy]$ ]]; then
            echo "已取消更新。"
            exit 0
        fi
    fi

    echo ""
    read -p "请输入要更新的目标版本号 [默认: ${TARGET_VERSION}]: " IV
    TARGET_VERSION=${IV:-$TARGET_VERSION}

    echo -e "${GREEN}==> 开始下载并更新至 ${TARGET_VERSION}...${PLAIN}"
    DL_URL="https://github.com/other-blowsnow/n8n-i18n-chinese/releases/download/n8n%40${TARGET_VERSION}/editor-ui.tar.gz"
    
    if curl -sLf -o /tmp/editor-ui.tar.gz "$DL_URL"; then
        rm -rf "${N8N_DIR}/n8n_ui/dist" && tar -xzf /tmp/editor-ui.tar.gz -C "${N8N_DIR}/n8n_ui"
        chown -R 1000:1000 "${N8N_DIR}/n8n_ui" && rm -f /tmp/editor-ui.tar.gz
    else
        echo -e "${YELLOW}警告: 未找到该版本的汉化补丁，可能导致 UI 资源缺失。系统将继续仅更新 n8n 官方引擎。${PLAIN}"
    fi
    
    sed -i "s|image: n8nio/n8n:.*|image: n8nio/n8n:${TARGET_VERSION}|g" "${N8N_DIR}/docker-compose.yml"
    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD pull && $DOCKER_COMPOSE_CMD up -d
    
    docker image prune -f
    echo -e "${GREEN}更新完成！系统当前已运行版本: ${CYAN}${TARGET_VERSION}${PLAIN}"
}

cmd_backup() {
    echo -e "${GREEN}==> 开始备份数据与配置...${PLAIN}"
    mkdir -p "${BACKUP_DIR}"
    local FILE="${BACKUP_DIR}/n8n_$(date +%Y%m%d_%H%M%S).tar.gz"
    cd "${N8N_DIR}" 
    nice -n 19 ionice -c2 -n7 tar czf "${FILE}" n8n_data n8n_files docker-compose.yml
    find "${BACKUP_DIR}" -name "n8n_*.tar.gz" -mtime +7 -delete
    echo -e "${GREEN}备份完成: ${CYAN}${FILE}${PLAIN}"
}

cmd_recover() {
    init_docker_compose
    echo -e "${CYAN}--- 数据恢复面板 ---${PLAIN}"
    
    # 【修复项】检查目录是否存在，且目录中是否包含有效备份文件
    if [ ! -d "${BACKUP_DIR}" ] || ! ls "${BACKUP_DIR}"/n8n_*.tar.gz 1> /dev/null 2>&1; then
        echo -e "${YELLOW}未找到任何备份归档文件！${PLAIN}"
        exit 1
    fi
    
    ls -lh "${BACKUP_DIR}"/n8n_*.tar.gz | awk '{print NR". "$9" ("$5")"}' | sed "s|${BACKUP_DIR}/||"
    read -p "请选择恢复编号 (输入 0 取消): " IDX
    if [ "$IDX" -eq 0 ]; then
        exit 0
    fi
    
    FILE=$(ls "${BACKUP_DIR}"/n8n_*.tar.gz | sed -n "${IDX}p")
    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD down
    rm -rf n8n_data n8n_files docker-compose.yml
    tar xzf "${FILE}" -C "${N8N_DIR}"
    chown -R 1000:1000 n8n_data n8n_files
    $DOCKER_COMPOSE_CMD up -d
    echo -e "${GREEN}恢复完成。${PLAIN}"
}

cmd_uninstall() {
    check_root
    echo -e "${RED}警告：此操作将删除 n8n 容器、数据、备份文件及 Nginx 配置。${PLAIN}"
    read -p "确认卸载请输入 'yes': " CONFIRM
    if [ "$CONFIRM" == "yes" ]; then
        echo -e "${GREEN}==> 清理数据与容器...${PLAIN}"
        init_docker_compose
        if [ -d "${N8N_DIR}" ]; then
            cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD down -v || true
        fi
        rm -rf "${N8N_DIR}"
        
        echo -e "${GREEN}==> 清理 Nginx 与定时任务...${PLAIN}"
        rm -f /etc/nginx/sites-enabled/n8n /etc/nginx/sites-available/n8n
        systemctl reload nginx || true
        crontab -l | grep -v "n8n backup" | crontab - || true
        
        echo -e "${GREEN}==> 移除命令行工具...${PLAIN}"
        rm -f /usr/local/bin/n8n
        echo -e "${GREEN}卸载完成。${PLAIN}"
    else
        echo "已取消卸载。"
    fi
}

cmd_status() {
    init_docker_compose
    local VERSION=$(grep -oE 'n8nio/n8n:[a-zA-Z0-9.-]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 || echo "未知")
    echo -e "\n${GREEN}▶ n8n 当前运行版本: ${CYAN}${VERSION}${PLAIN}"
    echo -e "-----------------------------------------------------------"
    docker ps -f name=n8n
    echo -e "\n${GREEN}▶ 资源占用情况 (静态快照):${PLAIN}"
    docker stats --no-stream n8n 
}

cmd_top() {
    init_docker_compose
    echo -e "${YELLOW}提示: 正在进入实时监控模式，按 Ctrl+C 退出。${PLAIN}"
    docker stats n8n 
}

case "$1" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    status)    cmd_status ;;
    top)       cmd_top ;;
    restart)   init_docker_compose && cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD restart ;;
    backup)    cmd_backup ;;
    recover)   cmd_recover ;;
    uninstall) cmd_uninstall ;;
    *) cmd_show_panel ;;
esac
