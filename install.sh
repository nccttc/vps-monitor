#!/usr/bin/env bash
# vps-monitor脚本

set -euo pipefail

# --- 全局变量和常量 ---
readonly PROG_NAME="vps-monitor"
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'

# exporter 版本和校验和 (建议定期更新)
readonly NODE_EXPORTER_VERSION="1.8.1"
readonly PROCESS_EXPORTER_VERSION="0.7.10"
readonly BLACKBOX_EXPORTER_VERSION="0.25.0"

# --- 日志函数 ---
log_info() {
    echo -e "${C_GREEN}[INFO]${C_RESET} $1"
}

log_warn() {
    echo -e "${C_YELLOW}[WARN]${C_RESET} $1"
}

log_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2
    exit 1
}

# --- 辅助函数 ---

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查是否以 root 用户运行
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "此脚本需要以 root 权限运行，请使用 sudo 或切换到 root 用户。"
    fi
}

# 获取操作系统信息
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID}"
    else
        log_error "无法检测到操作系统信息。"
    fi
}

# 获取系统架构
get_arch() {
    case "$(uname -m)" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "不支持的系统架构: $(uname -m)" ;;
    esac
}

# 安装必要的依赖软件
install_dependencies() {
    log_info "正在检查并安装依赖..."
    local pkgs_to_install=()
    command_exists wget || command_exists curl || pkgs_to_install+=("wget" "curl")
    command_exists unzip || pkgs_to_install+=("unzip")
    command_exists virt-what || pkgs_to_install+=("virt-what")
    command_exists dmidecode || pkgs_to_install+=("dmidecode")

    if [[ ${#pkgs_to_install[@]} -gt 0 ]]; then
        if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
            apt-get update -y
            apt-get install -y "${pkgs_to_install[@]}"
        elif [[ "${OS_ID}" == "centos" || "${OS_ID}" == "rhel" || "${OS_ID}" == "fedora" ]]; then
            yum install -y "${pkgs_to_install[@]}"
        else
            log_error "不支持的操作系统: ${OS_ID}"
        fi
    fi
    log_info "依赖安装完成。"
}

# 下载并校验文件
download_and_verify() {
    local url="$1"
    local checksum="$2"
    local filename
    filename=$(basename "$url")

    if command_exists curl; then
        curl -sSL -o "${filename}" "${url}"
    elif command_exists wget; then
        wget -q -O "${filename}" "${url}"
    else
        log_error "未找到 wget 或 curl，无法下载文件。"
    fi

    log_info "正在校验文件: ${filename}"
    echo "${checksum} ${filename}" | sha256sum -c -
    log_info "文件校验成功。"
}

# --- Exporter 安装/卸载/重启 ---

# 通用安装函数
install_exporter() {
    local name="$1"
    local version="$2"
    local checksum_amd64="$3"
    local checksum_arm64="$4"
    local binary_name="$5"
    local port="$6"
    local args="${7:-}"

    log_info "--- 开始安装 ${name} v${version} ---"

    local checksum
    [[ "${ARCH}" == "amd64" ]] && checksum="${checksum_amd64}" || checksum="${checksum_arm64}"
    
    local url="https://github.com/prometheus/${name}/releases/download/v${version}/${name}-${version}.linux-${ARCH}.tar.gz"
    local archive_name
    archive_name=$(basename "$url")
    local extracted_dir="${archive_name%.tar.gz}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    pushd "${tmp_dir}" >/dev/null

    download_and_verify "${url}" "${checksum}"
    tar -xzf "${archive_name}"
    
    log_info "正在安装 ${binary_name}..."
    mv "${extracted_dir}/${binary_name}" /usr/local/bin/
    chmod +x "/usr/local/bin/${binary_name}"

    log_info "正在创建 systemd 服务: ${binary_name}.service"
    cat > "/etc/systemd/system/${binary_name}.service" << EOF
[Unit]
Description=${name}
Documentation=https://github.com/prometheus/${name}
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

    log_info "${name} 安装成功！端口: ${port}"
}

# 通用卸载函数
uninstall_exporter() {
    local service_name="$1"
    log_info "正在卸载 ${service_name}..."
    
    if systemctl is-active "${service_name}" &>/dev/null; then
        systemctl stop "${service_name}"
    fi
    if systemctl is-enabled "${service_name}" &>/dev/null; then
        systemctl disable "${service_name}"
    fi
    
    rm -f "/etc/systemd/system/${service_name}.service"
    rm -f "/usr/local/bin/${service_name}"
    
    systemctl daemon-reload
    log_info "${service_name} 卸载完成。"
}

# 通用重启函数
restart_exporter() {
    local service_name="$1"
    log_info "正在重启 ${service_name}..."
    systemctl restart "${service_name}"
    log_info "${service_name} 重启完成。"
}

# --- 业务逻辑 ---

install_monitor() {
    log_info "开始安装监控套件..."
    install_dependencies
    
    # 请在这里填入最新的 SHA256 校验和
    # node_exporter
    install_exporter "node_exporter" "${NODE_EXPORTER_VERSION}" \
        "26e85571a0695543d833075e8184e03b2909a80556553d100783f9850123530c" \
        "a436585192534570b2401f165a2977f6b8969f6929944062e08674d89b65b6c0" \
        "node_exporter" "9100"

    # process-exporter
    install_exporter "process-exporter" "${PROCESS_EXPORTER_VERSION}" \
        "92b8d4145785f7ad86b772c7201c181512b9d282f63e6e879a955938f653459e" \
        "5c7ecb9a2444c80387b320d757d5e656d7826a7988bd71e54581177651a14603" \
        "process-exporter" "9256"

    # blackbox_exporter
    install_exporter "blackbox_exporter" "${BLACKBOX_EXPORTER_VERSION}" \
        "21fe449103a893c5b967a149c05bb1f13b190f23057e93f3560b45d2595e86d2" \
        "70174c84b1f649232924294de8d576a870d0246a48238128e469d4d232537bd7" \
        "blackbox_exporter" "9115" "--config.file=/etc/blackbox.yml"

    # blackbox_exporter 需要一个配置文件
    log_info "正在为 blackbox_exporter 创建默认配置文件..."
    cat > /etc/blackbox.yml << EOF
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      follow_redirects: true
      preferred_ip_protocol: "ip4"
  tcp_connect:
    prober: tcp
    timeout: 5s
EOF
    restart_exporter "blackbox_exporter"

    log_info "所有监控组件安装并启动成功！"
}

uninstall_monitor() {
    log_info "开始卸载监控套件..."
    uninstall_exporter "node_exporter"
    uninstall_exporter "process-exporter"
    uninstall_exporter "blackbox_exporter"
    rm -f /etc/blackbox.yml
    log_info "所有监控组件已卸载。"
}

restart_monitor() {
    log_info "开始重启监控套件..."
    restart_exporter "node_exporter"
    restart_exporter "process-exporter"
    restart_exporter "blackbox_exporter"
    log_info "所有监控组件已重启。"
}

# --- 菜单和主程序 ---
show_menu() {
    echo "------------------------------------------------"
    echo "          VPS 监控代理管理脚本"
    echo "------------------------------------------------"
    echo "  1. 安装监控 (Install Monitor)"
    echo "  2. 卸载监控 (Uninstall Monitor)"
    echo "  3. 重启监控 (Restart Monitor)"
    echo "  4. 退出脚本 (Exit)"
    echo "------------------------------------------------"
    read -rp "请输入你的选择 [1-4]: " choice
}

main() {
    check_root
    get_os_info
    get_arch

    if [[ $# -gt 0 ]]; then
        case "$1" in
            install) install_monitor ;;
            uninstall) uninstall_monitor ;;
            restart) restart_monitor ;;
            *) log_error "无效的参数: $1。有效参数为: install, uninstall, restart" ;;
        esac
    else
        show_menu
        case "${choice}" in
            1) install_monitor ;;
            2) uninstall_monitor ;;
            3) restart_monitor ;;
            4) echo "脚本已退出。" ;;
            *) log_error "无效的选择。" ;;
        esac
    fi
}

main "$@"
