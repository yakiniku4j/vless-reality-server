# xray-reality-skill

**用于部署 Xray REALITY(VLESS)节点的 Agent Skill**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) ![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20WSL-blue) ![Agent Skill](https://img.shields.io/badge/Agent%20Skill-format-blueviolet)

> **English**: [README.md](README.md)

## 安装

本 skill 遵循开放的 Agent Skills 格式，同一个目录在所有工具上都能用。挑一种适合你的方式即可。

### 方式一 — skills CLI，一条命令

[skills CLI](https://github.com/vercel-labs/skills) 会自动识别你装了哪些 agent，然后把 skill 放进它们各自的目录：

```sh
npx skills add yakiniku4j/xray-reality-skill
```

默认装在当前项目下，加 `-g` 则装到用户级。想让一条命令覆盖机器上所有 agent，用这个。

### 方式二 — Claude Code，通过插件市场

```
/plugin marketplace add yakiniku4j/xray-reality-skill
/plugin install xray-reality-skill@xray-reality-skill
```

### 方式三 — 直接拷贝目录

```sh
git clone https://github.com/yakiniku4j/xray-reality-skill vrs
cp -r vrs/skills/xray-reality-skill ~/.codex/skills/ && rm -rf vrs
```

不管用哪种方式装，**装完都要开一个新会话**。agent 是在会话启动时加载 skill 的，已经在跑的那个会话看不到它。

## 概述

这是一个 Agent Skill，用来在 VPS 上通过 SSH 部署并运维一个 VLESS-REALITY 节点。你只需要给它两样东西——一个 SSH 目标和一个伪装域名——它会生成 REALITY 密钥对、写好 Xray 配置，并用 Docker 跑起官方 `xray-core` 镜像（`restart: unless-stopped`），最后交给你一条 `vless://` 链接和一个二维码。

之后它继续负责运维：增删用户、轮换密钥、更换端口、切换伪装目标、更新镜像，以及从两端验证部署是否真的可用。

没有面板、没有数据库、没有 Web 界面。整个节点就是一个容器、一个配置文件、一条分享链接，由 agent 在命令行上管理。

## 功能特性

- 🚀 **只给两样输入，其余全部生成** —— UUID、REALITY 密钥对、short id、配置、端口
- 🎭 **REALITY，不需要域名和证书** —— 借用真实站点的 TLS 1.3 + HTTP/2 握手
- 🐳 **官方镜像 + Docker** —— `restart: unless-stopped`，重启服务器后节点自动回来
- 👥 **按用户管理客户端** —— `client-add` / `client-rm` / `client-list`，每个用户独立 UUID
- 🔑 **密钥轮换** —— 按需更换 REALITY 密钥对
- 🔌 **端口与伪装目标可改** —— `set-port`、`set-sni`，compose 文件同步重建
- 🔗 **分享链接与二维码** —— 直接产出 `vless://` URI 和 PNG／终端二维码，不需要额外工具
- ✅ **内置验证** —— 部署前 `check`，部署后 `doctor`，两端都测
- 🧭 **密码登录的主机有引导** —— 检测到就停下来教你怎么改成密钥登录，而不是抛个看不懂的错
- 🛡️ **REALITY 私钥对 agent 不可读** —— 没有任何子命令会读取或打印它
- 🔒 **不碰你的 SSH 密钥** —— 不生成、不拷贝、不写 `authorized_keys`，也不自动接受主机密钥
- 📄 **服务器状态只由一个脚本写** —— 主机上所有文件都由 `ctl.sh` 产生，绝不通过临时 SSH 命令写
- 🌍 **跨 agent 通用** —— 一个目录，Claude Code、Codex、OpenCode 以及任何遵循该标准的一起用

## 工作流程

```
输入：一个能用密钥登录的 SSH 目标 + 一个伪装域名
  |
  +-- check        确认登录不需要交互式输入密码
  |
  +-- install      生成 UUID、REALITY 密钥对、short id
  |                写入 config.json 与 docker-compose.yml
  |                启动容器（主机上没装 Docker 会自动装）
  |
  +-- doctor       服务端：配置、容器、TLS 探测、出网
  |                本机侧：可达性与握手
  |
  +-- link / qr    客户端分享链接，以及对应的二维码
  |
  +-- operate      client-add / client-rm / rotate-keys / set-port / set-sni
  |                logs / restart / update / backup
  |
  +-- 完成：一个跑着的节点，以及一条能用的链接
```

## 用法

装好之后，直接说出你想要什么：

- *"在我的 VPS（203.0.113.10）上搭一个 VLESS-REALITY 节点"*
- *"给我的节点加一个叫 laptop 的用户"*
- *"把那台服务器的 REALITY 密钥换掉"*
- *"把节点改到 8443 端口"*
- *"我的节点现在还正常吗？"*

请求匹配时 skill 会自动激活，并通过 SSH 完成这些工作。

想自己驱动它，就在 skill 目录下跑脚本：

```sh
cd skills/xray-reality-skill

./scripts/vless-reality-server.sh check   -H myvps
./scripts/vless-reality-server.sh install -H myvps --sni www.tesla.com
./scripts/vless-reality-server.sh doctor
./scripts/vless-reality-server.sh link
```

`--sni` 是 REALITY 借用其 TLS 证书的伪装域名。它必须支持 TLS 1.3 和 HTTP/2、流量足够大以至于不显眼，而且不能是你自己拥有的域名。`www.tesla.com`、`www.microsoft.com`、`www.apple.com` 都可以。

任何命令加 `--help` 都能看到完整选项。

## 环境要求

**运行 agent 的一侧**

- `bash` 3.2 以上，以及 `ssh`、`scp`、`curl`
- `python3`（仅生成二维码时需要，其余功能不需要）
- macOS、Linux、WSL，或装了 Git for Windows 的 Windows。**没有 PowerShell 版本**：原生 Windows 不装 Git Bash 跑不了这个驱动脚本。

**服务器一侧**

- Ubuntu 或 Debian，以 root 身份通过 SSH 访问
- Docker（没有会自动装）以及 `python3`
- 一个可达的公网 IP

## 安全模型

三条特性是设计进去的，不是后加的：

- **REALITY 私钥永远不会被读出、打印或传输。** 没有任何子命令会暴露它，驱动脚本还会在显示前把形似密钥的内容抹掉。备份它是你自己在主机上拷贝 `config.json` 的有意动作；工具不提供任何导出它的途径。这样做的目的，是让 agent 永远无法泄露那个唯一无法再生的值。
- **你的 SSH 密钥永远不会被碰。** skill 不读取、不生成、不拷贝、不上传任何密钥材料，不写 `authorized_keys`，也不自动接受主机密钥。建立连接是你的事，skill 只负责验证它已经能用。
- **本仓库不含任何秘密。** 生成的密钥对只存在于服务器上。客户端侧信息写在本地 `~/.local/share/` 下。

## 适用范围

- VLESS over TCP，配合 REALITY 与 `xtls-rprx-vision`。不支持 WebSocket、gRPC、TLS 透传或多协议混搭。
- 默认一台主机一个节点；`--name` 和 `--dir` 允许再并排跑一个。
- `install` 在没有 `--force` 时拒绝覆盖一个正在运行的部署。

## 许可证

MIT —— 详见 [LICENSE](LICENSE)。

你需要自行遵守部署所在地适用的法律法规。

## 致谢

构建在以下项目之上：

- [Xray-core](https://github.com/XTLS/Xray-core) —— 支撑 VLESS、REALITY 与 Vision 的代理引擎

## 参与贡献

1. Fork 本仓库
2. 建一个特性分支（`git checkout -b feature/improvement`）
3. 提交你的改动
4. 发起 Pull Request
