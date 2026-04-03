#!/bin/bash
#=================================================================#
#  System Required: Debian 12+                                    #
#  Description: n8n Global CLI Management Tool (V7.0)             #
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
DOCKER_COMPOSE_CMD="docker compose"

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行。${PLAIN}" && exit 1
}

init_docker_compose() {
    if ! command -v docker compose &> /dev/null && command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    fi
}

# ==========================================
# 核心功能 1：安装与初始化 (install)
# ==========================================
cmd_install() {
    echo -e "${GREEN}==> 开始执行 n8n 安装...${PLAIN}"
    apt update && apt install -y curl vim nginx certbot python3-certbot-nginx jq tar cron dnsutils iproute2
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh || true
        apt install -y docker-compose-plugin
        systemctl enable --now docker
        rm -f get-docker.sh
    fi
    init_docker_compose

    # Swap 检测
    MEM_TOTAL=$(free -m | awk '/Mem/{print $2}')
    SWAP_TOTAL=$(free -m | awk '/Swap/{print $2}')
    if [ "$MEM_TOTAL" -le 2048 ] && [ "$SWAP_TOTAL" -eq 0 ] && [ ! -f /swapfile ]; then
        echo -e "${GREEN}==> 正在配置 Swap...${PLAIN}"
        [ "$MEM_TOTAL" -le 600 ] && SWAP_SIZE_MB=2048 || SWAP_SIZE_MB=1024
        fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB}
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    fi

    mkdir -p "${N8N_DIR}/n8n_data" "${N8N_DIR}/n8n_files" "${BACKUP_DIR}"
    chown -R 1000:1000 "${N8N_DIR}/n8n_data" "${N8N_DIR}/n8n_files"

    # 配置继承或新建
    if [ -f "${N8N_DIR}/docker-compose.yml" ]; then
        echo -e "${YELLOW}检测到历史配置，自动继承...${PLAIN}"
        DOMAIN=$(grep -E 'N8N_HOST=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || true)
        RANDOM_KEY=$(grep -E 'N8N_ENCRYPTION_KEY=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || true)
        BASIC_AUTH_PASS=$(grep -E 'N8N_BASIC_AUTH_PASSWORD=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r' || true)
        N8N_PORT=$(grep -E '127.0.0.1:' "${N8N_DIR}/docker-compose.yml" | awk -F':' '{print $2}' || true)
    fi

    if [ -z "$DOMAIN" ]; then
        read -p "请输入域名 (默认: ema.ink): " DOMAIN; DOMAIN=${DOMAIN:-"ema.ink"}
        EMAIL="admin@${DOMAIN}"
        read -p "请输入运行端口 (默认: 5678): " N8N_PORT; N8N_PORT=${N8N_PORT:-5678}
        RANDOM_KEY=$(tr -dc 'a-z0-9' </dev/urandom | head -c 32)
        BASIC_AUTH_PASS=$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)
    fi

    # 获取最新汉化包与版本
    echo -e "${GREEN}==> 获取最新汉化补丁...${PLAIN}"
    LATEST_API=$(curl -sL "https://api.github.com/repos/other-blowsnow/n8n-i18n-chinese/releases/latest" || true)
    LATEST_VERSION=$(echo "$LATEST_API" | jq -r '.tag_name' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    [ -z "$LATEST_VERSION" ] && LATEST_VERSION="2.14.2"
    
    echo -e "云端最新版本: ${CYAN}${LATEST_VERSION}${PLAIN}"
    read -p "请输入要部署的版本号 [默认: ${LATEST_VERSION}]: " TARGET_VERSION
    TARGET_VERSION=${TARGET_VERSION:-$LATEST_VERSION}

    DL_URL="https://github.com/other-blowsnow/n8n-i18n-chinese/releases/download/n8n%40${TARGET_VERSION}/editor-ui.tar.gz"
    mkdir -p "${N8N_DIR}/n8n_ui"
    if curl -sLf -o /tmp/editor-ui.tar.gz "$DL_URL"; then
        rm -rf "${N8N_DIR}/n8n_ui/dist"
        tar -xzf /tmp/editor-ui.tar.gz -C "${N8N_DIR}/n8n_ui"
        chown -R 1000:1000 "${N8N_DIR}/n8n_ui"
        rm -f /tmp/editor-ui.tar.gz
    else
        echo -e "${RED}无法下载汉化补丁！${PLAIN}" && exit 1
    fi

    # 生成 docker-compose
    cat > "${N8N_DIR}/docker-compose.yml" <<EOF
services:
  n8n:
    image: n8nio/n8n:${TARGET_VERSION}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    logging:
      driver: "json-file"
      options: { max-size: "50m", max-file: "5" }
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
      - ./n8n_ui/dist:/usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist
EOF

    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD pull && $DOCKER_COMPOSE_CMD up -d

    # Nginx 配置
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

    # SSL & 定时备份
    certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect || true
    # 注入系统的 /usr/local/bin/n8n 作为执行体
    (crontab -l 2>/dev/null | grep -v "n8n backup"; echo "0 3 * * * /usr/local/bin/n8n backup > /dev/null 2>&1") | crontab - || true

    echo -e "\n${GREEN}===========================================================${PLAIN}"
    echo -e "n8n 部署完毕！"
    echo -e "管理地址: ${YELLOW}https://${DOMAIN}${PLAIN}"
    echo -e "初始密码: ${CYAN}${BASIC_AUTH_PASS}${PLAIN} (默认账号: admin)"
    echo -e "加密密钥: ${CYAN}${RANDOM_KEY}${PLAIN}"
    echo -e "命令提示: 您可随时使用 ${CYAN}n8n status${PLAIN} 或 ${CYAN}n8n backup${PLAIN} 进行管理。"
    echo -e "${GREEN}===========================================================${PLAIN}"
}

# ==========================================
# 核心功能 2：版本更新 (update)
# ==========================================
cmd_update() {
    check_root
    init_docker_compose
    echo -e "${GREEN}==> 正在连接云端检查更新...${PLAIN}"
    LATEST_API=$(curl -sL "https://api.github.com/repos/other-blowsnow/n8n-i18n-chinese/releases/latest" || true)
    LATEST_VERSION=$(echo "$LATEST_API" | jq -r '.tag_name' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    [ -z "$LATEST_VERSION" ] && LATEST_VERSION="latest"
    
    echo -e "可更新的云端最新版本: ${CYAN}${LATEST_VERSION}${PLAIN}"
    read -p "请输入目标版本号 [默认: ${LATEST_VERSION}]: " TARGET_VERSION
    TARGET_VERSION=${TARGET_VERSION:-$LATEST_VERSION}

    DL_URL="https://github.com/other-blowsnow/n8n-i18n-chinese/releases/download/n8n%40${TARGET_VERSION}/editor-ui.tar.gz"
    echo -e "${GREEN}==> 下载汉化补丁...${PLAIN}"
    if curl -sLf -o /tmp/editor-ui.tar.gz "$DL_URL"; then
        rm -rf "${N8N_DIR}/n8n_ui/dist" && tar -xzf /tmp/editor-ui.tar.gz -C "${N8N_DIR}/n8n_ui"
        chown -R 1000:1000 "${N8N_DIR}/n8n_ui" && rm -f /tmp/editor-ui.tar.gz
    else
        echo -e "${RED}补丁下载失败，中断更新。${PLAIN}" && exit 1
    fi

    sed -i "s|image: n8nio/n8n:.*|image: n8nio/n8n:${TARGET_VERSION}|g" "${N8N_DIR}/docker-compose.yml"
    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD pull && $DOCKER_COMPOSE_CMD up -d
    docker image prune -f
    echo -e "${GREEN}==> n8n 成功更新至 ${CYAN}${TARGET_VERSION}${PLAIN}"
}

# ==========================================
# 核心功能 3：状态监控 (status / top)
# ==========================================
cmd_status() {
    echo -e "${CYAN}--- 容器运行状态 ---${PLAIN}"
    docker ps -f name=n8n
    echo -e "\n${CYAN}--- 实时资源占用 (Ctrl+C 退出) ---${PLAIN}"
    docker stats n8n
}

# ==========================================
# 核心功能 4：系统重启 (restart)
# ==========================================
cmd_restart() {
    init_docker_compose
    echo -e "${GREEN}==> 正在重启 n8n 服务...${PLAIN}"
    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD restart
    echo -e "${GREEN}重启完成。${PLAIN}"
}

# ==========================================
# 核心功能 5：手动备份 (backup)
# ==========================================
cmd_backup() {
    echo -e "${GREEN}==> 开始打包备份数据...${PLAIN}"
    mkdir -p "${BACKUP_DIR}"
    BACKUP_FILE="${BACKUP_DIR}/n8n_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    cd "${N8N_DIR}"
    tar czf "${BACKUP_FILE}" n8n_data n8n_files
    
    find "${BACKUP_DIR}" -name "n8n_backup_*.tar.gz" -mtime +7 -delete
    
    FILE_SIZE=$(du -h "${BACKUP_FILE}" | awk '{print $1}')
    echo -e "${GREEN}备份成功！${PLAIN}"
    echo -e "文件路径: ${CYAN}${BACKUP_FILE}${PLAIN}"
    echo -e "文件大小: ${YELLOW}${FILE_SIZE}${PLAIN}"
}

# ==========================================
# 核心功能 6：灾难恢复 (recover)
# ==========================================
cmd_recover() {
    init_docker_compose
    set +e 
    echo -e "${CYAN}=== n8n 数据恢复向导 ===${PLAIN}"
    
    if [ ! -d "${BACKUP_DIR}" ] || [ -z "$(ls -A ${BACKUP_DIR}/n8n_backup_*.tar.gz 2>/dev/null)" ]; then
        echo -e "${RED}未在 ${BACKUP_DIR} 找到任何备份文件！${PLAIN}"
        exit 1
    fi

    echo -e "检测到以下备份文件："
    ls -lh "${BACKUP_DIR}"/n8n_backup_*.tar.gz | awk '{print NR". "$9" ("$5")"}' | sed "s|${BACKUP_DIR}/||"
    
    echo ""
    read -p "请输入要恢复的备份编号 (输入 0 退出): " SELECT_INDEX
    [ "$SELECT_INDEX" -eq 0 ] && exit 0

    SELECTED_FILE=$(ls "${BACKUP_DIR}"/n8n_backup_*.tar.gz | sed -n "${SELECT_INDEX}p")
    
    if [ -z "$SELECTED_FILE" ]; then
        echo -e "${RED}输入有误，操作取消。${PLAIN}"
        exit 1
    fi

    echo -e "${YELLOW}警告：此操作将覆盖当前的 n8n_data 和 n8n_files 目录！${PLAIN}"
    read -p "确定要继续吗？(y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}==> 正在停止 n8n 服务...${PLAIN}"
        cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD down
        
        echo -e "${GREEN}==> 正在清空旧数据并解压备份...${PLAIN}"
        rm -rf n8n_data n8n_files
        tar xzf "${SELECTED_FILE}" -C "${N8N_DIR}"
        chown -R 1000:1000 n8n_data n8n_files
        
        echo -e "${GREEN}==> 正在重启服务...${PLAIN}"
        $DOCKER_COMPOSE_CMD up -d
        echo -e "${GREEN}恢复完成！${PLAIN}"
    else
        echo -e "已取消。"
    fi
}

# ==========================================
# 路由匹配
# ==========================================
case "$1" in
    install)  cmd_install ;;
    update)   cmd_update ;;
    status|top) cmd_status ;;
    restart)  cmd_restart ;;
    backup)   cmd_backup ;;
    recover)  cmd_recover ;;
    *)
        echo -e "${CYAN}n8n 全局 CLI 管理工具 (V7.0)${PLAIN}"
        echo -e "用法: ${GREEN}n8n [选项]${PLAIN}"
        echo -e "选项:"
        echo -e "  ${YELLOW}install${PLAIN}   - 全新安装、环境修复或重置配置"
        echo -e "  ${YELLOW}update${PLAIN}    - 一键拉取最新官版镜像与汉化补丁"
        echo -e "  ${YELLOW}status${PLAIN}    - 查看容器运行状态及实时资源占用 (同 top)"
        echo -e "  ${YELLOW}restart${PLAIN}   - 优雅重启 n8n 容器服务"
        echo -e "  ${YELLOW}backup${PLAIN}    - 立即执行全量冷备份 (保留最近7天)"
        echo -e "  ${YELLOW}recover${PLAIN}   - 交互式控制台，从历史备份中回档数据"
        ;;
esac
