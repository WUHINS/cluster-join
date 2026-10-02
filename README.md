# 服务器集群并网脚本

交互式、`sh`/`bash`/TTY 全兼容的服务器集群并网工具：

- **Komari Agent** —— 轻量级自托管服务器监控探针，把每台机器的 CPU / 内存 / 磁盘 / 网络 / 在线状态汇总到一块面板。
- **EasyTier** —— 去中心化异地组网（SD-WAN / 虚拟局域网），支持 **Web 控制台托管**，配置由控制台统一下发。

一台机器跑一次脚本，就完成「接入监控面板 + 加入虚拟网络」两件事。

| 文件 | 作用 |
| --- | --- |
| `cluster-join.sh` | 节点侧主脚本：交互式菜单，安装并接入 Komari + EasyTier |
| `cluster-batch.sh` | 跳板机侧脚本：把 `cluster-join.sh` 并行下发到几十上百台机器 |
| `hosts.txt.example` | 批量下发的主机清单示例 |
| `cluster.env.example` | 节点配置样例（也可直接用环境变量） |
| `LICENSE` | MIT 许可证 |

---

## 1. 设计要点

### 1.1 三种运行环境都支持（这是重点）

| 运行方式 | 行为 |
| --- | --- |
| **交互式 TTY**（`sudo sh cluster-join.sh`） | 打印菜单，逐项提问，带默认值 |
| **管道执行**（`curl … \| sudo sh -s -- …`） | `stdin` 被脚本占用，脚本自动改从 `/dev/tty` 读输入，提问依旧可用 |
| **无终端 / 无人值守** | 全部走命令行参数与环境变量，**绝不挂起**；未提供的项使用默认值 |
| **`sh` 与 `bash`** | 纯 POSIX 语法，在 dash / ash / busybox sh / bash / mksh 下均可运行 |

脚本只有 `--yes` 或没有 TTY 时才走非交互分支；两者都不满足时会给出明确报错而不是静默乱装。

### 1.2 语言策略

**交互式 TTY 一律英文；非 TTY 按系统 locale 决定中/英。**

| 运行环境 | 消息语言 |
| --- | --- |
| 交互式 TTY（`sudo sh cluster-join.sh`） | **英文**（固定策略，不看 locale） |
| 非 TTY + 系统 locale 为 `zh*`（如 `zh_CN.UTF-8`） | 中文 |
| 非 TTY + 其它 locale，或 locale 未设置 | 英文 |

locale 判定顺序：`LC_ALL` → `LC_MESSAGES` → `LANG` → `LANGUAGE` → `/etc/locale.conf`、`/etc/default/locale`、`/etc/sysconfig/i18n` → `localectl status`。

需要显式指定时用 `--lang zh|en`（批量脚本也支持 `CLUSTER_BATCH_LANG`），显式指定优先于上面的自动策略：

```sh
sudo sh cluster-join.sh --all --yes --lang zh ...   # 非 TTY 也想看中文
```

**交互菜单里也能随时切**：主菜单第 9 项 `切换语言 / Switch language`，选完立即用新语言重绘菜单。
这是给「TTY 一律英文」留的显式出口，只对本次运行生效、不写入参数存档，因此不会和自动策略打架。
想永久生效就用 `--lang` / `CLUSTER_JOIN_LANG`。

英文模式下所有输出（banner、`--help`、`--status`、日志标签）都是纯 ASCII，便于日志采集和英文终端显示。

### 1.3 幂等与顺序

- 重复执行 = 重新下载最新二进制 + 重写服务单元 + 重启服务，不会产生重复服务。
- **支持服务运行中直接重装**：覆盖正在运行的可执行文件在 Linux 上会 `ETXTBSY`（`Text file busy`），
  因此二进制先下到目标目录内的暂存名，再用 `mv`（rename）原子替换——运行中的进程继续持有旧 inode，
  不受影响，随后由服务重启切到新二进制。
- 安装顺序固定为 **EasyTier 先、Komari 后**：这样当监控面板本身位于虚拟网络内（例如 `http://10.126.126.1:25774`）时，探针第一次上报就能连通。
- 参数会保存到 `/etc/cluster-join/cluster.env`（权限 `600`），下次换一个动作运行时会自动带出上次的配置。

### 1.4 职责边界：装完即脱手

脚本只负责**交付三样东西**，交完就退出，**不介入运行期**：

1. **可运行的二进制** —— 放到 `/opt/easytier`、`/opt/komari`（缺 `unzip` 等依赖会自动补装）
2. **所需的凭证** —— Komari 节点令牌写入 `0600` 的 `agent.json`；服务单元只通过 `--config` 引用它
3. **自启动注册** —— 写 systemd / OpenRC / procd 单元 → `enable` → `start`

交付完成后脚本立即返回：**不轮询、不等待、不做健康检查、不守护进程**。
运行期的一切（进程是否存活、有没有连上面板、控制台里有没有批准节点、虚拟网有没有打通）
都由运维与容器运行时负责。安装路径的最后一屏只是**事实汇报**（注册的服务名、面板地址、组网模式），
不附带"下一步该做什么"的指引。

需要运维信息时用下面这些**独立子命令**——它们不在安装流程里自动执行，只在你显式调用时运行：

| 子命令 | 用途 |
| --- | --- |
| `--status` | 主动查看服务状态 / 虚拟网节点 / 监听端口 / 日志尾部 |
| `--uninstall` | 主动卸载 |
| `--emit-cmd` | 打印可下发到其它节点的标准命令 |

> **无 init 系统时（容器常见）**：没有"自启动"可写，脚本退化为 `nohup` 后台启动并记录 pid 文件——
> 这仍是无 init 系统下"注册自启动"的等价物，但**没有进程守护**。
> 此时若 agent 自动更新（以退出码 42 退出）或崩溃，**不会自动拉起**。
> 这是刻意的：容器里的守护应由 `docker run --restart` / Kubernetes 的 restartPolicy 承担，
> 而不是塞进安装脚本里。systemd / OpenRC / procd 环境下单元自带 `Restart=always`，无需额外处理。

### 1.5 网络不通也能装

所有 GitHub 下载都内置镜像回退：直连失败后依次尝试 `ghfast.top`、`gh-proxy.com`、`ghproxy.net`，可用 `--gh-proxy <前缀>` 换成自己的加速地址，或 `--no-gh-proxy` 关闭。

---

## 2. 快速开始

### 2.1 单台机器，交互式（推荐首次使用）

```sh
curl -fsSL https://your-host/cluster-join.sh -o cluster-join.sh
sudo sh cluster-join.sh
```

菜单：

```
  1) 一键并网（EasyTier 组网 + Komari Agent）  推荐
  2) 仅安装/更新 Komari Agent
  3) 仅安装/配置 EasyTier 组网
  4) 部署 EasyTier Web 控制台（服务端 / web 托管）
  5) 查看运行状态
  6) 输出批量下发命令
  7) 卸载
  0) 退出
```

选了第 1 或第 3 项后，还会再问一次 **EasyTier 模式（启用并网 / 不启用）**：

```
请选择 EasyTier 模式（启用并网 / 不启用）
  1) 启用并网 · Web 控制台托管（推荐，集中管理、配置下发） (默认)
  2) 启用并网 · 共享节点/P2P 直连（自填网络名与密码）
  3) 启用并网 · 本机作为共享节点（中继服务器）
  4) 不启用并网（跳过 EasyTier，仅安装 Komari 监控）
```

选第 4 项时本机**只装 Komari 探针、不接入虚拟网络**；这个选择会随其它参数一起写进存档，
下次 `--all` 重跑仍然跳过 EasyTier。要重新启用只需再跑一次交互式并选 1/2/3，或显式加 `--et-mode web`。

### 2.2 一条命令并网（web 托管模式）

在 Komari 面板里创建**自动发现密钥（AD Key）**——面板建一次，所有节点自动注册，不用逐台「添加节点」；
拿不到 AD Key 时才退回单节点 Token：

```sh
sudo sh cluster-join.sh --all --yes \
    --komari-endpoint https://komari.example.com \
    --komari-ad-key 'YOUR-AD-KEY' \
    --et-config-server udp://10.0.0.1:22020/admin
```

### 2.3 管道一键下发（无需先落盘）

```sh
curl -fsSL https://your-host/cluster-join.sh | sudo sh -s -- --all --yes \
    --komari-endpoint https://komari.example.com \
    --komari-ad-key 'YOUR-AD-KEY' \
    --et-config-server udp://10.0.0.1:22020/admin
```

### 2.4 批量下发到整个集群

```sh
cp hosts.txt.example hosts.txt
vi hosts.txt

sh cluster-batch.sh -f hosts.txt -j 8 \
    --script-url https://your-host/cluster-join.sh \
    --komari-endpoint https://komari.example.com \
    --komari-ad-key 'YOUR-AD-KEY' \
    --komari-no-web-ssh \
    --et-config-server udp://10.0.0.1:22020/admin
```

`hosts.txt` 支持 `user@host:port`、`#` 注释、逗号分隔：

```
# 生产集群
10.0.0.1
10.0.0.2:2222
root@10.0.0.3
ops@10.0.0.4:2222
```

执行结束后会输出汇总表，每台机器的完整日志在 `./cluster-logs/<目标>.log`：

```
批量并网汇总  共 32 台 → 成功 31 / 失败 1 / 超时 0 / 无权限 0
  成功        10.0.0.1     ./cluster-logs/10.0.0.1.log
  ...
  FAIL(255)   10.0.0.9     ./cluster-logs/10.0.0.9.log
```

> 退出码：全部成功 `0`，存在失败 `1`，可直接用于 CI / 流水线判断。

---

## 3. 组网模式说明

### 3.1 web 托管模式（`--et-mode web`，默认）

由 Web 控制台集中管理所有节点：新增/修改网络、下发配置、查看在线状态和日志。

**自建控制台**（一台有公网 IP 的机器）：

```sh
# 部署控制台服务端：Web 前端/API 11211，配置下发 22020/udp
sudo sh cluster-join.sh --web-only --yes --web-deploy binary

# 浏览器打开 http://<该机器IP>:11211 ，点击 Register 注册账户
```

**其它节点接入**：

```sh
sudo sh cluster-join.sh --all --yes \
    --komari-endpoint https://komari.example.com --komari-ad-key 'AD-KEY' \
    --et-config-server udp://<控制台IP>:22020/<你在控制台上的用户名>
```

**使用 EasyTier 官方公共控制台**时，`--et-config-server` 只写用户名即可：

```sh
--et-config-server admin
```

> 控制台内置两个测试账户 `admin` / `user`，首次注册后建议立即改密。
> 配置下发协议支持 `udp`（默认，最省资源）、`tcp`、`ws`；如果前面挂了反向代理并启用了 TLS，用 `wss://`。

### 3.2 共享节点 / P2P 直连模式（`--et-mode peer`）

没有 Web 控制台时，用「网络名 + 密码 + 共享节点」组网，所有节点填一样的值：

```sh
sudo sh cluster-join.sh --all --yes \
    --komari-endpoint https://komari.example.com --komari-ad-key 'AD-KEY' \
    --et-mode peer \
    --et-network-name 'mynet-prod' \
    --et-network-secret 'a-strong-secret' \
    --et-peers 'tcp://1.2.3.4:11010 udp://1.2.3.4:11010'
```

- 不指定 `--et-ip` 时使用 DHCP 自动分配虚拟 IP（默认 `10.126.126.0/24`）。
- 需要固定 IP 时加 `--et-ip 10.126.126.7`（会自动关闭 DHCP）。
- 可同时写多个 `-p` 对端以提高可用性。

### 3.3 本机作为共享节点（`--et-mode server`）

```sh
sudo sh cluster-join.sh --easytier-only --yes \
    --et-mode server --et-ip 10.126.126.1
```

会用 `-i <IP>` 加 `--relay-network-whitelist '*'` 开放转发，并监听 `tcp/udp 11010`。
需要在云安全组 / 防火墙放行 `11010`（TCP+UDP），必要时再放行 `11011/udp`（WebSocket）。

### 3.4 不启用并网（`--et-mode off` / `--no-easytier`）

只需要监控、不需要把机器拉进虚拟网络时：

```sh
sudo sh cluster-join.sh --all --yes \
    --komari-endpoint https://komari.example.com --komari-ad-key 'AD-KEY' \
    --et-mode off
```

默认上报间隔是 **1 秒**（`--komari-interval` 可改），默认凭证是**自动发现密钥（AD Key）**——它只在安装时用一次做注册，不会被保存（详见 [4.2](#42-komari-agent)）。

`--no-easytier` 与之等价。此时脚本不会下载 EasyTier、不写任何服务单元、不动 `/opt/easytier`，
汇总里会明确显示 `EasyTier: 未启用并网（已跳过）`。已装的 EasyTier 也不会被卸载——
要清理请用 `--uninstall --uninstall-target easytier`。

> 注意：`off` 是会被记住的配置项。如果之前交互式选过「不启用并网」，
> 后续 `--all --yes` 会沿用该选择并打印跳过提示；显式传 `--et-mode web|peer|server` 可覆盖。

### 3.5 纯 IPv6 主机

**实测结论：GitHub 的下载链路完全没有 IPv6**，内置镜像也全是 IPv4-only。

| 源 | AAAA | IPv6 可达 |
| --- | --- | --- |
| `github.com` / `api.github.com` / `objects.githubusercontent.com` | 无 | ❌ |
| `ghfast.top` / `gh-proxy.com` | 无 | ❌ |
| `ghproxy.net` | 有 | ❌（端点超时） |
| `raw.githubusercontent.com` | 有 | ✅（但不用于下 release） |

所以**纯 IPv6 机器无法完成下载**。脚本的做法：

- 自动探测本机地址族（`ip`/`ifconfig`；都没有时用 `curl --noproxy` 连通性兜底，
  避免被 IPv4-only 的 HTTP 代理"成功"返回而误判），可用 `--ip-family 4|6|auto` 强制
- 判定为纯 IPv6 时：**明确告知不可达原因**、强制 `-6`（避免 IPv4 连接超时）、
  逐个实测并**剔除不可达的镜像**，并让 Komari Agent 优先用 IPv6 连面板
- 提供可执行的三条出路：

```sh
# 1) 自备支持 IPv6 的 GitHub 代理
... | sudo sh -s -- --all --yes --gh-proxy 'https://你的IPv6代理/' ...

# 2) 预置二进制后完全不下载（也适用于离线/内网机器）
#    预置：/opt/komari/komari-agent 与 /opt/easytier/{easytier-core,easytier-cli}
... | sudo sh -s -- --all --yes --no-download -e https://面板 --komari-ad-key 'AD-XXXX'

# 3) 从双栈跳板机用 cluster-batch.sh 下发（节点侧仍受同样限制）
```

> `--no-download` 下若二进制缺失会明确报错，不会静默跳过。

### 3.6 系统信息工具（fastfetch / neofetch）

和并网无关，但通常顺手装上：

```sh
# 单独安装（默认优先 fastfetch）
sudo sh cluster-join.sh --fetch --yes

# 并网的同时装上
sudo sh cluster-join.sh --all --yes --with-fetch \
    --komari-endpoint https://komari.example.com --komari-ad-key 'AD-KEY'

# 指定只用 neofetch
sudo sh cluster-join.sh --fetch --fetch-tool neofetch --yes
```

安装策略是**系统包管理器优先，拿不到再回退官方发布物**：

| 工具 | 包管理器 | 回退来源 |
| --- | --- | --- |
| fastfetch | `apt` / `dnf` / `yum` / `zypper` / `pacman` / `apk` / `opkg` / `brew` | GitHub Releases 的 `fastfetch-linux-<arch>.tar.gz`（静态二进制），落到 `/usr/local/bin/fastfetch`，presets 落到 `/usr/local/share/fastfetch` |
| neofetch | 同上 | GitHub Archives 的 7.1.0 源码包里的单文件 bash 脚本，落到 `/usr/local/bin/neofetch` |

支持的 fastfetch 预编译架构：`amd64` / `aarch64` / `armv7l` / `i686` / `loongarch64` / `ppc64le` / `riscv64` / `s390x`。
neofetch 是 bash 脚本，没有 bash 的系统会明确报错而不是装一半。

> 已安装则直接跳过；`--with-fetch` 只在并网动作成功后追加执行。

#### 让它在登录时显示（含 Komari 探针终端）

只装二进制的话，敲 `fastfetch` 才会跑。默认还会装一个登录钩子
`/etc/update-motd.d/99-fastfetch`（`--no-fetch-motd` 可关闭）。

**为什么是 `/etc/update-motd.d/`**：查过 komari-agent 的源码
（`terminal/terminal_unix.go`），它开 Web 终端时是这么启动 shell 的——

```go
const motdShellPrelude = "for f in /etc/update-motd.d/*; do [ -e \"$f\" ] && [ -x \"$f\" ] && \"$f\"; done; [ -r /etc/motd ] && cat /etc/motd; exec \"$1\""
```

也就是**先执行 `/etc/update-motd.d/` 下所有可执行脚本**，再 exec 用户 shell。
所以挂在这里，能同时覆盖：

- **Komari 探针 Web 终端**（agent 自己会跑这批脚本）
- **SSH 登录**（Debian/Ubuntu 的 pam_motd 也会跑）

钩子内容带 TTY 守卫，避免污染非交互会话：

```sh
#!/bin/sh
[ -t 1 ] || exit 0
for _c in fastfetch neofetch; do
    if command -v "$_c" >/dev/null 2>&1; then exec "$_c"; fi
done
exit 0
```

`[ -t 1 ] || exit 0` 是关键：没有它，`scp` / `rsync` / `ssh host cmd` 的输出会被
fastfetch 的渲染结果污染（经典翻车点）。实测无 TTY 时输出 0 字节、退出码 0。

---

## 4. 参数速查

### 4.1 通用

| 参数 | 说明 |
| --- | --- |
| `--all` / `--komari-only` / `--easytier-only` / `--web-only` | 选择动作 |
| `--menu` | 强制进入交互菜单 |
| `--status` / `--uninstall` | 查看状态 / 卸载 |
| `--fetch` | 安装系统信息工具（fastfetch，失败回退 neofetch） |
| `--with-fetch` | 并网成功后追加安装系统信息工具 |
| `--ip-family 4\|6\|auto` | 强制本机地址族（默认自动探测） |
| `--no-download` | 完全不下载，只用预置二进制（纯 IPv6 / 离线环境） |
| `--fetch-tool TOOL` | `auto`（默认）/ `fastfetch` / `neofetch` |
| `--fetch-motd` / `--no-fetch-motd` | 是否安装登录钩子（`/etc/update-motd.d/99-fastfetch`），默认装 |
| `--emit-cmd` | 只打印可下发到其它节点的标准命令，不改动系统 |
| `-y, --yes` | 无人值守，所有提问取默认值 |
| `--lang zh\|en` | 强制指定消息语言（默认 TTY=英文，非 TTY 跟随系统 locale） |
| `--dry-run` | 只打印将要执行的操作 |
| `--gh-proxy URL` / `--no-gh-proxy` | 指定 / 关闭 GitHub 加速 |
| `--install-ghproxy URL` / `--install-no-mirror` | 同上（官方 install.sh 的命名，便于迁移） |
| `--install-dir DIR` | Komari Agent 安装目录，默认 `/opt/komari` |
| `--install-service-name NAME` | Komari Agent 服务名，默认 `komari-agent` |
| `--log FILE` | 同时写日志（默认 `/var/log/cluster-join.log`） |
| `--reset-conf` | 忽略已保存的配置 |
| `--purge` | 卸载时连同数据目录一起删除 |

### 4.2 Komari Agent

| 参数 | 说明 |
| --- | --- |
| `-e, --komari-endpoint URL` | 面板地址，如 `https://komari.example.com` |
| `--komari-ad-key KEY` | **推荐**。自动发现密钥；**安装时只用一次**做注册，之后不再需要，也不会被保存 |
| `-t, --komari-token TOKEN` | 单节点 Token（面板 → 添加节点），拿不到 AD Key 时使用 |
| `--komari-interval SEC` | 上报间隔秒数，**默认 1** |
| `--komari-version VER` | `latest`（默认）/ `snapshot` / 具体标签如 `1.5.11`，便于固定版本或回滚 |
| `--komari-force-register` | 本机已有令牌时也强制重新向面板注册 |
| `--komari-info-interval MIN` | 基础信息上报间隔分钟 |
| `--komari-no-web-ssh` | **禁用远程控制**（Web SSH / 远程执行），安全加固用 |
| `--komari-insecure` | 忽略面板证书错误（自签证书场景） |
| `--komari-no-autoupdate` | 禁用 Agent 自动更新 |
| `--komari-extra 'ARGS'` | 追加透传给 `komari-agent` 的原始参数 |

#### Komari 凭证是怎么处理的

**AD Key 只用于一次性引导注册，绝不会被写进任何持久化文件。**

`komari-agent` 的真实行为是：首次以 `--auto-discovery <AD Key>` 启动时，它会
`POST /api/clients/register` 换取 `{uuid, token}` 并写进自己目录下的 `auto-discovery.json`；
此后即使再传 AD Key 也不会重新注册（文件存在就直接复用）。而不传 `--auto-discovery` 时，
它根本不会读取那个文件。

因此本脚本的流程是：

```
AD Key ──(一次性注册)──► 面板返回节点令牌 ──► 写入 agent.json (0600)
                                                    │
                              服务单元只引用 ──► --config agent.json
```

| 文件 | 权限 | 内容 | 谁写的 |
| --- | --- | --- | --- |
| `/opt/komari/agent.json` | `600` | `endpoint` / `token` / `interval` 等 | 脚本 |
| `/opt/komari/auto-discovery.json` | `600` | `uuid` / `token`（注册产物） | agent 自己（脚本会收紧权限） |
| `/etc/systemd/system/komari-agent.service` | `644` | 只有 `--config /opt/komari/agent.json`，**无任何密钥** | 脚本 |
| `/etc/cluster-join/cluster.env` | `600` | 面板地址、间隔等非密钥项，**不含 AD Key / 令牌** | 脚本 |

行为约定：

- **重复执行是幂等的**：本机已有令牌时直接复用，不会重复注册（避免面板里出现重复节点）。
- 面板里删掉了节点、需要重新注册时，加 `--komari-force-register`；或删除 `/opt/komari/agent.json`。
- 想换面板：直接改 `--komari-endpoint` 重新执行即可。
- AD Key 在注册时是通过**环境变量**（`AGENT_AUTO_DISCOVERY_KEY`）传给 agent 的，因此也不会出现在 `ps` 的命令行里。

### 4.3 EasyTier

| 参数 | 说明 |
| --- | --- |
| `--et-mode web\|peer\|server\|off` | 组网模式；`off` = 不启用并网（跳过 EasyTier） |
| `--no-easytier` | 等同于 `--et-mode off` |
| `--et-config-server URL` | Web 控制台配置下发地址；也接受纯用户名（官方控制台） |
| `--et-machine-id ID` | 固定机器标识，重装/迁移后保持同一节点身份 |
| `--et-network-name` / `--et-network-secret` | 虚拟网络名与密码（peer 模式） |
| `--et-peers 'URL...'` | 对端/共享节点，空格分隔 |
| `--et-ip IPV4` / `--et-no-dhcp` | 固定虚拟 IP / 关闭 DHCP |
| `--et-hostname NAME` | 虚拟网络内主机名（配合魔法 DNS 使用） |
| `--et-version VER` | 指定版本，如 `v2.6.4`；默认最新 |
| `--et-extra 'ARGS'` | 追加透传给 `easytier-core` 的参数，如 `--no-tun --socks5 1080` |

### 4.4 Web 控制台服务端

| 参数 | 说明 |
| --- | --- |
| `--web-deploy binary\|docker\|none` | 部署方式，默认二进制 |
| `--web-port PORT` | Web 前后端端口，默认 `11211` |
| `--web-cfg-port PORT` | 配置下发端口，默认 `22020` |
| `--web-cfg-proto PROTO` | 配置下发协议 `udp`/`tcp`/`ws`，默认 `udp` |
| `--web-api-host URL` | 前端访问后端的地址，默认 `http://<本机IP>:<web-port>` |

### 4.5 环境变量

长选项都有对应的大写环境变量（`-` 换 `_`）。注意含空格的值必须加引号：

```sh
export KOMARI_ENDPOINT='https://komari.example.com'
export KOMARI_AD_KEY='AD-XXXX'
export ET_MODE=web
export ET_CONFIG_SERVER='udp://10.0.0.1:22020/admin'
export ET_NETWORK_NAME='mynet'
export ET_NETWORK_SECRET='s3cret'
export ET_PEERS='tcp://1.2.3.4:11010 udp://1.2.3.4:11010'
export ET_IPV4='10.126.126.7'
export GH_PROXY='https://ghfast.top/'

sudo -E sh cluster-join.sh --all --yes      # -E 保留环境变量
```

其它控制变量：

| 变量 | 作用 |
| --- | --- |
| `CLUSTER_JOIN_YES=1` | 等价于 `--yes` |
| `CLUSTER_JOIN_NO_TTY=1` | 强制非交互（即使有终端） |
| `CLUSTER_JOIN_FORCE_INTERACTIVE=1` | 无终端时改为从 `stdin` 读取答案，便于 heredoc / expect 驱动 |
| `CLUSTER_JOIN_CONF=/path/cluster.env` | 自定义参数存档位置 |
| `CLUSTER_JOIN_LANG=zh\|en` | 强制消息语言（批量脚本也支持 `CLUSTER_BATCH_LANG`） |

也可以把参数写进存档文件（脚本每次运行会自动读取，命令行与环境变量优先）：

```sh
sudo mkdir -p /etc/cluster-join
sudo cp cluster.env.example /etc/cluster-join/cluster.env
sudo chmod 600 /etc/cluster-join/cluster.env
sudo sh cluster-join.sh --all --yes
```

> 存档格式是每行 `KEY=VALUE`，值不要加引号；脚本按「第一个等号」切分，不做 shell 求值，
> 所以值里可以安全地包含空格、`=`、单引号。

---

## 5. 前置条件

| 项目 | 要求 |
| --- | --- |
| 权限 | root（脚本会自动尝试 `sudo` 提权） |
| 系统 | Linux（systemd / OpenRC / OpenWrt procd 均可）；容器内可用 `nohup` 兜底 |
| 架构 | x86_64 / aarch64 / armv7 / armv6 / loongarch64 / riscv64 等 |
| 工具 | `curl` 或 `wget`；解压用 `unzip`（缺失时自动安装，或用 `python3` 兜底） |
| TUN | `/dev/net/tun`。缺失时脚本会尝试 `modprobe tun`；容器需加 `--device /dev/net/tun --cap-add NET_ADMIN` |
| 磁盘 | 约 12 MB（Komari Agent）+ 11 MB（EasyTier 普通节点，仅 `easytier-core`+`easytier-cli`）+ 25 MB（部署 Web 控制台时额外解压 `easytier-web`/`easytier-web-embed`）。下载与解压全程在**目标文件系统**内进行，不占用 `/tmp`（小 VPS 上 `/tmp` 常是 tmpfs，放那里会直接吃内存） |
| 端口 | 共享节点模式需放行 `11010/tcp+udp`；Web 控制台需放行 `11211/tcp` 与 `22020/udp` |

---

## 6. 日常运维

```sh
# 查看整体状态（服务、虚拟网节点、监听端口、日志尾部）
sudo sh cluster-join.sh --status

# 实时日志
sudo journalctl -u easytier -u komari-agent -f

# EasyTier 侧
/opt/easytier/easytier-cli peer      # 虚拟网内的节点
/opt/easytier/easytier-cli route     # 路由
/opt/easytier/easytier-cli node      # 本机节点信息

# 服务管理
systemctl restart easytier
systemctl restart komari-agent

# 卸载（保留数据）
sudo sh cluster-join.sh --uninstall --yes
# 卸载并清空数据
sudo sh cluster-join.sh --uninstall --yes --purge
```

目录约定：

| 路径 | 内容 |
| --- | --- |
| `/opt/easytier/easytier-core`、`easytier-cli`、`easytier-web-embed` | EasyTier 二进制 |
| `/opt/easytier/config/` | web 托管模式接收到的配置 |
| `/opt/easytier/web/` | 自建 Web 控制台数据（`et.db`） |
| `/opt/komari/komari-agent` | Komari 探针二进制 |
| `/opt/komari/agent.json` | 探针配置（`600`）：面板地址 + 节点令牌 + 上报间隔 |
| `/opt/komari/auto-discovery.json` | 自动发现的注册产物（`600`），含 uuid 与节点令牌 |
| `/etc/cluster-join/cluster.env` | 脚本保存的参数（`600`） |
| `/var/log/cluster-join.log` | 脚本日志 |

---

## 7. 故障排查

| 现象 | 处理 |
| --- | --- |
| `非交互环境且未提供任何配置参数` | 无 TTY 时必须给参数，或加 `--yes` 配合环境变量 |
| 下载失败 | 换 `--gh-proxy https://你的加速前缀/`，或先手动下载二进制再跑 |
| EasyTier 起不来 | `journalctl -u easytier -n 100`；重点看 `/dev/net/tun` 是否存在、是否有 `NET_ADMIN` |
| 虚拟网 ping 不通 | 关掉防火墙或放行 `11010`；`easytier-cli peer` 有对端才算组网成功 |
| web 托管节点一直离线 | 节点上 `-w` 地址/用户名是否正确；`udp://IP:22020/用户名` 三部分都不能少 |
| 控制台刷新不出验证码 | `--api-host` 与浏览器实际访问地址不一致，改 `--web-api-host http://真实IP:11211` |
| Komari 节点不显示 | 确认面板地址可访问：`curl -I https://komari.example.com`；`journalctl -u komari-agent -n 50` |
| 服务显示 `stopped` 但进程在跑 | 容器里没有 systemd，脚本退化为 `nohup`；用 `--status` 看 pid 文件 |

---

## 8. 安全提醒

- 脚本参数里会出现 Token / AD Key / 网络密码，已保存文件权限为 `600`，但仍请勿把命令历史、日志外发。
- 批量部署建议加 `--komari-no-web-ssh`，关闭探针的远程执行能力。
- `--insecure-ssh`（批量脚本）与 `--komari-insecure` 会降低校验强度，仅在自签证书的内网临时使用。
- EasyTier 的 `--network-secret` 是网络准入凭据，请使用足够复杂的值，不要与网络名相同。
- 共享节点模式若要对外提供中继，请自行评估带宽与滥用风险，必要时加 `--et-extra '--relay-network-whitelist "你的网络名"'` 限制转发范围。

---

## 9. 验证情况

脚本中的安装命令、参数与版本号均对照真实二进制核对：

- EasyTier `v2.6.4`：`easytier-core -w/--config-server`、`--machine-id`、`--config-dir`、`easytier-cli service install`、`easytier-web-embed --api-server-port/--config-server-port/--config-server-protocol/--api-host/--db`
- Komari Agent：`-e/--endpoint`、`-t/--token`、`--auto-discovery`、`-i/--interval`、`--disable-web-ssh`、`-u/--ignore-unsafe-cert`

脚本自身已在 `dash` 与 `bash` 下通过语法校验（40 项回归全绿），覆盖：交互式问答流程、管道/无终端流程、
`--dry-run`、`--emit-cmd`、`--status`、`--et-mode off` 不启用并网、非法模式报错、
批量参数透传与失败汇总、配置读写往返（含 `'`、`=`、空格的敏感值），
以及"安装路径在注册自启动后立即返回"（安装函数内无 `sleep`、无存活检查）。

语言策略的验证覆盖：`HAVE_TTY=1` 时无论 locale 一律英文；非 TTY 下 `zh_CN/zh_TW` 走中文、`en_US` 与无 locale 走英文；`--lang` / `CLUSTER_JOIN_LANG` 覆盖生效；英文模式下 `--help`、`--status`、安装流程、批量流程的输出经字节扫描确认 **零非 ASCII 字符**。

---

## 许可证

[MIT License](LICENSE) © 2026 WUHINS
