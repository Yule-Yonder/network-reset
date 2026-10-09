# 网络重置工具
> 菜单式双功能：① 一键关系统代理 + 刷 DNS（免管理员）；② 深度重置（需管理员）：WinHTTP 代理归零 + 清理 VPN/代理软件残留路由（孤儿路由 + 多余默认路由，含持久化条目），用于 TUN/VPN 崩溃断网与"系统配置检测"红项的自救

## 技术栈与版本
- Windows 批处理（`reg` + `ipconfig` + `ping` + `route` + `netsh winhttp`）+ 内置 PowerShell 网络模块（`Get-NetAdapter` / `Get-NetRoute` / `Remove-NetRoute`），无任何第三方依赖
- Windows 10 及以上（依赖 PowerShell NetAdapter/NetRoute 模块）

## 功能说明

### 菜单 [1] 快速重置（免管理员）
原 4 步流程：查代理 → 关系统代理（HKCU `ProxyEnable` 置 0）→ 刷 DNS 缓存 → 验证，随后展示 IP 配置并 ping 测连通性。

### 菜单 [2] 深度重置（需管理员，选中后才弹 UAC）
典型场景：Clash/v2rayN TUN 模式、OpenVPN/WireGuard 等异常退出（崩溃、强杀进程）后路由表残留导致断网；或"系统配置检测"面板报 WinHTTP 代理已配置、检测到多条疑似 VPN/代理默认路由。

处理流程（新开的提权窗口中执行，6 步）：
1. 展示 WinHTTP 代理当前状态（`netsh winhttp show proxy`）→ `netsh winhttp reset proxy` 重置为直接访问
2. 展示所有网卡及状态（`Get-NetAdapter`）
3. 展示当前完整 IPv4 路由表（`route print -4`，含持久化路由段）
4. 扫描并删除**孤儿路由**：绑定到「不存在 / Not Present / Disconnected / Disabled / Broken」网卡的 IPv4 活动路由，逐条 `Remove-NetRoute` 删除
5. 扫描并删除**可疑默认路由**（0.0.0.0/0 与 ::/0）：非活动物理网卡上的默认路由整组删除；同一活动物理网卡上存在多条默认路由时仅保留有效 metric 最低的一条、其余（如残留的第二网关）删除；删除时 `Remove-NetRoute` 同时清 ActiveStore 与 PersistentStore（**持久化条目一并清除**，否则重启后残留路由会自动复活）
6. 验证：刷 DNS → 回显 WinHTTP 状态与清理后的路由表 → ping 验证

**安全边界**：
- 状态为 Up 的正常物理网卡（含其正常默认路由）一律保留；Local 协议路由与 loopback（127.x）路由排除在外
- **防断网兜底**：某地址族按上述规则清理后将不存在任何默认路由时，保留有效 metric 最低的一条并打印 `SAFETY KEEP` 提示，确保始终有网

## 目录结构
```
网络重置工具/
├─ Network_Reset_Quick.bat    # 源码即启动入口（菜单式，运行完返回菜单）
├─ README.md                  # 本文件
├─ .gitignore
└─ release/
   └─ 网络重置工具.zip         # 2026-09-11 交付存档（bat 打包分发用）
```

## 启动方式
- 双击 `Network_Reset_Quick.bat`，按菜单输入 1/2/3
- 或命令行：`D:\dev\自研工具\网络重置工具\Network_Reset_Quick.bat`
- 直接执行 `Network_Reset_Quick.bat /ROUTEFIX` 可跳过菜单直达深度重置（仍会请求 UAC）

## 端口
无（本工具用于修网络，自身不监听端口）

## 数据文件说明
- 无持久化数据文件；改动项：注册表 `HKCU\...\Internet Settings` 的 `ProxyEnable`（置 0）、WinHTTP 代理配置（`netsh winhttp reset proxy` 归零）、路由表活动条目（ActiveStore）与持久化路由（PersistentStore）

## 当前状态：源码 ↔ release 同步性
- `release/网络重置工具.zip` 为 2026-09-11 存档，**落后于 2026-10-09 深度重置迭代**，待用户发布指令后重打包（zip 内容 = bat + README）

## 已知限制
- **只关代理不清代理地址**：`ProxyServer` 注册表值保留（仅 ProxyEnable 置 0），Clash/v2rayN 等重新打开"系统代理"开关时无需重填地址，但也意味着代理地址一直留在注册表里
- 快速重置关的是**当前用户（HKCU）的 IE/WinINET 系统代理**；WinHTTP 代理归零在菜单 [2] 深度重置中处理（需管理员），浏览器自身代理设置不在处理范围
- **孤儿路由检测无法覆盖"TUN 网卡仍为 Up 但代理进程已死"的情况**（部分 TUN 伪网卡会常驻 Up 状态）：此时孤儿检测不触发，但默认路由清理（第 5 步）会删掉非物理网卡上的默认路由，流量即回落物理网卡
- 默认路由清理按"物理网卡"判定（`Get-NetAdapter -Physical`）；双物理网卡同时在线时仅各保留一条 metric 最低的默认路由，若依赖备用默认路由做故障切换，被清的那条需手动补回
- 孤儿路由清理只处理 IPv4 活动路由；默认路由清理覆盖 IPv4（0.0.0.0/0）与 IPv6（::/0）；明细级 IPv6 残留路由不处理
- 适配器状态按英文枚举值匹配（Up/Disconnected/Not Present 等）；实测 CIM 枚举在中文系统同样返回英文（已验证），如遇本地化异常会导致漏删（只漏删不误删，属安全侧失败）
- 代理关闭后部分已打开的浏览器需重启才生效（浏览器启动时读取代理设置）
- `ping www.baidu.com` 在纯内网环境会失败，属正常
- 快速重置无需管理员；深度重置需管理员（UAC 提权，取消 UAC 则不会执行）

## 迭代记录
- 2026-08-25 迁移入库：自工具根目录散置状态归入本文件夹，按 create-tool skill 规范补 README/.gitignore 并 git 化（工具实际创建日期早于本次迁移，bat 末次修改 2026-07-29）
- 2026-09-04 新增：菜单式单入口（原快速重置为菜单项 1）；新增菜单项 2"清理 VPN/代理残留路由"——基于 Get-NetAdapter/Get-NetRoute 孤儿路由检测 + Remove-NetRoute 删除，选中时按需 UAC 提权，新增 `/ROUTEFIX` 直达参数
- 2026-10-09 菜单 [2] 升级为**深度重置**（6 步）：新增 WinHTTP 代理归零（`netsh winhttp reset proxy`，实测本机残留网关 192.168.123.1）与可疑默认路由清理（0.0.0.0/0 与 ::/0；非物理网卡整组删 + 同网卡多默认路由仅留 metric 最低条 + ActiveStore/PersistentStore 双删防持久化复活 + SAFETY KEEP 防断网兜底）；dry-run 实测命中残留路由 192.168.123.1（metric 291, WLAN）并保留正常网关 10.1.9.1（metric 35）
