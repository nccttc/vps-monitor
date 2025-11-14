#!/usr/bin/env bash

# =================================================================================
# VPS Monitor & Interactive Bot - 统一管理脚本 (已修复下载问题并增加校验)
#
# 功能:
# 1. 安装/管理 Prometheus Exporters (node, process, blackbox).
# 2. 在关键操作后发送 Telegram 推送通知.
# 3. 安装/管理一个交互式 Telegram Bot, 用于实时查询服务器状态.
# =================================================================================

set -euo pipefail

# --- 全局配置 ---
readonly CONFIG_FILE="/etc/vps-monitor.conf"
readonly BOT_PY_SCRIPT="/usr/local/bin/vps_bot.py"
readonly BOT_SERVICE_FILE="/etc/systemd/system/vps-bot.service"

# 颜色定义
readonly C_RESET='\033[0m'; readonly C_RED='\033[0;31m'; readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'; readonly C_CYAN='\033[0;36m'

# Exporter 版本
readonly NODE_EXPORTER_VERSION="1.8.1"
readonly PROCESS_EXPORTER_VERSION="0.7.10"
readonly BLACKBOX_EXPORTER_VERSION="0.25.0"

# 全局变量
TG_BOT_TOKEN=""
TG_CHAT_ID=""
HOST_IP=""
HOST_NAME=""
OS_ID=""
ARCH=""

# --- 日志与辅助函数 ---
log_info() { echo -e "${C_GREEN}[INFO]${C_RESET} $1"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本 (例如: sudo $0)。"
    fi
}

get_host_info() {
    HOST_NAME=$(hostname)
    HOST_IP=$(curl -s4m 5 https://api.ipify.org || ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1 || echo "N/A")
}

detect_os_arch() {
    if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID}"; else log_error "无法检测到操作系统。"; fi
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "不支持的系统架构: $(uname -m)" ;;
    esac
}

install_dependencies() {
    log_info "检查并安装依赖..."
    local pkgs=()
    command_exists curl || pkgs+=("curl"); command_exists wget || pkgs+=("wget"); command_exists tar || pkgs+=("tar")
    [[ "$1" == "bot" ]] && { command_exists python3 || pkgs+=("python3"); command_exists pip3 || pkgs+=("python3-pip"); }

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        log_info "将要安装: ${pkgs[*]}"
        if [[ "${OS_ID}" =~ (ubuntu|debian) ]]; then apt-get update -y && apt-get install -y "${pkgs[@]}";
        elif [[ "${OS_ID}" =~ (centos|rhel|fedora|almalinux|rocky) ]]; then yum install -y "${pkgs[@]}";
        else log_error "无法自动安装依赖，请手动安装: ${pkgs[*]}"; fi
    else log_info "依赖已满足。"; fi
}

# --- Telegram 配置与通知 ---

load_config() { if [[ -f "${CONFIG_FILE}" ]]; then source "${CONFIG_FILE}"; fi; }

setup_telegram() {
    echo -e "\n${C_CYAN}--- 配置 Telegram 通知 ---${C_RESET}"
    if [[ -n "${TG_BOT_TOKEN}" ]]; then read -rp "已检测到现有配置，是否覆盖？[y/N]: " ovr; [[ ! "${ovr}" =~ ^[Yy]$ ]] && return 0; fi
    read -rp "请输入你的 Bot Token: " token; read -rp "请输入你的 Chat ID: " chat_id
    if [[ -n "$token" && -n "$chat_id" ]]; then
        TG_BOT_TOKEN="$token"; TG_CHAT_ID="$chat_id"
        { echo "TG_BOT_TOKEN=\"${TG_BOT_TOKEN}\""; echo "TG_CHAT_ID=\"${TG_CHAT_ID}\""; } > "${CONFIG_FILE}"; chmod 600 "${CONFIG_FILE}"
        log_info "配置已保存到 ${CONFIG_FILE}"; send_telegram "🔔 <b>VPS Monitor 通知配置成功</b>%0A%0A主机: <code>${HOST_NAME}</code>%0AIP: <code>${HOST_IP}</code>"
    else log_warn "输入为空，跳过配置。"; fi
}

send_telegram() {
    [[ -n "${TG_BOT_TOKEN}" && -n "${TG_CHAT_ID}" ]] && curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="$1" -d parse_mode="HTML" >/dev/null 2>&1 || true
}

# --- Exporter 监控管理 ---

install_monitor() {
    log_info "=== 开始安装 Exporter 监控套件 ==="
    install_dependencies "exporter"; setup_telegram

    # 定义 checksums
    local node_sum_amd64="26e85571a0695543d833075e8184e03b2909a80556553d100783f9850123530c"
    local node_sum_arm64="a436585192534570b2401f165a2977f6b8969f6929944062e08674d89b65b6c0"
    local process_sum_amd64="92b8d4145785f7ad86b772c7201c181512b9d282f63e6e879a955938f653459e"
    local process_sum_arm64="5c7ecb9a2444c80387b320d757d5e656d7826a7988bd71e54581177651a14603"
    local blackbox_sum_amd64="21fe449103a893c5b967a149c05bb1f13b190f23057e93f3560b45d2595e86d2"
    local blackbox_sum_arm64="70174c84b1f649232924294de8d576a870d0246a48238128e469d4d232537bd7"
    
    # 根据架构选择 checksum
    local node_sum=$([[ "$ARCH" == "amd64" ]] && echo "$node_sum_amd64" || echo "$node_sum_arm64")
    local process_sum=$([[ "$ARCH" == "amd64" ]] && echo "$process_sum_amd64" || echo "$process_sum_arm64")
    local blackbox_sum=$([[ "$ARCH" == "amd64" ]] && echo "$blackbox_sum_amd64" || echo "$blackbox_sum_arm64")
    
    install_exporter "prometheus/node_exporter" "node_exporter" "${NODE_EXPORTER_VERSION}" "${node_sum}" "node_exporter" ""
    install_exporter "ncabatoff/process-exporter" "process-exporter" "${PROCESS_EXPORTER_VERSION}" "${process_sum}" "process-exporter" ""
    install_exporter "prometheus/blackbox_exporter" "blackbox_exporter" "${BLACKBOX_EXPORTER_VERSION}" "${blackbox_sum}" "blackbox_exporter" "--config.file=/etc/blackbox.yml"

    cat > /etc/blackbox.yml << 'EOF'
modules:
  http_2xx:
    prober: http
    timeout: 5s
EOF
    systemctl restart blackbox_exporter

    log_info "✅ 所有 Exporter 组件安装并启动成功！"
    send_telegram "✅ <b>Exporter 监控安装成功</b>%0A%0A主机: <code>${HOST_NAME}</code>%0AIP: <code>${HOST_IP}</code>%0A状态: 所有服务运行中"
}

install_exporter() {
    local repo_path="$1" name="$2" version="$3" checksum="$4" binary_name="$5" args="${6:-}"
    log_info "--- 正在安装 ${name} v${version} ---"
    local url="https://github.com/${repo_path}/releases/download/v${version}/${name}-${version}.linux-${ARCH}.tar.gz"
    local tmp_dir; tmp_dir=$(mktemp -d)
    pushd "${tmp_dir}" >/dev/null

    log_info "正在下载: ${url}"; if command_exists curl; then curl -sSL -o "${name}.tar.gz" "${url}"; else wget -q -O "${name}.tar.gz" "${url}"; fi
    log_info "正在校验文件..."; echo "${checksum}  ${name}.tar.gz" | sha256sum -c - || log_error "文件 ${name}.tar.gz 校验失败！"
    tar -xzf "${name}.tar.gz"
    find . -name "${binary_name}" -type f -exec mv {} /usr/local/bin/ \;
    chmod +x "/usr/local/bin/${binary_name}"

    cat > "/etc/systemd/system/${binary_name}.service" << EOF
[Unit]
Description=${name}
After=network-online.target
[Service]
User=root
Restart=on-failure
ExecStart=/usr/local/bin/${binary_name} ${args}
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable "${binary_name}" && systemctl start "${binary_name}"
    popd >/dev/null; rm -rf "${tmp_dir}"
    log_info "${name} 安装成功。"
}

uninstall_monitor() {
    log_info "=== 开始卸载所有 Exporter 监控组件 ==="
    for svc in node_exporter process-exporter blackbox_exporter; do
        systemctl stop "$svc" 2>/dev/null || true; systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service" "/usr/local/bin/${svc}"
    done
    rm -f /etc/blackbox.yml; systemctl daemon-reload
    log_info "✅ 所有 Exporter 组件已卸载。"; send_telegram "🗑️ <b>Exporter 监控已卸载</b>%0A%0A主机: <code>${HOST_NAME}</code>%0AIP: <code>${HOST_IP}</code>"
}

restart_monitor() {
    log_info "=== 正在重启所有 Exporter 监控服务 ==="
    systemctl restart node_exporter process-exporter blackbox_exporter
    log_info "✅ 所有 Exporter 服务已重启。"; send_telegram "🔄 <b>Exporter 监控服务已重启</b>%0A%0A主机: <code>${HOST_NAME}</code>%0AIP: <code>${HOST_IP}</code>"
}

# --- 交互式 Bot 管理 ---
install_bot_service() {
    log_info "=== 开始安装交互式 Telegram Bot 服务 ==="
    if [[ ! -f "${CONFIG_FILE}" || -z "${TG_BOT_TOKEN}" ]]; then log_warn "未找到 Telegram 配置。请先配置。"; setup_telegram; [[ -z "${TG_BOT_TOKEN}" ]] && log_error "Telegram 配置失败，无法安装 Bot。"; fi
    install_dependencies "bot"; log_info "正在安装/更新 Python 库: python-telegram-bot"; pip3 install "python-telegram-bot>=20.0" --upgrade

    log_info "正在创建 Bot 脚本: ${BOT_PY_SCRIPT}"; cat > "${BOT_PY_SCRIPT}" << 'EOF'
import os, subprocess, logging
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters
logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)
BOT_TOKEN, ALLOWED_CHAT_ID = os.getenv("VPS_BOT_TOKEN"), os.getenv("VPS_CHAT_ID")
if not (BOT_TOKEN and ALLOWED_CHAT_ID): logger.error("环境变量 VPS_BOT_TOKEN 或 VPS_CHAT_ID 未设置!"); exit(1)
try: admin_filter = filters.User(user_id=int(ALLOWED_CHAT_ID))
except ValueError: logger.error("环境变量 VPS_CHAT_ID 不是一个有效的整数!"); exit(1)

async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_html(f"👋 你好, {update.effective_user.mention_html()}!\n\n我是你的专属 VPS 状态监控机器人。\n\n<b>可用命令:</b>\n/status - 查看当前服务器状态")

async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        hostname = subprocess.check_output("hostname", shell=True).decode("utf-8").strip()
        uptime_output = subprocess.check_output("uptime", shell=True).decode("utf-8").strip()
        mem_info = "\n".join(subprocess.check_output("free -h", shell=True).decode("utf-8").splitlines()[:2])
        disk_info = subprocess.check_output("df -h /", shell=True).decode("utf-8").splitlines()[1]
        message = (f"<b>📊 主机 <code>{hostname}</code> 状态报告</b>\n\n"
                   f"<b>⏳ 系统负载与在线时间:</b>\n<pre>{uptime_output}</pre>\n"
                   f"<b>💾 内存使用:</b>\n<pre>{mem_info}</pre>\n"
                   f"<b>💽 磁盘空间 (/):</b>\n<pre>Filesystem      Size  Used Avail Use%\n{disk_info}</pre>")
        await update.message.reply_html(message)
    except Exception as e:
        logger.error(f"执行 status 命令失败: {e}"); await update.message.reply_text("获取服务器状态时出错，请检查服务器日志。")

async def unauthorized_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("🚫 你没有权限使用此机器人。")

def main():
    application = Application.builder().token(BOT_TOKEN).build()
    application.add_handler(CommandHandler("start", start_command, filters=admin_filter))
    application.add_handler(CommandHandler("status", status_command, filters=admin_filter))
    application.add_handler(MessageHandler(~admin_filter, unauthorized_handler))
    logger.info("机器人启动，开始监听..."); application.run_polling()
if __name__ == '__main__': main()
EOF
    chmod +x "${BOT_PY_SCRIPT}"

    log_info "正在创建 systemd 服务: ${BOT_SERVICE_FILE}"; cat > "${BOT_SERVICE_FILE}" << EOF
[Unit]
Description=VPS Telegram Bot Service
After=network.target
[Service]
Environment="VPS_BOT_TOKEN=${TG_BOT_TOKEN}"
Environment="VPS_CHAT_ID=${TG_CHAT_ID}"
Type=simple
User=root
ExecStart=/usr/bin/python3 ${BOT_PY_SCRIPT}
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable vps-bot.service && systemctl restart vps-bot.service
    log_info "✅ 交互式 Bot 服务安装/更新成功并已启动！"; log_info "请在 Telegram 中向你的机器人发送 /status 命令进行测试。"
}

uninstall_bot_service() {
    log_info "=== 正在卸载交互式 Bot 服务 ==="
    systemctl stop vps-bot.service 2>/dev/null || true; systemctl disable vps-bot.service 2>/dev/null || true
    rm -f "${BOT_SERVICE_FILE}" "${BOT_PY_SCRIPT}"; systemctl daemon-reload
    log_info "✅ 交互式 Bot 服务已卸载。"
}

restart_bot_service() { log_info "=== 正在重启交互式 Bot 服务 ==="; systemctl restart vps-bot.service; log_info "✅ 交互式 Bot 服务已重启。"; }
view_bot_logs() { log_info "=== 查看 Bot 服务日志 (按 Ctrl+C 退出) ==="; journalctl -u vps-bot.service -f -n 50; }

# --- 主菜单与程序入口 ---
show_menu() {
    echo -e "\n${C_CYAN}========== VPS 监控与 Bot 统一管理脚本 ==========${C_RESET}"
    echo -e "${C_YELLOW}--- Exporter 监控 ---${C_RESET}"
    echo "  1. 安装 Exporter (Install Exporters)"; echo "  2. 卸载 Exporter (Uninstall Exporters)"; echo "  3. 重启 Exporter (Restart Exporters)"
    echo -e "${C_YELLOW}--- 交互式 Bot ---${C_RESET}"
    echo "  4. 安装/更新 Bot 服务 (Install/Update Bot Service)"; echo "  5. 卸载 Bot 服务 (Uninstall Bot Service)"
    echo "  6. 重启 Bot 服务 (Restart Bot Service)"; echo "  7. 查看 Bot 日志 (View Bot Logs)"
    echo -e "${C_YELLOW}--- 其他 ---${C_RESET}"
    echo "  8. 重新配置 Telegram (Re-configure Telegram)"; echo "  9. 退出 (Exit)"
    echo "----------------------------------------------------"
    read -rp "请输入你的选择 [1-9]: " choice
}

main() {
    check_root; detect_os_arch; get_host_info; load_config
    if [[ $# -gt 0 ]]; then
        case "$1" in
            install) install_monitor ;; uninstall) uninstall_monitor ;; restart) restart_monitor ;;
            install_bot) install_bot_service ;; uninstall_bot) uninstall_bot_service ;; restart_bot) restart_bot_service ;;
            *) log_error "无效参数: $1。" ;;
        esac
    else
        while true; do
            show_menu
            case "${choice}" in
                1) install_monitor ;; 2) uninstall_monitor ;; 3) restart_monitor ;; 4) install_bot_service ;;
                5) uninstall_bot_service ;; 6) restart_bot_service ;; 7) view_bot_logs ;; 8) setup_telegram ;;
                9) echo "脚本已退出。"; exit 0 ;; *) log_warn "无效的选择，请重新输入。" ;;
            esac
            read -n 1 -s -r -p $'\n按任意键返回主菜单...'
        done
    fi
}

main "$@"
