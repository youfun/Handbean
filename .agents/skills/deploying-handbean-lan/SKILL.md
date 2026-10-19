---
name: deploying-handbean-lan
description: Deploys Handbean Web UI for trusted-LAN access on Windows, Linux, and macOS. Use when enabling --lan / -LanHost, LAN passwords, firewall ports, or diagnosing other devices that cannot open the Web UI.
---

# 局域网部署 Handbean Web UI

只用于受信任局域网。先读事实来源，再执行；不要把 GUI 宿主或 `mix phx.server`
当成局域网服务端。

## 先读

1. `docs/lan-deployment.md`：Windows / Linux / macOS 的逐步说明与边界。
2. `docs/security.md`：访问模式、明文 HTTP、反向代理与 TLS。
3. 当前的 `scripts/start.sh`、`scripts/start.ps1`、`scripts/start.bat`：实际
   导出的环境变量与校验。
4. 用户指定的包路径或仓库打包命令；包名与架构以 README 为准。

不要把示例 IP、端口、防火墙命令写进另一份配置。脚本不会猜测网卡。

## 下载 Web UI 包

没有现成解压目录、也不是从本仓库打包时，从 GitHub Releases 取 **Web UI** 包，
不要用 macOS/Windows 桌面 zip 当局域网服务端：

- 页面：<https://github.com/youfun/Handbean/releases>
- 滚动标签（当前预编译包）：<https://github.com/youfun/Handbean/releases/tag/web-latest>
- 固定版本：同一页的 `v*` 标签；不要把版本号写进本技能。

直接下载（把文件名换成对应架构）：

```text
https://github.com/youfun/Handbean/releases/download/web-latest/handbean-web-linux-x86_64.tar.gz
https://github.com/youfun/Handbean/releases/download/web-latest/handbean-web-linux-arm64.tar.gz
https://github.com/youfun/Handbean/releases/download/web-latest/handbean-web-macos-arm64.tar.gz
https://github.com/youfun/Handbean/releases/download/web-latest/handbean-web-windows-amd64.zip
```

Linux/macOS 的 tar 把 `start.sh` 放在归档根目录；Windows zip 根目录有 `start.bat`。
可选校验同名 `.sha256`。实验性 `handbean-web-windows-amd64-toolchain.zip` 不改变
局域网绑定语义。没有 Windows ARM64 包。

## 执行顺序

1. 确认目标是上述 Web UI 预编译包或仓库内生产 release，不是 `Handbean.app` /
   `Handbean.exe`，也不是开发服务器。
2. 向用户确认服务端主机名或 IPv4（其他设备实际会打开的地址，不含协议和端口）
   以及端口（默认 `5008`）。
3. 按服务端操作系统启动：

   ```bash
   # Linux / macOS，解压包
   ./start.sh --lan 192.168.1.10
   # 仓库内
   bash scripts/start.sh --lan 192.168.1.10
   ```

   ```powershell
   # Windows，解压包
   .\start.bat -LanHost 192.168.1.10
   # 仓库内（先用 scripts\build_webui.bat 构建并选择本地版本）
   .\start.bat -LanHost 192.168.1.10
   ```

4. 交互环境让启动脚本提示密码；无人值守才用宿主环境中的
   `HANDBEAN_ACCESS_PASSWORD`。不要把密码写入仓库、技能或聊天记录。
5. 仅在服务端防火墙放行所选 TCP 端口；不要对公网或访客网络开放。
6. 在另一台设备用 `http://HOST:PORT` 验证 Basic 认证和 LiveView，而不是只看
   服务端进程还在。

## 报告

分开写清：操作系统与架构、用的是解压包还是仓库 release、监听地址与端口、是否
已设密码（不要回显密码）、防火墙是否放行、访问端是否打开成功。

失败时先对照 `docs/lan-deployment.md` 的「不要做的事」：错误 HOST 格式、开发
模式来源校验、GUI 只绑环回、HSTS 强制 HTTPS、库/端口冲突。公网需求转到
`docs/security.md`，不要加局域网参数。
