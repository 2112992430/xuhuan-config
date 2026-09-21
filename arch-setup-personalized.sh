#!/bin/bash
# arch-setup-personalized.sh - 为你的真实机器定制的 Arch Linux 一键配置脚本
# 作者: qin
# 适用: AMD Ryzen 5 5500U / 多桌面环境 / btrfs
# 仓库: https://github.com/2112992430/xuhuan-config
# 用法: sudo ./arch-setup-personalized.sh

set -euo pipefail

# 🎨 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 📝 日志函数
log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
info()  { echo -e "${BLUE}[NOTE]${NC} $1"; }

# 🔁 重试函数：下载/安装命令失败后自动重新执行，直到成功
# 用法: retry <命令...>   默认无限重试；设置环境变量 RETRY_MAX=N 可限制次数
retry() {
    local attempts=0
    local max="${RETRY_MAX:-0}"   # 0 = 无限重试
    while true; do
        attempts=$((attempts + 1))
        if "$@"; then
            [[ $attempts -gt 1 ]] && log "✅ 命令在第 ${attempts} 次尝试时成功: $*"
            return 0
        fi
        warn "⚠️ 命令失败 (第 ${attempts} 次)，3 秒后自动重试: $*"
        if [[ "$max" -gt 0 && "$attempts" -ge "$max" ]]; then
            error "命令在 ${max} 次尝试后仍失败: $*"
            return 1
        fi
        sleep 3
    done
}

# ✅ 检查 root
if [[ $EUID -ne 0 ]]; then
    error "此脚本需要 root 权限运行: sudo $0"
    exit 1
fi

# 检测当前用户
REAL_USER="${SUDO_USER:-$(who am i | awk '{print $1}')}"
REAL_USER="${REAL_USER:-root}"
HOME_DIR="/home/${REAL_USER}"
if [[ "$REAL_USER" == "root" ]]; then
    HOME_DIR="/root"
fi
log "检测到用户: ${REAL_USER} (家目录: ${HOME_DIR})"

# 脚本所在目录（即 xuhuan-config 仓库根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log "配置仓库目录: ${SCRIPT_DIR}"

# ============================================================
# 🖥️ 桌面环境选择
# ============================================================
select_desktop_environments() {
    local choices
    if command -v whiptail &>/dev/null; then
        choices=$(whiptail --title "桌面环境选择" \
            --checklist "请选择要安装的桌面环境（空格键选择，回车确认）:\n\n注意：至少选择一个，否则将默认安装 i3。" \
            20 70 8 \
            "kde"     "KDE Plasma 6 (完整桌面环境)"       ON \
            "sonicde" "SonicDE (KDE X11 分支)"           OFF \
            "niri"    "Niri (Wayland 滚动平铺)"          ON \
            "i3"      "i3 (X11 平铺窗口管理器)"          ON \
            3>&1 1>&2 2>&3) || true
    else
        echo "==============================================="
        echo "  桌面环境选择"
        echo "==============================================="
        echo "  1) KDE Plasma 6"
        echo "  2) SonicDE (KDE X11 分支)"
        echo "  3) Niri (Wayland)"
        echo "  4) i3 (X11)"
        echo "==============================================="
        echo "请输入要安装的编号，用空格分隔（如: 1 3 4）:"
        read -r -p "> " raw_choices
        choices=""
        for c in $raw_choices; do
            case "$c" in
                1) choices="$choices kde" ;;
                2) choices="$choices sonicde" ;;
                3) choices="$choices niri" ;;
                4) choices="$choices i3" ;;
            esac
        done
    fi

    # 如果用户没有选择任何桌面环境，默认安装 i3
    if [[ -z "${choices// /}" ]]; then
        warn "未选择任何桌面环境，默认安装 i3。"
        choices="i3"
    fi

    echo "$choices"
}

log "请选择要安装的桌面环境..."
SELECTED_DESKTOPS=$(select_desktop_environments)
log "✅ 已选择: ${SELECTED_DESKTOPS}"

# 确认是否继续
read -r -p "确认开始配置? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { info "已取消"; exit 0; }

# ⏱️ 计时
START_TIME=$(date +%s)

# 🌏 第零步：ArchLinuxCN 源 + 镜像源 + paru
log "配置 ArchLinuxCN 源与镜像源..."

# 0.1 添加 ArchLinuxCN 源 (使用当前系统的官方源 repo.archlinuxcn.org)
log "配置 ArchLinuxCN 源..."
if ! grep -q "^\[archlinuxcn\]" /etc/pacman.conf; then
    cp /etc/pacman.conf /etc/pacman.conf.bak
    cat >> /etc/pacman.conf << 'EOF'

[archlinuxcn]
Server = https://repo.archlinuxcn.org/$arch
EOF
    log "✅ ArchLinuxCN 已添加 (官方源 repo.archlinuxcn.org, 备份: /etc/pacman.conf.bak)"
else
    log "✅ ArchLinuxCN 源已存在"
fi

# 0.2 安装 reflector 并生成最快镜像列表
log "安装 reflector 并获取最快镜像源..."
retry pacman -S --noconfirm --needed reflector
if reflector --country China --latest 20 --protocol https --sort rate --fastest 10 --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    log "✅ 已用 reflector 生成国内镜像列表 (Top 10)"
else
    warn "国内镜像获取失败，使用全局镜像排序..."
    reflector --protocol https --sort rate --fastest 10 --save /etc/pacman.d/mirrorlist 2>/dev/null \
        && log "✅ 已用 reflector 生成全局镜像列表" \
        || warn "reflector 失败，保留原镜像列表"
fi

# 0.3 刷新数据库并安装 archlinuxcn-keyring + paru
log "刷新 pacman 数据库..."
retry pacman -Sy --noconfirm

log "安装 archlinuxcn-keyring 与 paru..."
# 首次安装 archlinuxcn-keyring 前，先信任 cn 源主密钥（否则会报 unknown public key）
pacman-key --recv-keys 5E351FAF0F6E0A7E 2>/dev/null || true
pacman-key --lsign-key 5E351FAF0F6E0A7E 2>/dev/null || true
if retry pacman -S --noconfirm --needed archlinuxcn-keyring paru; then
    log "✅ paru 已安装 (AUR 助手)"
else
    # 仅当设置了 RETRY_MAX 且超限时才会走到这里
    warn "从 ArchLinuxCN 安装 paru 失败，尝试 AUR 手动编译..."
    retry pacman -S --noconfirm --needed base-devel git
    rm -rf /tmp/paru-build
    retry sudo -H -u "${REAL_USER}" git clone https://aur.archlinux.org/paru.git /tmp/paru-build
    if cd /tmp/paru-build && retry sudo -H -u "${REAL_USER}" makepkg -si --noconfirm; then
        log "✅ paru 已通过 AUR 手动编译安装"
    else
        warn "paru 安装失败，请安装后手动执行: paru -Syu"
    fi
    cd /
fi

# 0.4 启用 multilib 仓库（steam/wine/lutris/lib32 系列依赖）
log "启用 multilib 仓库..."
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    # 若存在被注释的 [multilib] 段则取消注释，否则追加
    if grep -q "^#\[multilib\]" /etc/pacman.conf; then
        sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
        sed -i 's|^#Include = /etc/pacman.d/mirrorlist|Include = /etc/pacman.d/mirrorlist|' /etc/pacman.conf
    else
        cat >> /etc/pacman.conf << 'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
    fi
    retry pacman -Sy --noconfirm
    log "✅ multilib 仓库已启用"
else
    log "✅ multilib 仓库已启用"
fi

# 🚀 第一步：系统更新与基础工具
log "更新系统与密钥环..."
retry pacman -Sy --noconfirm archlinux-keyring
retry pacman -Syu --noconfirm --needed \
    bash bash-completion \
    git vim curl wget unzip zip p7zip \
    fzf ripgrep zsh-completions \
    btrfs-progs \
    linux-zen linux-zen-headers \
    linux-lts linux-lts-headers \
    amd-ucode \
    networkmanager wpa_supplicant \
    bluez bluez-utils \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack \
    xdg-user-dirs xdg-utils \
    man-db man-pages \
    sudo 

# 重新生成 boot 配置（新内核安装后 GRUB/mkinitcpio 需要刷新）
log "重新生成 boot 配置..."
if command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
fi
mkinitcpio -P 2>/dev/null || true
log "✅ zen + lts 内核及 amd-ucode 已安装"

# 🐧 第二步：用户权限配置
log "配置用户权限..."
# 确保目标组存在（全新系统可能没有这些组）
for g in network disk input kvm libvirt tun dialout gamemode; do
    groupadd -f "$g" || true
done
# 加入当前 xuhuan 用户所在的组（wheel,network,disk,input,kvm,libvirt,tun,dialout,gamemode；不含 ollama）
usermod -aG wheel,network,disk,input,kvm,libvirt,tun,dialout,gamemode "${REAL_USER}" || true
if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
    echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/99-wheel
    chmod 440 /etc/sudoers.d/99-wheel
    log "✅ wheel 组已获得 sudo 权限"
fi
log "✅ 用户已加入: wheel,network,disk,input,kvm,libvirt,tun,dialout,gamemode"

# ============================================================
# 🖥️ 第三步：桌面环境（根据用户选择）
# ============================================================

# --- 安装基础图形栈（所有桌面环境共用）---
log "安装基础图形栈..."
retry pacman -S --noconfirm --needed \
    xorg-server xorg-xinit xorg-xrandr xorg-xwayland \
    mesa vulkan-radeon libva-mesa-driver \
    xf86-video-amdgpu vulkan-tools libva-utils \
    xdg-desktop-portal xdg-desktop-portal-gnome \
    polkit polkit-kde-agent \
    qt5-base qt5-wayland qt6-base qt6-wayland \
    libinput \
    foot kitty \
    zenity

# --- 安装 SDDM（显示管理器）---
log "安装 SDDM 显示管理器..."
retry pacman -S --noconfirm --needed sddm
systemctl enable sddm.service || true
log "✅ SDDM 已安装并设为开机自启"

# --- 根据选择安装各桌面环境 ---

# 检查是否选择了 KDE
if echo "$SELECTED_DESKTOPS" | grep -qw "kde"; then
    log "安装 KDE Plasma 6..."
    retry pacman -S --noconfirm --needed \
        plasma-meta \
        sddm-kcm
    log "✅ KDE Plasma 6 已安装"
fi

# 检查是否选择了 SonicDE
if echo "$SELECTED_DESKTOPS" | grep -qw "sonicde"; then
    log "配置 SonicDE 仓库..."
    # 添加 SonicDE 仓库的 GPG 密钥
    if ! pacman-key --list-keys 3B87898C73F11DF5 &>/dev/null; then
        curl -O https://sonicde-arch.github.io/sonicde-archlinux.asc
        pacman-key --add sonicde-archlinux.asc
        pacman-key --finger 3B87898C73F11DF5
        pacman-key --lsign-key 3B87898C73F11DF5
        rm -f sonicde-archlinux.asc
        log "✅ SonicDE GPG 密钥已添加"
    fi

    # 添加 SonicDE 仓库到 pacman.conf
    if ! grep -q "^\[sonicde\]" /etc/pacman.conf; then
        tee -a /etc/pacman.conf << 'EOF'

[sonicde]
Server = https://sonicde-arch.github.io/$arch
EOF
        retry pacman -Syyu --noconfirm
        log "✅ SonicDE 仓库已添加"
    fi

    log "安装 SonicDE..."
    retry pacman -S --noconfirm --needed sonicde-meta
    log "✅ SonicDE 已安装"
fi

# 检查是否选择了 Niri
if echo "$SELECTED_DESKTOPS" | grep -qw "niri"; then
    log "安装 Niri..."
    retry pacman -S --noconfirm --needed \
        niri \
        waybar \
        swaybg grim slurp wl-clipboard \
        udiskie \
        polkit-gnome \
        awww

    # 安装 xwayland-satellite (AUR)
    if command -v xwayland-satellite >/dev/null 2>&1; then
        log "✅ xwayland-satellite 已安装"
    elif command -v paru >/dev/null 2>&1; then
        retry sudo -H -u "${REAL_USER}" paru -S --noconfirm --needed xwayland-satellite
        log "✅ xwayland-satellite 已通过 paru 安装 (AUR)"
    else
        warn "未找到 paru，跳过 xwayland-satellite 安装 (手动: paru -S xwayland-satellite)"
    fi
    log "✅ Niri + Waybar + udiskie 已安装"
fi

# 检查是否选择了 i3
if echo "$SELECTED_DESKTOPS" | grep -qw "i3"; then
    log "安装 i3..."
    retry pacman -S --noconfirm --needed \
        i3-wm i3status dmenu rofi \
        feh picom
    log "✅ i3 已安装"
fi

# --- 安装 zsh 及组件（所有环境共用）---
log "安装 zsh 及组件..."
# 官方仓库组件已在第一步安装 (zsh zsh-autosuggestions zsh-syntax-highlighting zsh-autocomplete)
# AUR: zsh-vi-mode + zsh-theme-powerlevel10k
if command -v paru >/dev/null 2>&1; then
    retry sudo -H -u "${REAL_USER}" paru -S --noconfirm --needed \
        zsh-vi-mode zsh-theme-powerlevel10k
    log "✅ zsh-vi-mode + powerlevel10k 已安装 (AUR)"
fi
# zsh-vi-mode 手动安装 fallback（AUR 失败时）
if [[ ! -d /usr/share/zsh/plugins/zsh-vi-mode ]]; then
    log "手动安装 zsh-vi-mode..."
    sudo git clone --depth 1 https://github.com/jeffreytse/zsh-vi-mode /usr/share/zsh/plugins/zsh-vi-mode 2>/dev/null \
        && log "✅ zsh-vi-mode 已手动安装" \
        || warn "zsh-vi-mode 安装失败，可稍后手动: git clone https://github.com/jeffreytse/zsh-vi-mode /usr/share/zsh/plugins/zsh-vi-mode"
fi
# powerlevel10k 手动安装 fallback（AUR 失败时）
if [[ ! -d /usr/share/zsh/plugins/powerlevel10k ]]; then
    log "手动安装 powerlevel10k..."
    sudo git clone --depth 1 https://github.com/romkatv/powerlevel10k /usr/share/zsh/plugins/powerlevel10k 2>/dev/null \
        && log "✅ powerlevel10k 已手动安装" \
        || warn "powerlevel10k 安装失败，可稍后手动: git clone https://github.com/romkatv/powerlevel10k /usr/share/zsh/plugins/powerlevel10k"
fi
# oh-my-zsh: 手动 clone 到 ~/.oh-my-zsh（.zshrc 写死此路径，AUR/CN 源包路径不符）
if [[ ! -d "${HOME_DIR}/.oh-my-zsh/.git" ]]; then
    log "安装 oh-my-zsh 到 ~/.oh-my-zsh..."
    sudo -H -u "${REAL_USER}" git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "${HOME_DIR}/.oh-my-zsh" 2>/dev/null \
        && log "✅ oh-my-zsh 已安装到 ~/.oh-my-zsh" \
        || warn "oh-my-zsh 安装失败，可稍后手动: git clone https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh"
fi

# ============================================================
# 🖥️ 第三步半：克隆仓库与复制配置
# ============================================================

# --- 克隆 xuhuan-config 仓库 ---
log "克隆 xuhuan-config 仓库..."
REPO_DIR="${HOME_DIR}/xuhuan-config"
if [[ -d "${REPO_DIR}/.git" ]]; then
    log "✅ ${REPO_DIR} 已存在，跳过克隆"
elif command -v git >/dev/null 2>&1; then
    log "开始克隆 xuhuan-config 仓库（失败将自动重试）..."
    clone_attempt=0
    while true; do
        clone_attempt=$((clone_attempt + 1))
        if sudo -H -u "${REAL_USER}" git clone https://github.com/2112992430/xuhuan-config "${REPO_DIR}" 2>/dev/null; then
            log "✅ 仓库已克隆到 ${REPO_DIR}（第 ${clone_attempt} 次尝试成功）"
            break
        else
            warn "⚠️  第 ${clone_attempt} 次克隆失败，5 秒后重试..."
            rm -rf "${REPO_DIR}"
            sleep 5
        fi
    done
else
    warn "未找到 git，回退使用脚本所在目录"
    REPO_DIR="${SCRIPT_DIR}"
fi

# --- 根据选择的桌面环境复制配置 ---

# Niri 配置
if echo "$SELECTED_DESKTOPS" | grep -qw "niri"; then
    log "复制 Niri 配置..."
    mkdir -p "${HOME_DIR}/.config/niri"
    if [[ -f "${REPO_DIR}/.config/niri/config.kdl" ]]; then
        cp "${REPO_DIR}/.config/niri/config.kdl" "${HOME_DIR}/.config/niri/config.kdl"
        chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.config/niri"
        log "✅ niri 配置已从仓库复制"
    else
        warn "仓库中未找到 .config/niri/config.kdl，跳过"
    fi

    log "复制 Waybar 配置..."
    mkdir -p "${HOME_DIR}/.config/waybar"
    if [[ -d "${REPO_DIR}/.config/waybar" ]]; then
        cp -r "${REPO_DIR}/.config/waybar/." "${HOME_DIR}/.config/waybar/"
        chmod +x "${HOME_DIR}"/.config/waybar/scripts/*.sh 2>/dev/null || true
        chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.config/waybar"
        log "✅ waybar 配置已从仓库复制 (含 scripts)"
    else
        warn "仓库中未找到 .config/waybar，跳过"
    fi

    log "复制 udiskie 配置..."
    mkdir -p "${HOME_DIR}/.config/udiskie"
    if [[ -f "${REPO_DIR}/.config/udiskie/config.yml" ]]; then
        cp "${REPO_DIR}/.config/udiskie/config.yml" "${HOME_DIR}/.config/udiskie/config.yml"
        chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.config/udiskie"
        log "✅ udiskie 配置已从仓库复制"
    else
        # 仓库没有时写入一份最小可用配置
        cat > "${HOME_DIR}/.config/udiskie/config.yml" << 'EOF'
program_options:
  tray: auto
  notify: true
  automount: true
  password_cache: true
  file_manager: thunar
EOF
        chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.config/udiskie"
        log "✅ udiskie 默认配置已写入 ~/.config/udiskie/config.yml"
    fi
fi

# i3 配置
if echo "$SELECTED_DESKTOPS" | grep -qw "i3"; then
    log "复制 i3 配置..."
    mkdir -p "${HOME_DIR}/.config/i3"
    if [[ -f "${REPO_DIR}/.config/i3/config" ]]; then
        cp "${REPO_DIR}/.config/i3/config" "${HOME_DIR}/.config/i3/config"
        chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.config/i3"
        log "✅ i3 配置已从仓库复制"
    else
        warn "仓库中未找到 .config/i3/config，跳过"
    fi
fi

# 通用配置（kitty 等，所有环境可用）
log "复制 kitty 配置..."
mkdir -p "${HOME_DIR}/.config/kitty"
if [[ -f "${REPO_DIR}/.config/kitty/kitty.conf" ]]; then
    cp "${REPO_DIR}/.config/kitty/kitty.conf" "${HOME_DIR}/.config/kitty/kitty.conf"
    chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.config/kitty"
    log "✅ kitty 配置已从仓库复制"
fi

# --- 复制 zsh 配置（从仓库）---
log "复制 zsh 配置 (.zshrc + .p10k.zsh)..."
if [[ -f "${REPO_DIR}/.zshrc" ]]; then
    cp "${REPO_DIR}/.zshrc" "${HOME_DIR}/.zshrc"
    chown "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.zshrc"
    log "✅ .zshrc 已从仓库复制"
else
    warn "仓库中未找到 .zshrc，跳过"
fi
if [[ -f "${REPO_DIR}/.p10k.zsh" ]]; then
    cp "${REPO_DIR}/.p10k.zsh" "${HOME_DIR}/.p10k.zsh"
    chown "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.p10k.zsh"
    log "✅ .p10k.zsh 已从仓库复制"
else
    warn "仓库中未找到 .p10k.zsh，跳过"
fi

# --- 设置默认 shell 为 zsh ---
log "设置默认 shell 为 zsh..."
if command -v zsh >/dev/null 2>&1; then
    chsh -s /usr/bin/zsh "${REAL_USER}" 2>/dev/null \
        && log "✅ ${REAL_USER} 默认 shell 已设为 zsh" \
        || warn "chsh 失败，可稍后手动: chsh -s /usr/bin/zsh ${REAL_USER}"
else
    warn "zsh 未安装，跳过默认 shell 设置"
fi

# 🐱 第四步：输入法 Fcitx5
log "安装配置 Fcitx5..."
retry pacman -S --noconfirm --needed \
    fcitx5 fcitx5-chinese-addons fcitx5-configtool \
    fcitx5-gtk fcitx5-qt \
    fcitx5-material-color

mkdir -p "${HOME_DIR}/.config/fcitx5"
cat > /etc/environment << EOF
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
GLFW_IM_MODULE=fcitx
EOF
log "✅ fcitx5 环境变量已写入 /etc/environment"

# 🖥️ 第四步半：X11 会话配置 (.xinitrc / .xprofile，仅当选择 i3 时配置 startx 入口)
log "配置 X11 会话 (.xinitrc / .xprofile)..."
if echo "$SELECTED_DESKTOPS" | grep -qw "i3"; then
    cat > "${HOME_DIR}/.xinitrc" << EOF
#!/bin/sh
# X11 会话启动 (startx → i3)
# 注意: startx 只读 .xinitrc，不读 .xprofile，所以变量必须在这里
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export GLFW_IM_MODULE=fcitx
exec i3
EOF
    chmod +x "${HOME_DIR}/.xinitrc"
    chown "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.xinitrc"
    log "✅ .xinitrc 已配置 (startx → i3)"
fi
cat > "${HOME_DIR}/.xprofile" << EOF
#!/bin/sh
# X11 会话环境变量 (Display Manager 登录时读取)
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export GLFW_IM_MODULE=fcitx
EOF
chmod +x "${HOME_DIR}/.xprofile"
chown "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.xprofile"
log "✅ .xprofile 已配置 (fcitx5 环境变量)"

# 🐳 第五步：虚拟化 + jiasuqi 虚拟机脚本
log "设置虚拟化..."
retry pacman -S --noconfirm --needed libvirt virt-manager qemu-full dnsmasq virt-viewer
systemctl enable libvirtd.service || true
log "✅ libvirtd 已启用"

log "复制 jiasuqi 虚拟机脚本..."
if [[ -d "${REPO_DIR}/jiasuqi" ]]; then
    mkdir -p "${HOME_DIR}/jiasuqi"
    cp -r "${REPO_DIR}/jiasuqi/." "${HOME_DIR}/jiasuqi/"
    chmod +x "${HOME_DIR}/jiasuqi/vm-cli.sh" 2>/dev/null || true
    chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/jiasuqi"
    log "✅ jiasuqi 已复制 (vm-cli.sh + linux/jiasuqi.conf)"
else
    warn "仓库中未找到 jiasuqi/，跳过"
fi

# 👾 第六步：游戏与多媒体
log "安装游戏与多媒体..."
retry pacman -S --noconfirm --needed \
    steam \
    wine winetricks \
    lutris \
    obs-studio \
    mpv vlc ffmpeg \
    gamemode lib32-gamemode \
    mangohud lib32-mangohud \
    steam-devices

# 📁 第七步：文件管理与系统工具
log "安装文件管理与监控工具..."
retry pacman -S --noconfirm --needed \
    thunar gvfs file-roller tumbler ffmpegthumbnailer \
    btop htop fastfetch \
    acpi lm_sensors smartmontools iotop nethogs \
    dnsutils iputils net-tools openssh rsync \
    ipset iptables iproute2 \
    gzip bzip2 xz zstd \
    aria2

# 🌐 第八步：网络与主机名
log "配置网络..."
hostnamectl set-hostname arch-pc || true
systemctl enable NetworkManager.service || true
systemctl enable sshd.service || true
if [[ ! -f "${HOME_DIR}/.ssh/id_ed25519" ]]; then
    mkdir -p "${HOME_DIR}/.ssh"
    ssh-keygen -t ed25519 -f "${HOME_DIR}/.ssh/id_ed25519" -N "" || true
    chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.ssh"
    log "✅ SSH 密钥已生成"
fi

# 📊 第九步：系统优化
log "优化系统..."
if ! grep -q "vm.swappiness" /etc/sysctl.d/99-custom.conf 2>/dev/null; then
    echo "vm.swappiness=30" >> /etc/sysctl.d/99-custom.conf
fi
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-amdgpu.conf << 'EOF'
Section "Device"
    Identifier "AMD"
    Driver "modesetting"
    Option "TearFree" "true"
EndSection
EOF
log "✅ 系统优化已应用"

# 🌐 第十步：GRUB 引导与美化 (hyperfluent 主题)
log "配置 GRUB 引导与 hyperfluent 主题..."
retry pacman -S --noconfirm --needed grub efibootmgr os-prober

THEME_SRC="${REPO_DIR}/grub-themes/hyperfluent"

# UEFI / BIOS 自动检测并安装 GRUB
if [[ -d /sys/firmware/efi ]]; then
    EFI_DIR=""
    for d in /boot /efi /boot/efi; do
        if [[ -d "$d/EFI" ]]; then EFI_DIR="$d"; break; fi
    done
    EFI_DIR="${EFI_DIR:-/boot}"
    if ! grub-install --target=x86_64-efi --efi-directory="$EFI_DIR" --bootloader-id=Archlinux &>/dev/null; then
        warn "grub-install 失败，请检查 EFI 挂载点 (当前尝试: $EFI_DIR)"
    else
        log "✅ GRUB 已安装到 EFI ($EFI_DIR)"
    fi
else
    ROOT_DISK=$(lsblk -no pkname "$(findmnt -no source /)" 2>/dev/null)
    if [ -n "$ROOT_DISK" ]; then
        grub-install "/dev/${ROOT_DISK}" 2>/dev/null || warn "GRUB 安装失败（BIOS 模式），请手动执行 grub-install /dev/sdX"
    else
        warn "无法自动检测根磁盘，请手动执行 grub-install /dev/sdX"
    fi
fi

# 复制 hyperfluent 主题
mkdir -p /boot/grub/themes
if [[ -d "$THEME_SRC" ]]; then
    cp -r "$THEME_SRC" /boot/grub/themes/
    chmod -R 755 /boot/grub/themes/hyperfluent
    log "✅ hyperfluent 主题已复制到 /boot/grub/themes/"
else
    warn "未找到 ${THEME_SRC}，跳过主题配置"
fi

# 写入 /etc/default/grub（复刻当前配置）
cat > /etc/default/grub << 'EOF'
#boot loader configuration

GRUB_DEFAULT=saved
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash zswap.enabled=0"
GRUB_CMDLINE_LINUX=""

# Preload both GPT and MBR modules so that they are not missed
GRUB_PRELOAD_MODULES="part_gpt part_msdos"

# Set to 'countdown' or 'hidden' to change timeout behavior,
# press ESC key to display menu.
GRUB_TIMEOUT_STYLE=menu

# The resolution used on graphical terminal
GRUB_GFXMODE=auto

# Uncomment to allow the kernel use the same resolution used by grub
GRUB_GFXPAYLOAD_LINUX=keep

# Uncomment to disable generation of recovery mode menu entries
GRUB_DISABLE_RECOVERY=true

# GRUB Theme: hyperfluent
GRUB_THEME="/boot/grub/themes/hyperfluent/theme.txt"

# Make GRUB remember the last selection
GRUB_SAVEDEFAULT=true

# Probing for other operating systems (Windows dual-boot)
GRUB_DISABLE_OS_PROBER=false
EOF
log "✅ /etc/default/grub 已配置 (hyperfluent 主题)"

# 生成 grub.cfg
if grub-mkconfig -o /boot/grub/grub.cfg; then
    log "✅ grub.cfg 已生成"
else
    warn "grub-mkconfig 失败，请手动执行"
fi

# 🧊 第十一步：Ryzen 温控墙 (使用仓库中的动态温控脚本)
log "配置 Ryzen 5 5500U 动态温控墙..."

# 11.1 安装 ryzenadj (AUR)
if ! command -v ryzenadj &>/dev/null; then
    if command -v paru &>/dev/null; then
        retry sudo -H -u "${REAL_USER}" paru -S --noconfirm --needed ryzenadj
        log "✅ ryzenadj 已通过 paru 安装 (AUR)"
    else
        warn "未找到 paru，跳过 ryzenadj 安装 (手动: paru -S ryzenadj)"
    fi
else
    log "✅ ryzenadj 已安装"
fi

# 11.2 从仓库复制动态温控脚本
if [[ -f "${REPO_DIR}/ryzenadj-optimization.sh" ]]; then
    install -m 0755 "${REPO_DIR}/ryzenadj-optimization.sh" /usr/local/bin/ryzenadj-optimization.sh
    log "✅ ryzenadj-optimization.sh 已从仓库复制到 /usr/local/bin/"
else
    warn "仓库中未找到 ryzenadj-optimization.sh，跳过 (请确认仓库根目录含该文件)"
fi

# 11.3 写入 systemd 服务
# 注意: 仓库中的脚本是【持续运行】的动态温控脚本 (while true 循环),
#       因此必须使用 Type=simple + Restart=always, 不能用 Type=oneshot。
cat > /etc/systemd/system/ryzenadj-optimization.service << 'EOF'
[Unit]
Description=Ryzen 5 5500U 动态温控墙 (动态调节功耗上限)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ryzenadj-optimization.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 11.4 启用并立即启动
systemctl daemon-reload
if systemctl enable --now ryzenadj-optimization.service; then
    log "✅ Ryzen 动态温控墙已配置并设为开机自启"
else
    warn "systemctl enable --now 失败, 请检查: systemctl status ryzenadj-optimization.service"
fi

# 🖼️ 第十二步：壁纸 (从仓库复制 + 轮换)
log "配置壁纸与轮换..."

# 12.1 从仓库复制壁纸到 ~/wallpapers（仓库内有莫宁女仆系列 11 张）
if [[ -d "${REPO_DIR}/wallpapers" ]]; then
    mkdir -p "${HOME_DIR}/wallpapers"
    cp -r "${REPO_DIR}/wallpapers/." "${HOME_DIR}/wallpapers/"
    chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/wallpapers"
    log "✅ 壁纸已从仓库复制到 ~/wallpapers ($(ls "${HOME_DIR}/wallpapers" | wc -l) 张)"
elif [[ -d "${HOME_DIR}/wallpapers" ]]; then
    log "✅ 检测到已有壁纸目录 ~/wallpapers"
else
    warn "仓库与本地均无壁纸目录，跳过壁纸配置 (可从 GitHub 拉取: 2112992430/awww-)"
fi

# 12.2 复制 random-wallpaper-awww.sh（从仓库）
if [[ -f "${REPO_DIR}/.local/bin/random-wallpaper-awww.sh" ]]; then
    mkdir -p "${HOME_DIR}/.local/bin"
    cp "${REPO_DIR}/.local/bin/random-wallpaper-awww.sh" "${HOME_DIR}/.local/bin/"
    chmod +x "${HOME_DIR}/.local/bin/random-wallpaper-awww.sh"
    chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.local/bin"
    log "✅ random-wallpaper-awww.sh 已复制到 ~/.local/bin/"
fi

# 12.3 niri 配置中确认壁纸轮换启动项
if echo "$SELECTED_DESKTOPS" | grep -qw "niri"; then
    if [[ -d "${HOME_DIR}/wallpapers" ]]; then
        if ! grep -q "random-wallpaper-awww" "${HOME_DIR}/.config/niri/config.kdl" 2>/dev/null; then
            warn "niri 配置中未找到 random-wallpaper 启动项，请手动在 config.kdl 添加 spawn"
        fi
    fi
fi

# 🎨 第十三步：Wallpaper Engine (wine + xwinwrap, 仅 X11/i3)
if echo "$SELECTED_DESKTOPS" | grep -qw "i3"; then
    log "配置 Wallpaper Engine (wine)..."
    if ! command -v xwinwrap &>/dev/null; then
        if command -v paru >/dev/null 2>&1; then
            retry sudo -H -u "${REAL_USER}" paru -S --noconfirm --needed xwinwrap-git \
                && log "✅ xwinwrap-git 已通过 paru 安装 (AUR)" \
                || warn "xwinwrap-git 安装失败，可稍后手动: paru -S xwinwrap-git"
        else
            warn "未找到 paru，跳过 xwinwrap-git 安装 (手动: paru -S xwinwrap-git)"
        fi
    fi
    if [[ ! -d "${HOME_DIR}/wallpaper-engine-using-wine" ]]; then
        info "提示: 未找到 ~/wallpaper-engine-using-wine，请手动配置:"
        info "  git clone https://github.com/m3t4f1v3/wallpaper-engine-using-wine ~/wallpaper-engine-using-wine"
        info "  并按仓库 README 配置 steam 路径、壁纸 ID、项目名"
    else
        log "✅ 检测到 ~/wallpaper-engine-using-wine"
        if ! grep -q "wallpaper-engine-using-wine" "${HOME_DIR}/.config/i3/config" 2>/dev/null; then
            cat >> "${HOME_DIR}/.config/i3/config" << EOF

# Wallpaper Engine via wine (X11 only, xwinwrap desktop layer)
exec --no-startup-id sleep 10 && ${HOME_DIR}/wallpaper-engine-using-wine/start.sh
EOF
            log "✅ i3 已添加 wallpaper-engine 开机自启"
        fi
    fi
fi

# 🛠️ 第十四步：鸣潮启动器修复脚本 (wuwalauncherfix.sh)
log "配置鸣潮启动器修复脚本..."
# 依赖 bbe (binary block editor)，wuwalauncherfix.sh 用它修补 launcher_main.dll
if command -v bbe >/dev/null 2>&1; then
    log "✅ bbe 已安装"
else
    if command -v paru >/dev/null 2>&1; then
        retry sudo -H -u "${REAL_USER}" paru -S --noconfirm --needed bbe \
            && log "✅ bbe 已通过 paru 安装" \
            || warn "bbe 安装失败，可稍后手动: paru -S bbe"
    else
        warn "未找到 paru，跳过 bbe 安装 (手动: paru -S bbe)"
    fi
fi
# 复制 wuwalauncherfix.sh 到 ~/.local/bin/
if [[ -f "${REPO_DIR}/wuwalauncherfix.sh" ]]; then
    mkdir -p "${HOME_DIR}/.local/bin"
    cp "${REPO_DIR}/wuwalauncherfix.sh" "${HOME_DIR}/.local/bin/"
    chmod +x "${HOME_DIR}/.local/bin/wuwalauncherfix.sh"
    chown -R "${REAL_USER}:${REAL_USER}" "${HOME_DIR}/.local/bin"
    log "✅ wuwalauncherfix.sh 已复制到 ~/.local/bin/ (鸣潮启动器修复)"
else
    warn "仓库中未找到 wuwalauncherfix.sh，跳过"
fi

# 🎉 完成
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
log "🎉 配置完成！用时 ${ELAPSED} 秒"
info "建议重启系统: sudo reboot"
info ""
info "本次配置包含:"
info "  ✅ 国内镜像源 (reflector) + ArchLinuxCN + paru"
info "  ✅ 已选择桌面环境: ${SELECTED_DESKTOPS}"
info "  ✅ SDDM 显示管理器 (开机自启)"
info "  ✅ Fcitx5 中文输入法 (所有环境已配置)"
info "  ✅ Steam + Wine + Lutris + 游戏优化 (gamemode/mangohud)"
info "  ✅ libvirt + QEMU-Full 虚拟化 + virt-viewer + jiasuqi 脚本"
info "  ✅ 连点器 (ydotool, Wayland+X11 通用)"
info "  ✅ 鸣潮启动器修复脚本 (wuwalauncherfix.sh + bbe)"
info "  ✅ 网络工具 (ipset/iptables/iproute2/aria2)"
info "  ✅ 用户组已同步 (wheel/network/disk/input/kvm/libvirt/tun/dialout/gamemode)"
info "  ✅ OBS / mpv / VLC 多媒体"
info "  ✅ btop/fastfetch 监控工具"
info "  ✅ SSH + NetworkManager 网络服务"
info "  ✅ GRUB + hyperfluent 主题美化"
info "  ✅ Ryzen 动态温控墙 (仓库脚本 ryzenadj-optimization.sh, systemd Type=simple)"
info "  ✅ 壁纸轮换 + Wallpaper Engine (仅 i3)"
info "  ✅ Niri 通知/挂载: udiskie (U 盘自动挂载 + 托盘 + 通知)"
info ""
info "安装后建议手动操作:"
info "  1. 配置 ~/wallpaper-engine-using-wine (如未 clone: git clone https://github.com/m3t4f1v3/wallpaper-engine-using-wine)"
info "  2. 鸣潮启动器修复: ~/.local/bin/wuwalauncherfix.sh (需 wine 已装鸣潮)"
info "  3. 若仓库壁纸不足，可额外拉取: git clone https://github.com/2112992430/awww- ~/wallpapers-extra"
info "  4. KDE/SonicDE 首次登录后可在系统设置中调整 SDDM 主题"
info "  5. 检查动态温控服务状态: systemctl status ryzenadj-optimization.service"
info "  6. Niri 中确认 config.kdl 已有: spawn-at-startup \"udiskie\" \"--tray\""
info "     若无，可手动添加；polkit 授权代理用 polkit-gnome 已在 niri 环境装好"

exit 0
