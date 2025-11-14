#!/bin/bash

# ==============================================================================
# VPS Monitor Bot 一体化管理脚本
# 作者: Gemini
# 描述: 一个用于监控VPS状态的Telegram机器人。
# ==============================================================================

# --- 脚本配置 ---
INSTALL_DIR="/opt/vps-monitor"
LOG_FILE="/var/log/vps_monitor.log"
SCREEN_NAME="vpsbot"

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==============================================================================
#                           卸载功能
# ==============================================================================
uninstall_bot() {
    echo -e "${YELLOW}开始执行卸载程序...${NC}"
    echo "--------------------------------------------------"

    # 1. 停止机器人后台服务
    echo -n "正在停止机器人服务 (Screen session: ${SCREEN_NAME})... "
    if screen -list | grep -q "${SCREEN_NAME}"; then
        screen -X -S "${SCREEN_NAME}" quit
        echo -e "${GREEN}完成${NC}"
    else
        echo -e "${CYAN}服务未在运行${NC}"
    fi

    # 2. 移除Cron定时任务
    echo -n "正在移除Cron定时任务... "
    (sudo crontab -l 2>/dev/null | grep -v "${INSTALL_DIR}/monitor.sh") | sudo crontab -
    echo -e "${GREEN}完成${NC}"

    # 3. 删除脚本和日志文件
    read -p "$(echo -e ${YELLOW}是否要删除所有相关文件 (${INSTALL_DIR} 和 ${LOG_FILE})？ [y/N]: ${NC})" confirm_delete
    if [[ "$confirm_delete" =~ ^[yY](es)*$ ]]; then
        echo -n "正在删除安装目录 ${INSTALL_DIR}... "
        sudo rm -rf "${INSTALL_DIR}"
        echo -e "${GREEN}完成${NC}"

        echo -n "正在删除日志文件 ${LOG_FILE}... "
        sudo rm -f "${LOG_FILE}"
        echo -e "${GREEN}完成${NC}"
    else
        echo -e "${CYAN}跳过文件删除。${NC}"
    fi

    echo "--------------------------------------------------"
    echo -e "${GREEN}🎉 卸载完成！🎉${NC}"
    echo "系统中的相关组件已被移除。"
}


# ==============================================================================
#                           安装功能
# ==============================================================================
install_bot() {
    echo -e "${YELLOW}开始执行安装程序...${NC}"
    echo "--------------------------------------------------"

    # 检查并安装依赖
    check_deps() {
        echo -e "${CYAN}正在检查系统依赖 (curl, jq, screen)...${NC}"
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

    # 获取用户配置
    get_user_config() {
        echo "请准备好您的Telegram机器人信息:"
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
        echo -e "${CYAN}正在创建安装目录 ${INSTALL_DIR}...${NC}"
        sudo mkdir -p $INSTALL_DIR

        echo -e "${CYAN}正在生成 monitor.sh 脚本...${NC}"
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

        echo -e "${CYAN}正在生成 bot.sh 脚本...${NC}"
        sudo tee "${INSTALL_DIR}/bot.sh" > /dev/null << 'EOF'
#!/bin/bash
BOT_TOKEN="%%BOT_TOKEN%%"
CHAT_ID="%%CHAT_ID%%"
LOG_FILE="/var/log/vps_monitor.log"
URL="https://api.telegram.org/bot${BOT_TOKEN}"
OFFSET=0
sendMessage(){ local encoded_message=$(printf %s "$2"|jq -s -R -r @uri);curl -s -X POST "${URL}/sendMessage" -d "chat_id=$1" -d "text=${encoded_message}" -d "parse_mode=MarkdownV2" >/dev/null;}
generateReport(){ local days="$1";local chat_id="$2";local title="";case "$days" in 1)title="📊 过去24小时VPS使用报告";;3)title="📊 过去3天VPS使用报告";;30)title="📊 过去30天VPS使用报告";;*)sendMessage "$chat_id" "❌ 无效的参数！请使用 \`/report 1\`\, \`/report 3\` 或 \`/report 30\`";return;;esac;if [ ! -s "$LOG_FILE" ];then sendMessage "$chat_id" "⚠️ 日志文件为空或不存在，请等待数据采集（每小时一次）。";return;fi;local start_date=$(date -d "-${days} days" "+%Y-%m-%d");local relevant_data=$(awk -v start_date="$start_date" '$0 > start_date' "$LOG_FILE");if [ -z "$relevant_data" ];then sendMessage "$chat_id" "⚠️ 未找到过去 ${days} 天的数据记录。";return;fi;local first_record=$(echo "$relevant_data"|head -n 1);local last_record=$(echo "$relevant_data"|tail -n 1);local mem_used=$(echo "$last_record"|jq .mem_used);local mem_total=$(echo "$last_record"|jq .mem_total);local mem_percent=$(awk "BEGIN {printf \"%.2f\", ${mem_used} / ${mem_total} * 100}");local disk_used=$(echo "$last_record"|jq .disk_used|tr -d '"');local disk_total=$(echo "$last_record"|jq .disk_total|tr -d '"');local rx_start=$(echo "$first_record"|jq .net_rx_mb);local tx_start=$(echo "$first_record"|jq .net_tx_mb);local rx_end=$(echo "$last_record"|jq .net_rx_mb);local tx_end=$(echo "$last_record"|jq .net_tx_mb);local rx_usage=$((rx_end-rx_start));local tx_usage=$((tx_end-tx_start));local total_usage=$((rx_usage+tx_usage));REPORT=$(cat <<EOM
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
);sendMessage "$chat_id" "$REPORT";}
echo "机器人已启动，正在监听命令...";while true;do RESPONSE=$(curl -s "${URL}/getUpdates?offset=${OFFSET}&limit=1&timeout=60");HAS_RESULT=$(echo "$RESPONSE"|jq '.result|length');if [ "$HAS_RESULT" -gt 0 ];then MESSAGE=$(echo "$RESPONSE"|jq -r '.result[0].message.text');SENDER_ID=$(echo "$RESPONSE"|jq -r '.result[0].message.chat.id');UPDATE_ID=$(echo "$RESPONSE"|jq -r '.result[0].update_id');OFFSET=$((UPDATE_ID+1));if [ "$SENDER_ID" == "$CHAT_ID" ];then echo "收到来自您的消息: $MESSAGE";case "$MESSAGE" in "/start")sendMessage "$SENDER_ID" "你好！我是您的VPS监控机器人。\n请使用以下命令获取报告：\n\`/report 1\` \- 获取过去24小时报告\n\`/report 3\` \- 获取过去3天报告\n\`/report 30\` \- 获取过去30天报告";;"/report 1")generateReport 1 "$SENDER_ID";;"/report 3")generateReport 3 "$SENDER_ID";;"/report 30")generateReport 30 "$SENDER_ID";;esac;else echo "收到来自未授权用户 ($SENDER_ID) 的消息，已忽略。";fi;fi;done
EOF
        sudo sed -i "s|%%BOT_TOKEN%%|${BOT_TOKEN}|g" "${INSTALL_DIR}/bot.sh"
        sudo sed -i "s|%%CHAT_ID%%|${CHAT_ID}|g" "${INSTALL_DIR}/bot.sh"
        sudo chmod +x "${INSTALL_DIR}/monitor.sh" "${INSTALL_DIR}/bot.sh"
    }
    
    # 设置环境
    setup_environment() {
        echo -e "${CYAN}正在创建并授权日志文件 ${LOG_FILE}...${NC}"
        sudo touch $LOG_FILE
        sudo chmod 666 $LOG_FILE

        echo -e "${CYAN}正在设置Cron定时任务（每小时执行一次）...${NC}"
        (sudo crontab -l 2>/dev/null | grep -v "${INSTALL_DIR}/monitor.sh" ; echo "0 * * * * ${INSTALL_DIR}/monitor.sh") | sudo crontab -
    }
    
    # 启动机器人
    start_bot() {
        echo -e "${CYAN}正在后台启动机器人服务...${NC}"
        if screen -list | grep -q "${SCREEN_NAME}"; then
            screen -X -S "${SCREEN_NAME}" quit
        fi
        screen -dmS "${SCREEN_NAME}" "${INSTALL_DIR}/bot.sh"
    }

    # 执行安装流程
    check_deps
    get_user_config
    create_scripts
    setup_environment
    start_bot
    
    echo "--------------------------------------------------"
    echo -e "${GREEN}🎉 恭喜！安装和配置已全部完成！ 🎉${NC}"
    echo "机器人已在后台运行。请向您的机器人发送 /start 来开始使用。"
}


# ==============================================================================
#                           主程序入口
# ==============================================================================
main() {
    clear
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}         VPS 监控机器人一体化管理脚本         ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo ""
    echo -e "请选择您要执行的操作:"
    echo -e "  ${YELLOW}1)${NC} 安装或重新配置机器人"
    echo -e "  ${RED}2)${NC} 卸载机器人"
    echo -e "  ${CYAN}3)${NC} 退出脚本"
    echo ""
    read -p "请输入选项 [1-3]: " choice

    case "$choice" in
        1)
            install_bot
            ;;
        2)
            uninstall_bot
            ;;
        3)
            echo "操作已取消。"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的输入，请输入 1, 2 或 3。${NC}"
            exit 1
            ;;
    esac
}

# 执行主程序
main
