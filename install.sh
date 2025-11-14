#!/bin/bash

#================================================================================
# VPS Monitoring Script with Telegram Alerts
#
# Description: This script monitors CPU, memory, disk usage, and network speed.
#              It sends an alert to a Telegram bot if any metric exceeds
#              predefined thresholds. It also supports scheduled reports.
# Author: Gemini
#================================================================================

# --- Script Configuration ---
CONFIG_FILE=~/.vps_monitor_config

# --- Helper Functions ---

# Function to display colored text
print_color() {
    case $1 in
        "green") echo -e "\033[32m$2\033[0m" ;;
        "red") echo -e "\033[31m$2\033[0m" ;;
        "yellow") echo -e "\033[33m$2\033[0m" ;;
        *) echo "$2" ;;
    esac
}

# --- Initial Setup ---
setup() {
    print_color "yellow" "欢迎使用VPS监控脚本安装向导。"
    print_color "yellow" "请输入您的Telegram Bot信息和警报阈值。"
    echo

    read -p "请输入您的Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    read -p "请输入您的Telegram Chat ID: " TELEGRAM_CHAT_ID
    echo

    print_color "yellow" "现在设置各项资源的警报阈值 (%)"
    read -p "CPU使用率警报阈值 (例如: 80): " CPU_THRESHOLD
    read -p "内存使用率警报阈值 (例如: 85): " MEM_THRESHOLD
    read -p "硬盘使用率警报阈值 (例如: 90): " DISK_THRESHOLD

    # 保存配置
    echo "TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN}'" > ${CONFIG_FILE}
    echo "TELEGRAM_CHAT_ID='${TELEGRAM_CHAT_ID}'" >> ${CONFIG_FILE}
    echo "CPU_THRESHOLD=${CPU_THRESHOLD}" >> ${CONFIG_FILE}
    echo "MEM_THRESHOLD=${MEM_THRESHOLD}" >> ${CONFIG_FILE}
    echo "DISK_THRESHOLD=${DISK_THRESHOLD}" >> ${CONFIG_FILE}

    print_color "green" "\n配置已保存至 ${CONFIG_FILE}"
    print_color "green" "安装完成！"
    echo
    print_color "yellow" "为了让脚本能够定时运行，您需要添加一个Cron任务。"
    print_color "yellow" "例如，要每天的10点发送报告，请运行 'crontab -e' 并添加以下行:"
    echo "0 10 * * * /bin/bash $(realpath "$0") report"
    print_color "yellow" "要实时监控并在超限时立即报警，可以每5分钟运行一次:"
    echo "*/5 * * * * /bin/bash $(realpath "$0") check"
    echo
}

# 加载配置
load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        source "${CONFIG_FILE}"
    else
        print_color "red" "配置文件不存在！请先运行安装程序。"
        setup
    fi
}

# --- Monitoring Functions ---

# 获取CPU使用率
get_cpu_usage() {
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    echo "${CPU_USAGE}"
}

# 获取内存使用率
get_mem_usage() {
    MEM_USAGE=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
    echo "${MEM_USAGE}"
}

# 获取硬盘使用率
get_disk_usage() {
    DISK_USAGE=$(df -h / | grep / | awk '{ print $5 }' | sed 's/%//g')
    echo "${DISK_USAGE}"
}

# 获取网络速度 (KB/s)
get_network_speed() {
    INTERFACE=$(ip route | grep default | awk '{print $5}')
    R1=$(cat /sys/class/net/${INTERFACE}/statistics/rx_bytes)
    T1=$(cat /sys/class/net/${INTERFACE}/statistics/tx_bytes)
    sleep 1
    R2=$(cat /sys/class/net/${INTERFACE}/statistics/rx_bytes)
    T2=$(cat /sys/class/net/${INTERFACE}/statistics/tx_bytes)
    RX_SPEED=$(( (R2 - R1) / 1024 ))
    TX_SPEED=$(( (T2 - T1) / 1024 ))
    echo "下载: ${RX_SPEED} KB/s, 上传: ${TX_SPEED} KB/s"
}


# --- Telegram Bot Function ---

# 发送消息到Telegram
send_telegram_message() {
    local MESSAGE_TEXT="$1"
    # 使用-d参数并通过POST请求发送，以支持多行文本
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${MESSAGE_TEXT}" \
        -d parse_mode="Markdown" > /dev/null
}


# --- Core Logic ---

# 检查并发送警报
check_and_alert() {
    load_config

    CPU=$(get_cpu_usage)
    MEM=$(get_mem_usage)
    DISK=$(get_disk_usage)
    
    ALERT_MESSAGE=""

    # 比较浮点数
    if (( $(echo "$CPU > $CPU_THRESHOLD" | bc -l) )); then
        ALERT_MESSAGE+="*警告: CPU使用率过高!* \n"
        ALERT_MESSAGE+="  - 当前: ${CPU}%\n"
        ALERT_MESSAGE+="  - 阈值: ${CPU_THRESHOLD}%\n\n"
    fi

    if (( $(echo "$MEM > $MEM_THRESHOLD" | bc -l) )); then
        ALERT_MESSAGE+="*警告: 内存使用率过高!* \n"
        ALERT_MESSAGE+="  - 当前: ${MEM}%\n"
        ALERT_MESSAGE+="  - 阈值: ${MEM_THRESHOLD}%\n\n"
    fi

    if [ "$DISK" -gt "$DISK_THRESHOLD" ]; then
        ALERT_MESSAGE+="*警告: 硬盘使用率过高!* \n"
        ALERT_MESSAGE+="  - 当前: ${DISK}%\n"
        ALERT_MESSAGE+="  - 阈值: ${DISK_THRESHOLD}%\n\n"
    fi

    if [ -n "${ALERT_MESSAGE}" ]; then
        HOSTNAME=$(hostname)
        IP_ADDRESS=$(hostname -I | awk '{print $1}')
        FINAL_MESSAGE="*VPS 状态警报: ${HOSTNAME} (${IP_ADDRESS})*\n\n${ALERT_MESSAGE}"
        send_telegram_message "${FINAL_MESSAGE}"
    fi
}

# 生成并发送报告
send_report() {
    load_config
    
    HOSTNAME=$(hostname)
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    CPU=$(get_cpu_usage)
    MEM=$(get_mem_usage)
    DISK=$(get_disk_usage)
    NET_SPEED=$(get_network_speed)
    UPTIME=$(uptime -p)

    REPORT_MESSAGE="*VPS 状态报告: ${HOSTNAME} (${IP_ADDRESS})*\n\n"
    REPORT_MESSAGE+="*系统运行时间:* ${UPTIME}\n"
    REPORT_MESSAGE+="*CPU 使用率:* ${CPU}%\n"
    REPORT_MESSAGE+="*内存 使用率:* ${MEM}%\n"
    REPORT_MESSAGE+="*硬盘 使用率:* ${DISK}%\n"
    REPORT_MESSAGE+="*当前网速:* ${NET_SPEED}\n"

    send_telegram_message "${REPORT_MESSAGE}"
}


# --- Main Execution ---

case "$1" in
    "install")
        setup
        ;;
    "check")
        check_and_alert
        ;;
    "report")
        send_report
        ;;
    *)
        echo "用法: $0 {install|check|report}"
        echo "  install: 初始化脚本配置。"
        echo "  check:   检查各项指标，如果超过阈值则发送警报。"
        echo "  report:  发送一份当前的系统状态报告。"
        ;;
esac

exit 0
