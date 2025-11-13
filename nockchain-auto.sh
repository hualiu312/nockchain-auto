#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

################################################################################
# 本脚本由 blog.deep123.top 制作而成
# 名称：Nockchain 全自动化编译安装与运行脚本
# 功能：自动检测依赖、安装环境、克隆源码、编译安装、生成密钥、运行节点/矿工、
#       以及创建 systemd 服务单元，带完整交互式功能菜单。
# 版权说明：本脚本可自由修改与分发，但请保留来源声明 blog.deep123.top
################################################################################

# nockchain-auto.sh
# 全自动化：依赖安装、clone、编译、安装、systemd 服务、wallet/key 管理 与 交互式菜单
# 参考 README: Nockchain project. See: README.md. :contentReference[oaicite:1]{index=1}

################################################################################
# Configuration (可按需修改)
################################################################################
REPO_URL="${REPO_URL:-https://github.com/zorp-corp/nockchain.git}"
WORKDIR="${WORKDIR:-$HOME/nockchain}"
ENV_FILE="${ENV_FILE:-$WORKDIR/.env}"
SYSTEMD_DIR="/etc/systemd/system"
LOGDIR="${LOGDIR:-/var/log/nockchain}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"   # 或指定 nightly
APT_PKGS=(clang llvm-dev libclang-dev make protobuf-compiler build-essential pkg-config cmake git)
# Optional kernel settings
SET_SYSCTL_OVERCOMMIT=true
SET_PERF_PTRACE=false   # 改为 true 可同时设置 perf/ptrace（需要谨慎）

################################################################################
# Helpers
################################################################################
timestamp(){ date +'%Y-%m-%d %H:%M:%S'; }
log(){ echo "[$(timestamp)] $*"; }
abort(){ echo "ERROR: $*"; exit 1; }

ensure_sudo(){
  if [ "$EUID" -ne 0 ]; then
    echo "某些步骤需要 sudo 权限。请按提示输入管理员密码。"
    if ! command -v sudo >/dev/null 2>&1; then
      abort "找不到 sudo，请以 root 用户运行或先安装 sudo。"
    fi
  fi
}

ensure_cmd(){
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

safe_run(){
  # wrapper to log commands, but continue on non-fatal errors if desired
  log "+ $*"
  "$@"
}

makedir_if_needed(){
  if [ ! -d "$1" ]; then
    mkdir -p "$1"
  fi
}

################################################################################
# Step tasks
################################################################################

install_apt_deps(){
  # Only for Debian/Ubuntu style systems
  if ! ensure_cmd apt-get; then
    log "apt-get not found — 跳过 apt 依赖安装，请在你的系统上手动安装: ${APT_PKGS[*]}"
    return 0
  fi
  log "更新 apt 并安装依赖: ${APT_PKGS[*]}"
  sudo apt-get update -y
  sudo apt-get install -y "${APT_PKGS[@]}"
}

install_rustup(){
  if ensure_cmd rustup cargo rustc; then
    log "rustup 已存在，确保 toolchain 为: ${RUST_TOOLCHAIN}"
    rustup default "${RUST_TOOLCHAIN}" || true
    return 0
  fi

  log "安装 rustup (非交互)，并安装 ${RUST_TOOLCHAIN} toolchain"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain "${RUST_TOOLCHAIN}"
  export PATH="$HOME/.cargo/bin:$PATH"
  rustup default "${RUST_TOOLCHAIN}"
  log "rustup 安装完成"
}

set_kernel_params(){
  if [ "$SET_SYSCTL_OVERCOMMIT" = true ]; then
    log "设置 vm.overcommit_memory=1（启用内存 overcommit）"
    echo 'vm.overcommit_memory=1' | sudo tee /etc/sysctl.d/99-overcommit.conf >/dev/null
    sudo sysctl --system || sudo sysctl -p /etc/sysctl.d/99-overcommit.conf || true
  fi

  if [ "$SET_PERF_PTRACE" = true ]; then
    log "设置 perf/ptrace（警告：会降低安全限制）"
    echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope >/dev/null || true
    echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null || true
    # 持久化
    sudo bash -c 'cat >/etc/sysctl.d/99-nockchain-perf.conf <<EOF
kernel.yama.ptrace_scope=0
kernel.perf_event_paranoid=1
EOF'
    sudo sysctl --system || true
  fi
}

clone_or_update_repo(){
  if [ -d "$WORKDIR/.git" ]; then
    log "仓库已存在，拉取最新改动: $WORKDIR"
    safe_run git -C "$WORKDIR" fetch --all --prune
    safe_run git -C "$WORKDIR" pull --ff-only || true
  else
    log "克隆仓库到 $WORKDIR"
    safe_run git clone "$REPO_URL" "$WORKDIR"
  fi
}

prepare_env(){
  if [ ! -f "$ENV_FILE" ] && [ -f "$WORKDIR/.env_example" ]; then
    log "复制 .env_example -> ${ENV_FILE}"
    cp "$WORKDIR/.env_example" "$ENV_FILE"
    log ".env 已创建，请编辑 ${ENV_FILE} 设置 MINING_PKH 等信息（脚本将继续）。"
  fi
}

build_install_all(){
  log "开始构建与安装（release）"

  cd "$WORKDIR"

  # 如果 Makefile 提供安装目标，优先使用 make（README 提到 make install-*）
  if [ -f Makefile ]; then
    log "执行 make install-hoonc"
    safe_run make install-hoonc || log "make install-hoonc 失败，继续尝试逐个 cargo build"
  fi

  # Build wallet & nockchain (release)
  if [ -d ./crates/nockchain-wallet ]; then
    log "构建 nockchain-wallet --release"
    safe_run cargo build --manifest-path crates/nockchain-wallet/Cargo.toml --release || abort "构建 wallet 失败"
    # 安装到 ~/.cargo/bin
    BIN_WALLET="$(cargo metadata --format-version 1 --no-deps | jq -r '.packages[] | select(.name=="nockchain-wallet") | .targets[0].name' 2>/dev/null || true)"
    # 直接调用 cargo install --path 也可
    safe_run cargo install --path crates/nockchain-wallet --force || true
  fi

  if [ -f Makefile ]; then
    log "执行 make install-nockchain"
    safe_run make install-nockchain || log "make install-nockchain 失败，尝试 cargo install"
  fi

  if [ -d ./crates/nockchain ]; then
    log "构建 nockchain --release"
    safe_run cargo build --manifest-path crates/nockchain/Cargo.toml --release || abort "构建 nockchain 失败"
    safe_run cargo install --path crates/nockchain --force || true
  fi

  # 确保 PATH 包含 cargo bin
  export PATH="$HOME/.cargo/bin:$PATH"
  log "构建完成。可执行文件位于: $HOME/.cargo/bin (若使用 cargo install)"
}

create_systemd_unit(){
  # Usage: create_systemd_unit node|miner <workdir> <envfile>
  local mode="${1:-node}"
  local workdir="${2:-$WORKDIR}"
  local envfile="${3:-$ENV_FILE}"
  makedir_if_needed "$LOGDIR"

  local unit_name="nockchain-${mode}.service"
  local exec_cmd=""
  if [ "$mode" = "miner" ]; then
    exec_cmd="/bin/bash -lc 'cd ${workdir} && ${HOME}/.cargo/bin/nockchain --mine --env-file ${envfile}'"
  else
    exec_cmd="/bin/bash -lc 'cd ${workdir} && ${HOME}/.cargo/bin/nockchain --env-file ${envfile}'"
  fi

  log "生成 systemd 单元: ${unit_name}"
  sudo bash -c "cat > ${SYSTEMD_DIR}/${unit_name} <<EOF
[Unit]
Description=Nockchain ${mode}
After=network.target

[Service]
Type=simple
User=${SUDO_USER:-$(whoami)}
WorkingDirectory=${workdir}
EnvironmentFile=${envfile}
ExecStart=${exec_cmd}
Restart=on-failure
LimitNOFILE=65536
StandardOutput=append:${LOGDIR}/${unit_name}.log
StandardError=append:${LOGDIR}/${unit_name}.err

[Install]
WantedBy=multi-user.target
EOF"

  sudo systemctl daemon-reload
  log "systemd 单元 ${unit_name} 已创建。启用并启动请使用： sudo systemctl enable --now ${unit_name}"
}

run_node_script(){
  log "开始以脚本方式运行节点（前台日志）"
  cd "$WORKDIR"
  export PATH="$HOME/.cargo/bin:$PATH"
  bash -c "cd ${WORKDIR} && bash ./scripts/run_nockchain_node.sh"
}

run_miner_script(){
  log "开始以脚本方式运行矿工（前台日志）"
  cd "$WORKDIR"
  export PATH="$HOME/.cargo/bin:$PATH"
  bash -c "cd ${WORKDIR} && bash ./scripts/run_nockchain_miner.sh"
}

wallet_keygen(){
  export PATH="$HOME/.cargo/bin:$PATH"
  if ! ensure_cmd nockchain-wallet; then
    abort "找不到 nockchain-wallet，请先构建/安装（菜单选项 4）"
  fi
  log "生成新密钥对（nockchain-wallet keygen）"
  nockchain-wallet keygen
}

wallet_export(){
  export PATH="$HOME/.cargo/bin:$PATH"
  if ! ensure_cmd nockchain-wallet; then
    abort "找不到 nockchain-wallet，请先构建/安装（菜单选项 4）"
  fi
  log "导出 keys： keys.export"
  nockchain-wallet export-keys --output keys.export || nockchain-wallet export-keys > keys.export
  log "已导出到 $(pwd)/keys.export"
}

run_fakenet(){
  log "设置并运行本地 fakenet 示例"
  cd "$WORKDIR"
  mkdir -p fakenet-hub fakenet-node
  cp "$ENV_FILE" fakenet-hub/ 2>/dev/null || true
  cp "$ENV_FILE" fakenet-node/ 2>/dev/null || true
  log "启动 hub (后台)"
  ( cd fakenet-hub && nohup bash ../scripts/run_nockchain_node_fakenet.sh > hub.out 2>&1 & )
  sleep 1
  log "启动 node (后台)"
  ( cd fakenet-node && nohup bash ../scripts/run_nockchain_miner_fakenet.sh > node.out 2>&1 & )
  log "fakenet 启动完成，查看 fakenet-hub/hub.out 以及 fakenet-node/node.out"
}

################################################################################
# Interactive menu
################################################################################

show_menu(){
  cat <<EOF

=== Nockchain 全自动化脚本菜单 ===
工作目录: ${WORKDIR}
.env 文件: ${ENV_FILE}

1) 安装系统依赖 (apt; Debian/Ubuntu)
2) 安装 rustup & toolchain (${RUST_TOOLCHAIN})
3) 设置内核 sysctl 参数 (overcommit, 可选 perf/ptrace)
4) 克隆或更新仓库并构建 & 安装 (release)
5) 生成或导出钱包密钥 (keygen / export)
6) 运行节点（前台） 或 运行矿工（前台）
7) 创建 systemd 服务 (节点/矿工)
8) 启动/停止/查看 systemd 服务 状态
9) 启动本地 fakenet 示例（多个实例）
0) 退出

请输入数字选择： 
EOF
}

menu_loop(){
  while true; do
    show_menu
    read -r choice
    case "$choice" in
      1)
        install_apt_deps
        ;;
      2)
        install_rustup
        ;;
      3)
        set_kernel_params
        ;;
      4)
        clone_or_update_repo
        prepare_env
        build_install_all
        ;;
      5)
        echo "a) 生成新密钥  b) 导出 keys  c) 取消"
        read -r sub
        case "$sub" in
          a|A) wallet_keygen ;;
          b|B) wallet_export ;;
          *) log "取消" ;;
        esac
        ;;
      6)
        echo "a) 运行节点 (run_nockchain_node.sh)  b) 运行矿工 (run_nockchain_miner.sh)  c) 取消"
        read -r sub
        case "$sub" in
          a|A) run_node_script ;;
          b|B) run_miner_script ;;
          *) log "取消" ;;
        esac
        ;;
      7)
        echo "创建 systemd 单元: 输入 node 或 miner（默认 node）:"
        read -r mode
        mode="${mode:-node}"
        create_systemd_unit "$mode" "$WORKDIR" "$ENV_FILE"
        ;;
      8)
        echo "输入服务名后缀: node 或 miner（默认 node）:"
        read -r svc
        svc="${svc:-node}"
        unit="nockchain-${svc}.service"
        echo "选择: 1) enable+start 2) stop+disable 3) status 4) journal 5) cancel"
        read -r act
        case "$act" in
          1) sudo systemctl enable --now "$unit" ;;
          2) sudo systemctl stop "$unit" && sudo systemctl disable "$unit" ;;
          3) sudo systemctl status "$unit" --no-pager ;;
          4) sudo journalctl -u "$unit" -f ;;
          *) log "取消" ;;
        esac
        ;;
      9)
        run_fakenet
        ;;
      0)
        log "退出"
        exit 0
        ;;
      *)
        log "无效选择: $choice"
        ;;
    esac
    echo
    read -p "按回车继续菜单..." _
  done
}

################################################################################
# Entrypoint
################################################################################
main(){
  log "Nockchain 全自动化脚本启动"
  makedir_if_needed "$LOGDIR"

  # ensure some commands exist for interactive steps
  if ! ensure_cmd git curl; then
    abort "本脚本需要 git 和 curl，请先安装。"
  fi

  menu_loop
}

main "$@"

