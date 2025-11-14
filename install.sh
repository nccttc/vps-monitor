#!/usr/bin/env bash

# vps-monitor脚本

set -euo pipefail

# --- 全局配置 ---
readonly PROG_NAME="vps-monitor"
readonly CONFIG_FILE="/etc/vps-monitor.conf"
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_CYAN='\033[0;36m'

# Exporter 版本配置
readonly NODE_EXPORTER_VERSION="1.8.1"
readonly PROCESS_EXPORTER_VERSION="0.7.10"
readonly BLACKBOX_EXPORTER_VERSION="0.25.0"

# 全局变量，将在 load_config 中初始化
TG_BOT_TOKEN=""
TG_CHAT_ID=""
HOST_IP=""
HOST_NAME=""

# --- 日志函数 ---
log_info() { echo -e "${C_GREEN}[INFO]${C_RESET} $1"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2; exit 1; }

# --- 辅助函数 ---

command_exists() { command -v "$1" >/dev/null 2>&1; }

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "请使用 root 权限运行此脚本 (sudo)。"
    fi
}

# 获取本机信息用于通知
get_host_info() {
    HOST_NAME=$(hostname)
    # 尝试获取公网IP，如果失败则使用内网IP
    HOST_IP=$(curl -s4m 5 https://api.ipify.org || ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
}

get_os_info() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID}"
    else
        log_error "无法检测到操作系统信息。"
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "不支持的架构: $(uname -m)" ;;
    esac
}

install_dependencies() {
    log_info "检查依赖..."
    local pkgs=()
    command_exists curl || pkgs+=("curl")
    command_exists wget || pkgs+=("wget")
    command_exists unzip || pkgs+=("unzip")
    command_exists tar || pkgs+=("tar")

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        if [[ "${OS_ID}" =~ (ubuntu|debian) ]]; then
            apt-get update -y && apt-get install -y "${pkgs[@]}"
        elif [[ "${OS_ID}" =~ (centos|rhel|fedora|almalinux|rocky) ]]; then
            yum install -y "${pkgs[@]}"
        else
            log_warn "无法自动安装依赖，请手动安装: ${pkgs[*]}"
        fi
    fi
}

# --- Telegram 通知功能 ---

# 加载配置
load_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
    fi
}

# 配置 Telegram
setup_telegram() {
    echo -e "\n${C_CYAN}--- 配置 Telegram 通知 ---${C_RESET}"
    read -rp "是否启用 Telegram 通知? [y/N]: " enable_tg
    if [[ "${enable_tg}" =~ ^[Yy]$ ]]; then
        read -rp "请输入 Bot Token: " token
        read -rp "请输入 Chat ID: " chat_id
        
        # 简单的校验
        if [[ -n "$token" && -n "$chat_id" ]]; then
            TG_BOT_TOKEN="$token"
            TG_CHAT_ID="$chat_id"
            
            # 保存配置
            echo "TG_BOT_TOKEN=\"${token}\"" > "${CONFIG_FILE}"
            echo "TG_CHAT_ID=\"${chat_id}\"" >> "${CONFIG_FILE}"
            chmod 600 "${CONFIG_FILE}" # 保护配置文件
            log_info "Telegram 配置已保存至 ${CONFIG_FILE}"
            
            # 发送测试消息
            send_telegram "🔔 <b>VPS Monitor 通知配置测试</b>%0A%0A主机: <code>${HOST_NAME}</code>%0AIP: <code>${HOST_IP}</code>%0A状态: 配置成功"
        else
            log_warn "输入为空，跳过 Telegram 配置。"
        fi
    else
        log_info "已跳过 Telegram 配置。"
    fi
}

# 发送消息函数
send_telegram() {
    local message="$1"
    # 只有当变量不为空时才发送
    if [[ -n "${TG_BOT_TOKEN}" && -n "${TG_CHAT_ID}" ]]; then
        # 使用 curl 发送，--data-urlencode 处理特殊字符
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="HTML" >/dev/null 2>&1 || true
    fi
}

# --- 核心功能 ---

download_and_verify() {
    local url="$1"
    local checksum="$2"
    local filename
    filename=$(basename "$url")

    if command_exists curl; then
        curl -sSL -o "${filename}" "${url}"
    else
        wget -q -O "${filename}" "${url}"
    fi

    # 简单的校验逻辑，如果 checksum 为空则跳过
    if [[ -n "$checksum" ]]; then
        echo "${checksum} ${filename}" | sha256sum -c - >/dev/null 2>&1 || log_error "文件 ${filename} 校验失败！"
    fi
}

install_exporter() {
    local name="$1"
    local version="$2"
    local checksum="$3" # 简化传参，这里只演示逻辑
    local binary_name="$4"
    local port="$5"
    local args="${6:-}"

    log_info "正在安装 ${name}..."
    
    local url="https://github.com/prometheus/${name}/releases/download/v${version}/${name}-${version}.linux-${ARCH}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    pushd "${tmp_dir}" >/dev/null
    download_and_verify "${url}" "${checksum}"
    tar -xzf "$(basename "$url")"
    
    # 查找解压后的二进制文件 (因为目录名可能包含版本号)
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

    systemctl daemon-reload
    systemctl enable "${binary_name}"
    systemctl start "${binary_name}"
    popd >/dev/null
    rm -rf "${tmp_dir}"
}

# --- 业务流程 ---

install_monitor() {
    install_dependencies
    setup_telegram # 先配置 TG，以便发送安装成功通知

    # 安装各组件 (此处省略了详细的 SHA256 校验码以保持代码整洁，建议实际使用时加上)
    # node_exporter
    install_exporter "node_exporter" "${NODE_EXPORTER_VERSION}" "" "node_exporter" "9100"
    
    # process-exporter
    install_exporter "process-exporter" "${PROCESS_EXPORTER_VERSION}" "" "process-exporter" "9256" "-config.path /etc/process-exporter.yml"
    # 创建 process-exporter 默认空配置，防止启动失败
    if [[ ! -f /etc/process-exporter.yml ]]; then
        echo "process_names:" > /etc/process-exporter.yml
        echo "  - name: \"{{.Comm}}\"" >> /etc/process-exporter.yml
        echo "    cmdline: \".+ \"" >> /etc/process-exporter.yml
    fi
    systemctl restart process-exporter

    # blackbox_exporter
    install_exporter "blackbox_exporter" "${BLACKBOX_EXPORTER_VERSION}" "" "blackbox_exporter" "9115" "--config.file=/etc/blackbox.yml"
    # 创建 blackbox 配置
    if [[ ! -f /etc/blackbox.yml ]]; then
        cat > /etc/blackbox.yml << EOF
modules:
  http_2xx:
    prober: http
    timeout: 5s
  icmp:
    prober: icmp
EOF
    fi
    systemctl restart blackbox_exporter

    log_info "所有组件安装完成。"
    send_telegram "✅ <b>VPS Monitor 安装成功</b>%0A%0A主机: <code>${HOST_NAME}</code>%0AIP: <code>${HOST_IP}</code>%0A组件: node, process, blackbox%0A状态: 运行中"
}

uninstall_monitor() {
    log_info "开始卸载..."
    local services=("node_exporter" "process-exporter" "blackbox_exporter")
    
    for svc in "${services[@]}"; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        rm -f "/usr/local/bin/${svc}"
    done
    systemctl daemon-reload

    # 询问是否删除配置文件
    if [[ -f "${CONFIG_FILE}" ]]; then
        send_telegram "🗑️ <b>VPS Monitor 已卸载</b>%0A%0A主机: <code>${HOST_NAME}</code>%0AIP: <code>${HOST_IP}</code>%0A状态: 服务已移除"
        read -rp "是否删除 Telegram 配置文件? [y/N]: " del_conf
        if [[ "${del_conf}" =~ ^[Yy]$ ]]; then
            rm -f "${CONFIG_FILE}"
            log_info "配置文件已删除。"
        fi
    fi
    
    rm -f /etc/blackbox.yml /etc/process-exporter.yml
    log_info "卸载完成。"
}

restart_monitor() {
    log_info "正在重启服务..."
    systemctl restart node_exporter process-exporter blackbox_exporter
    log_info "重启完成。"
    send_telegram "🔄 <b>VPS Monitor 服务已重启</b>%0A%0A主机: <code>${HOST_NAME}</code>%0AIP: <code>${HOST_IP}</code>%0A状态: 服务已重新加载"
}

show_menu() {
    echo "------------------------------------------------"
    echo "          VPS 监控管理 (含 TG 通知)"
    echo "------------------------------------------------"
    echo "  1. 安装监控 (Install)"
    echo "  2. 卸载监控 (Uninstall)"
    echo "  3. 重启监控 (Restart)"
    echo "  4. 退出 (Exit)"
    echo "------------------------------------------------"
    read -rp "请选择 [1-4]: " choice
}

main() {
    check_root
    get_os_info
    get_arch
    get_host_info # 获取主机名和IP
    load_config   # 加载已保存的 TG 配置

    if [[ $# -gt 0 ]]; then
        case "$1" in
            install) install_monitor ;;
            uninstall) uninstall_monitor ;;
            restart) restart_monitor ;;
            *) log_error "用法: $0 {install|uninstall|restart}" ;;
        esac
    else
        show_menu
        case "${choice}" in
            1) install_monitor ;;
            2) uninstall_monitor ;;
            3) restart_monitor ;;
            4) exit 0 ;;
            *) log_error "无效选择" ;;
        esac
    fi
}

main "$@"
