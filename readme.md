🚀 n8n 终极部署方案 (Debian 12 纯净版)
第一阶段：系统加固与内存优化
针对 512MB 内存，必须先建立虚拟内存（Swap），否则处理图片必挂。

Bash

# 更新系统
apt update && apt upgrade -y

# 创建 1GB Swap 虚拟内存
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

# 安装基础依赖
apt install -y curl vim git ufw nginx certbot python3-certbot-nginx
第二阶段：Docker 环境安装
Bash

# 官方一键脚本
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# 设置开机自启
systemctl enable --now docker
第三阶段：目录与权限预设 (核心避坑步)
这是解决 EACCES: permission denied 报错的关键。

Bash

# 创建工作目录
mkdir -p ~/n8n/n8n_data

# 预先授权给容器内的 node 用户 (UID 1000)
chown -R 1000:1000 ~/n8n/n8n_data
chmod -R 775 ~/n8n/n8n_data
第四阶段：配置 docker-compose.yml
cd ~/n8n && vi docker-compose.yml

YAML

services:
  n8n:
    image: blowsnow/n8n-chinese:latest
    container_name: n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=ema.ink
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://ema.ink/
      - GENERIC_TIMEZONE=Asia/Shanghai
      - N8N_DEFAULT_LOCALE=zh-CN
      # --- 小内存深度优化 ---
      - N8N_PAYLOAD_SIZE_MAX=100              # 允许 100MB 附件
      - N8N_BINARY_DATA_MODE=filesystem       # 图片存硬盘，不占内存
      - N8N_BINARY_DATA_STORAGE_PATH=/home/node/.n8n/binaryData
      - EXECUTIONS_DATA_PRUNE=true           # 开启自动清理
      - EXECUTIONS_DATA_MAX_AGE=72           # 仅保留 3 天数据
    volumes:
      - ./n8n_data:/home/node/.n8n
启动服务： docker compose up -d

第五阶段：Nginx 反向代理配置
vi /etc/nginx/sites-available/n8n

Nginx

server {
    listen 80;
    server_name ema.ink;

    # 解决大图上传无响应的核心配置
    client_max_body_size 100M; 

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 支持 WebSocket 实时同步
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_buffering off;
    }
}
激活并生效：

Bash

ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
第六阶段：HTTPS 证书与自动维护
1. 一键申请证书：

Bash

certbot --nginx -d ema.ink
# 选 2 (Redirect) 实现全站加密
2. 开启凌晨 24 点自动更新：

Bash

docker run -d \
  --name watchtower \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower \
  --cleanup \
  --schedule "0 0 0 * * *" \
  n8n
🛠 常用维护指令备忘
查看实时日志：docker logs -f n8n

重启服务：cd ~/n8n && docker compose restart

手动清理内存（如遇卡顿）：sync && echo 3 > /proc/sys/vm/drop_caches

查看磁盘占用：df -h

总结：

这一套配置下来，你的 n8n 具备了自动扩容（Swap）、数据安全（HTTPS）、**大文件支持（100M）以及无人值守更新（Watchtower）**的能力。在 512MB 的 Debian 12 环境下，这已经是目前能做到的最优生产力环境。

恭喜正式入坑 n8n！接下来，如果你想尝试接入 AI 绘图、通知提醒或自动办公，随时叫我。
