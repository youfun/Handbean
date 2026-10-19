# 局域网部署（Windows / Linux / macOS）

把 Handbean Web UI 开放给**受信任局域网**里的其他设备。安全契约以
[`docs/security.md`](security.md) 为准；启动脚本以 `scripts/start.sh`、
`scripts/start.ps1`、`scripts/start.bat` 为准。不要把本页的示例 IP、端口或
命令当成另一套配置。

这不是公网部署。不要用局域网参数代替 TLS 反向代理。

## 适用与不适用

适用：

- GitHub Releases 的 Web UI 预编译包（解压后的 `start.sh` / `start.bat`）
- 仓库内打好的生产 release（Unix 启动脚本使用 `_build/prod/rel/handbean`；
  Windows 根启动器读取 `_build/local-webui/current.txt`）

不适用：

- `Handbean.app`（macOS）和 `Handbean.exe`（Windows）：只绑定环回地址，忽略
  非本机 host，不能当局域网服务端
- `mix phx.server`：开发模式只允许 `localhost` / `127.0.0.1` 来源，并打开
  调试页与热重载，不能当局域网入口
- 公网、酒店/咖啡厅 Wi-Fi、不可信访客网络、需要 TLS 的反向代理场景

Android / iOS 原生宿主不是这套 Web UI 局域网入口。

## 下载

预编译包在 [GitHub Releases](https://github.com/youfun/Handbean/releases)。
日常取滚动标签 [web-latest](https://github.com/youfun/Handbean/releases/tag/web-latest)；
固定版本用同页的 `v*` 标签。局域网用 Web UI 包，不要下载 `Handbean-macos-arm64.zip`
或 Windows 桌面程序当服务端：

| 系统 | 包 | 下载 |
|------|----|------|
| Linux x86_64 | `handbean-web-linux-x86_64.tar.gz` | [web-latest](https://github.com/youfun/Handbean/releases/download/web-latest/handbean-web-linux-x86_64.tar.gz) |
| Linux ARM64 | `handbean-web-linux-arm64.tar.gz` | [web-latest](https://github.com/youfun/Handbean/releases/download/web-latest/handbean-web-linux-arm64.tar.gz) |
| macOS Apple Silicon | `handbean-web-macos-arm64.tar.gz` | [web-latest](https://github.com/youfun/Handbean/releases/download/web-latest/handbean-web-macos-arm64.tar.gz) |
| Windows x86_64 | `handbean-web-windows-amd64.zip` | [web-latest](https://github.com/youfun/Handbean/releases/download/web-latest/handbean-web-windows-amd64.zip) |

每个包旁有同名 `.sha256`。tar/zip 的根目录就是启动脚本所在目录。暂无 Windows
ARM64 预编译包。

## 启动前确认

1. 服务跑在哪台机器上，就用**那台机器**被其他设备访问时使用的主机名或 IPv4，
   不要填访问端的地址。启动脚本不会猜测网卡。
2. HOST 不能带协议、端口、斜杠或空格。错误示例：`http://192.168.1.10:5008`。
3. 默认端口 `5008`，可用环境变量 `PORT` 覆盖。
4. 局域网模式会同时打开：全部 IPv4 网卡监听（`0.0.0.0`）、密码认证、明文
   HTTP。HTTP **不加密**密码、会话和通信内容。
5. 用户名默认 `handbean`，可用 `HANDBEAN_ACCESS_USERNAME` 覆盖。密码必须足够
   长、随机、不复用；脚本不把密码写到磁盘。
6. 正式库默认 `~/.handbean/handbean.db`（Windows 为 `%USERPROFILE%\.handbean\handbean.db`），
   可用 `DATABASE_PATH` 覆盖。工作区索引默认同目录 `workspaces.json`，可用
   `HANDBEAN_WORKSPACES_FILE` 覆盖。不要让本机 GUI 与 Web UI 同时打开同一个数据库。

查看本机 IPv4 时，选局域网那张网卡，不要用 `127.0.0.1`：

| 系统 | 查看地址（示例，以实际网卡为准） |
|------|----------------------------------|
| Linux | `ip -4 addr` 或 `hostname -I` |
| macOS | `ipconfig getifaddr en0`（Wi-Fi 也可能是 `en1`） |
| Windows | `ipconfig` |

## Linux 与 macOS

包名：`handbean-web-linux-x86_64.tar.gz`、`handbean-web-linux-arm64.tar.gz`、
`handbean-web-macos-arm64.tar.gz`。Apple Silicon 原生 `Handbean.app` 不能替代
下面的 Web UI 包。

解压包内：

```bash
./start.sh --lan 192.168.1.10
```

仓库内已打包生产 release：

```bash
bash scripts/pack_webui.sh linux-x86_64   # 或 linux-arm64 / macos-arm64
bash scripts/start.sh --lan 192.168.1.10
```

交互终端会提示输入密码且不回显。无终端或无人值守时，先在宿主环境提供
`HANDBEAN_ACCESS_PASSWORD`，不要把它写进仓库或提交记录。

其他设备打开 `http://192.168.1.10:5008`（把地址和端口换成实际值）。浏览器
可能因历史 HSTS 仍强制 HTTPS；局域网模式没有 TLS，应换浏览器配置或改用
未缓存该主机的环境。

防火墙只在服务端放行所选 TCP 端口，不要对公网开放。常见本机工具：

- Linux `ufw`：`sudo ufw allow 5008/tcp`
- Linux `firewalld`：`sudo firewall-cmd --add-port=5008/tcp`
- macOS：系统设置里的防火墙，或首次监听时的系统提示

云主机安全组、公司网关 ACL 不在启动脚本范围内，需要操作者单独放行。

## Windows

包名：`handbean-web-windows-amd64.zip`。暂无 Windows ARM64 预编译包。带开发
工具链的实验包同样用下面的局域网参数，不改变绑定与认证语义。Windows 发行包
没有浏览器内终端（Ghostty 无 Windows NIF）。

解压包内：

```powershell
.\start.bat -LanHost 192.168.1.10
```

仓库内本地构建的生产 release：

```powershell
.\scripts\build_webui.bat
.\start.bat -LanHost 192.168.1.10
```

`start.bat` 转调 `start.ps1`。HOST 规则与 Unix 相同：不要带 `http://` 或端口。

无人值守同样用宿主环境里的 `HANDBEAN_ACCESS_PASSWORD`。若 Windows Defender
防火墙拦截入站，为所选 TCP 端口添加仅限专用/专用局域网的入站规则，不要改成
对公用网络开放。

## 启动后应看到什么

局域网启动成功时，服务端日志会同时出现中英文强密码提醒，并类似：

```text
Listening: 0.0.0.0:5008 (password authentication required)
Address: http://192.168.1.10:5008
警告：HTTP 不加密密码或通信内容，仅用于受信任网络。
```

访问端使用 HTTP Basic：用户名默认 `handbean`，密码为本次启动设置的值。改用户名
或密码会使已有已认证会话失效。

## 不要做的事

- 不要把 `--lan` / `-LanHost` 用在公网 IP、端口转发或反向代理后面充当前端
- 不要把 `HANDBEAN_PUBLIC_BIND=1` 与 `HANDBEAN_ACCESS_MODE=local` 组合；非环回
  绑定必须密码模式
- 不要只开 `HANDBEAN_PUBLIC_BIND=1` 却指望自动明文 HTTP；明文 HTTP 需要
  `HANDBEAN_ALLOW_HTTP=1`（局域网启动脚本会设置）
- 不要把密码、`SECRET_KEY_BASE` 写进技能、文档示例的可复制提交内容里
- 不要让开发服务器、GUI 宿主和局域网 Web UI 争用同一端口或同一生产库

公网或 TLS 反向代理按 [`docs/security.md`](security.md) 配置，不要复用本页的
局域网参数。
