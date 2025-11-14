#!/bin.bash

# ==============================================================================
# VPS Monitor Bot 一体化安装脚本
# 作者: Gemini
# 描述: 此脚本将自动安装并配置一个用于监控VPS状态的Telegram机器人。
#       它会创建数据采集脚本和机器人交互脚本，并设置定时任务。
# ==============================================================================

# --- 脚本配置 ---
# 安装目录
INSTALL_DIR="/opt/vps-monitor"
# 日志文件路径
LOG_FILE="/var/log/vps_monitor.log"
# 机器人Screen会话名称
SCREEN_NAME="vpsbot"

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 核心函数 ---

# 检查并安装依赖
check_deps() {
    echo -e "${YELLOW}正在检查系统依赖 (curl, jq, screen)...${NC}"
    DEPS="curl jq screen"
    for dep in $DEPS; do
        if ! command -v $dep &> /dev/null; then
            echo -e "未找到命令: ${dep}。正在尝试安装..."
            if command -v apt-get &> /dev/null; then
                sudo apt-get update > /dev/null && sudo apt-get install -y $dep
            elif command -v yum &> /dev/null; then
                sudo yum install -y epel-release && sudo yum install -y $dep
            else
                echo -e "${RED}无法自动安装 ${dep}。请手动安装后再运行此脚本。${NC}"
                exit 1
            fi
        fi
    done
    echo -e "${GREEN}所有依赖均已满足。${NC}"
}

# 获取用户配置信息
get_user_config() {
    echo "--------------------------------------------------"
    echo "请准备好您的Telegram机器人信息:"
    echo "--------------------------------------------------"
    read -p "请输入 Bot Token: " BOT_TOKEN
    while [ -z "$BOT_TOKEN" ]; do
        echo -e "${RED}Bot Token 不能为空！${NC}"
        read -p "请输入 Bot Token: " BOT_TOKEN
    done

    read -p "请输入您的 Chat ID: " CHAT_ID
    while [ -z "$CHAT_ID" ]; do
        echo -e "${RED}Chat ID 不能为空！${NC}"
        read -p "请输入您的 Chat ID: " CHAT_ID
    done
}

# 创建并配置脚本文件
create_scripts() {
    echo -e "${YELLOW}正在创建安装目录 ${INSTALL_DIR}...${NC}"
    sudo mkdir -p $INSTALL_DIR

    echo -e "${YELLOW}正在生成 monitor.sh 脚本...${NC}"
    # 使用 Here Document 创建 monitor.sh
    # 使用 'EOF' 可以防止本地变量被展开，保持脚本内容的字面量
    sudo tee "${INSTALL_DIR}/monitor.sh" > /dev/null << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/vps_monitor.log"
NET_INTERFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n1)

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
MEM_USED=$(free -m | awk 'NR==2{print $3}')
MEM_TOTAL=$(free -m | awk 'NR==2{print $2}')
DISK_USED=$(df -h / | awk 'NR==2{print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
RX_BYTES=$(cat /proc/net/dev | grep "${NET_INTERFACE}:" | awk '{print $2}')
TX_BYTES=$(cat /proc/net/dev | grep "${NET_INTERFACE}:" | awk '{print $10}')
RX_MB=$((RX_BYTES / 1024 / 1024))
TX_MB=$((TX_BYTES / 1024 / 1024))

echo "{\"timestamp\":\"${TIMESTAMP}\", \"mem_used\":${MEM_USED}, \"mem_total\":${MEM_TOTAL}, \"disk_used\":\"${DISK_USED}\", \"disk_total\":\"${DISK_TOTAL}\", \"net_rx_mb\":${RX_MB}, \"net_tx_mb\":${TX_MB}}" >> ${LOG_FILE}
EOF

    echo -e "${YELLOW}正在生成 bot.sh 脚本...${NC}"
    # 使用 Here Document 创建 bot.sh
    sudo tee "${INSTALL_DIR}/bot.sh" > /dev/null << 'EOF'
#!/bin/bash
BOT_TOKEN="%%BOT_TOKEN%%"
CHAT_ID="%%CHAT_ID%%"
LOG_FILE="/var/log/vps_monitor.log"
URL="https://api.telegram.org/bot${BOT_TOKEN}"
OFFSET=0

sendMessage() {
    # URL编码消息文本
    local encoded_message=$(printf %s "$2" | jq -s -R -r @uri)
    curl -s -X POST "${URL}/sendMessage" -d "chat_id=$1" -d "text=${encoded_message}" -d "parse_mode=MarkdownV2" > /dev/null
}

generateReport() {
    local days="$1"
    local chat_id="$2"
    local title=""
    case "$days" in
        1) title="📊 过去24小时VPS使用报告" ;;
        3) title="📊 过去3天VPS使用报告" ;;
        30) title="📊 过去30天VPS使用报告" ;;
        *) sendMessage "$chat_id" "❌ 无效的参数！请使用 \`/report 1\`, \`/report 3\` 或 \`/report 30\`" ; return ;;
    esac
    
    if [ ! -s "$LOG_FILE" ]; then
        sendMessage "$chat_id" "⚠️ 日志文件为空或不存在，请等待数据采集（每小时一次）。"
        return
    fi
    
    local start_date=$(date -d "-${days} days" "+%Y-%m-%d")
    local relevant_data=$(awk -v start_date="$start_date" '$0 > start_date' "$LOG_FILE")
    if [ -z "$relevant_data" ]; then
        sendMessage "$chat_id" "⚠️ 未找到过去 ${days} 天的数据记录。" ; return
    fi
    local first_record=$(echo "$relevant_data" | head -n 1)
    local last_record=$(echo "$relevant_data" | tail -n 1)
    local mem_used=$(echo "$last_record" | jq .mem_used)
    local mem_total=$(echo "$last_record" | jq .mem_total)
    local mem_percent=$(awk "BEGIN {printf \"%.2f\", ${mem_used} / ${mem_total} * 100}")
    local disk_used=$(echo "$last_record" | jq .disk_used | tr -d '"')
    local disk_total=$(echo "$last_record" | jq .disk_total | tr -d '"')
    local rx_start=$(echo "$first_record" | jq .net_rx_mb)
    local tx_start=$(echo "$first_record" | jq .net_tx_mb)
    local rx_end=$(echo "$last_record" | jq .net_rx_mb)
    local tx_end=$(echo "$last_record" | jq .net_tx_mb)
    local rx_usage=$((rx_end - rx_start))
    local tx_usage=$((tx_end - tx_start))
    local total_usage=$((rx_usage + tx_usage))
    
    # 格式化报告 (注意MarkdownV2的特殊字符需要转义)
    REPORT=$(cat <<EOM
*${title}*

*硬盘使用情况:*
- 已使用: \`${disk_used}\`
- 总容量: \`${disk_total}\`

*内存使用情况 \(当前\):*
- 已使用: \`${mem_used} MB\`
- 总容量: \`${mem_total} MB\`
- 使用率: \`${mem_percent}%\`

*网络流量消耗 \(估算\):*
- 下载 \(RX\): \`${rx_usage} MB\`
- 上传 \(TX\): \`${tx_usage} MB\`
- 总计: \`${total_usage} MB\`

_报告生成于: $(date "+%Y-%m-%d %H:%M:%S")_
EOM
)
    sendMessage "$chat_id" "$REPORT"
}

echo "机器人已启动，正在监听命令..."
while true; do
    RESPONSE=$(curl -s "${URL}/getUpdates?offset=${OFFSET}&limit=1&timeout=60")
    HAS_RESULT=$(echo "$RESPONSE" | jq '.result | length')
    if [ "$HAS_RESULT" -gt 0 ]; then
        MESSAGE=$(echo "$RESPONSE" | jq -r '.result[0].message.text')
        SENDER_ID=$(echo "$RESPONSE" | jq -r '.result[0].message.chat.id')
        UPDATE_ID=$(echo "$RESPONSE" | jq -r '.result[0].update_id')
        OFFSET=$((UPDATE_ID + 1))
        if [ "$SENDER_ID" == "$CHAT_ID" ]; then
            echo "收到来自您的消息: $MESSAGE"
            case "$MESSAGE" in
                "/start") sendMessage "$SENDER_ID" "你好！我是您的VPS监控机器人。\n请使用以下命令获取报告：\n\`/report 1\` \- 获取过去24小时报告\n\`/report 3\` \- 获取过去3天报告\n\`/report 30\` \- 获取过去30天报告" ;;
                "/report 1") generateReport 1 "$SENDER_ID" ;;
                "/report 3") generateReport 3 "$SENDER_ID" ;;
                "/report 30") generateReport 30 "$SENDER_ID" ;;
            esac
        else
            echo "收到来自未授权用户 ($SENDER_ID) 的消息，已忽略。"
        fi
    fi
done
EOF

    echo -e "${YELLOW}正在将您的配置注入脚本...${NC}"
    # 使用sed将用户输入的值替换到bot.sh中的占位符
    sudo sed -i "s|%%BOT_TOKEN%%|${BOT_TOKEN}|g" "${INSTALL_DIR}/bot.sh"
    sudo sed -i "s|%%CHAT_ID%%|${CHAT_ID}|g" "${INSTALL_DIR}/bot.sh"

    echo -e "${YELLOW}正在设置脚本执行权限...${NC}"
    sudo chmod +x "${INSTALL_DIR}/monitor.sh"
    sudo chmod +x "${INSTALL_DIR}/bot.sh"
}

# 设置定时任务和日志文件
setup_environment() {
    echo -e "${YELLOW}正在创建并授权日志文件 ${LOG_FILE}...${NC}"
    sudo touch $LOG_FILE
    sudo chmod 666 $LOG_FILE

    echo -e "${YELLOW}正在设置Cron定时任务（每小时执行一次）...${NC}"
    (sudo crontab -l 2>/dev/null | grep -v "${INSTALL_DIR}/monitor.sh" ; echo "0 * * * * ${INSTALL_DIR}/monitor.sh") | sudo crontab -
    echo -e "${GREEN}Cron定时任务设置成功！${NC}"
}

# 启动机器人后台服务
start_bot() {
    echo -e "${YELLOW}正在后台启动机器人服务...${NC}"
    if screen -list | grep -q "${SCREEN_NAME}"; then
        echo -e "检测到机器人已在运行，正在重启..."
        screen -X -S "${SCREEN_NAME}" quit
    fi
    screen -dmS "${SCREEN_NAME}" "${INSTALL_DIR}/bot.sh"
}

# --- 主程序入口 ---
main() {
    clear
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}    欢迎使用VPS监控机器人一键安装脚本！    ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    
    check_deps
    get_user_config
    create_scripts
    setup_environment
    start_bot
    
    echo ""
    echo -e "${GREEN}==================================================================${NC}"
    echo -e "${GREEN}🎉 恭喜！安装和配置已全部完成！ 🎉${NC}"
    echo ""
    echo "您的机器人现在已在后台的Screen会话中运行。"
    echo "数据采集任务将每小时自动执行一次。"
    echo ""
    echo "➡️  请在Telegram中向您的机器人发送以下命令:"
    echo "    - /report 1  (获取过去24小时报告)"
    echo "    - /report 3  (获取过去3天报告)"
    echo "    - /report 30 (获取过去30天报告)"
    echo ""
    echo "ℹ️  您可以使用 \`${YELLOW}screen -r ${SCREEN_NAME}${NC}\` 命令查看机器人的实时日志。"
    echo "    分离会话请按 ${YELLOW}Ctrl+A${NC} 然后按 ${YELLOW}D${NC}。"
    echo -e "${GREEN}==================================================================${NC}"
}

# 执行主程序
main