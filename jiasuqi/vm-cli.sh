#!/bin/bash
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE_DIR/linux/jiasuqi.conf"

: "${SPICE_PORT:=5930}"
: "${INTERFACE:=jiasuqi}"

mkdir -p "$BASE_DIR/vm"

# 限制到前两个逻辑核心 + 降低优先级，避免影响宿主机
TASKSET="taskset -c 0-1"
NICE="nice -n 10 ionice -c 2 -n 7"

sudo $TASKSET $NICE qemu-system-x86_64 \
    -name "Windows加速器" \
    -enable-kvm \
    -daemonize \
    -pidfile "$BASE_DIR/vm/qemu.pid" \
    -D "$BASE_DIR/vm/qemu.log" \
    -cpu host \
    -smp 2,sockets=1,cores=2,threads=1 \
    -m 2G \
    -overcommit mem-lock=off \
    -rtc base=localtime,clock=host,driftfix=slew \
    -machine usb=on,hpet=off \
    -display none \
    -vga virtio \
    -spice addr=127.0.0.1,port="$SPICE_PORT",disable-ticketing=on,streaming-video=off \
    -device usb-tablet \
    -device virtio-serial \
    -chardev spicevmc,id=vdagent,name=vdagent \
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
    -drive file="$BASE_DIR/vm/windows.img",if=virtio,cache=writeback,aio=io_uring \
    -netdev tap,id=net0,ifname="$INTERFACE",script="$BASE_DIR/linux/vm-up.sh",downscript="$BASE_DIR/linux/vm-down.sh",vhost=on \
    -device virtio-net-pci,netdev=net0 \
    -object memory-backend-memfd,id=mem,size=2G,share=on \
    -numa node,memdev=mem \
    -chardev socket,id=char0,path=/tmp/vhostqemu \
    -device vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=shared_win \
    "$@"

echo "QEMU 已后台启动，PID: $(cat "$BASE_DIR/vm/qemu.pid")"
echo "查看画面: remote-viewer --title Windows spice://127.0.0.1:$SPICE_PORT"
