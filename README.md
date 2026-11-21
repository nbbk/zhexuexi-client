# 哲学系客户端（Zhexuexi Client）

全新自研的机场客户端，Flutter + sing-box，Windows + Android。

![哲学系 Logo](assets/logo.png)

- **暂名：** 哲学系（Zhexuexi / Philosophy）
- **平台：** Windows + Android（第一期只做这两个，不做 iOS）
- **方式：** 全新自研，不 fork 现成客户端换皮；代理核心不自写，用成熟开源核心 sing-box
- **Logo：** v1 定稿（深蓝底 + 金色哲人侧脸 + 月桂枝 + 三道信号弧），`assets/logo.png`；v2 负空间版为备选，`assets/logo-v2.png`

## 这是什么

你家两仓的官方客户端：打开就能连，节点自动选最快的，流量和到期一眼看得见，换域名、换订阅不用重装。

- 第一版只原生接自己的两仓：落地节点 `landing-node`（Xray / sing-box 双核心）+ 中转面板 `relay-node`（面板 1.3.29）。
- 流量限制走方案 2（节点侧按人计量）：所有节点（中转 + 直连）都要能限流。中转走面板 A 方案，直连走落地 agent + 每人一个 UUID + Xray stats 上报。
- Xboard / V2board 各做一个适配器，排第二阶段。

## 架构（两条线）

```
A 线：节点侧按人计量（services/node-agent，Go 静态 agent）
      落地 Xray stats → agent 按人计数 → 每 60 秒推回面板 → 超量停用
B 线：哲学系客户端（apps/flutter_client，Flutter + sing-box）
      远程配置中心 → 订阅 → 节点模型 → sing-box 核心 → 一键开关
汇合点：客户端首页的流量同时含中转和直连，超量停用在直连节点上真实生效。
```

详细开发流程见 [DEV-PLAN.md](DEV-PLAN.md)（950 行，两条线、阶段、验收、进度表全在里面）。

## 相关仓库

- 落地节点：[nbbk/landing-node](https://github.com/nbbk/landing-node) —— Xray / sing-box 双核心落地节点，一键安装
- 中转面板：[nbbk/relay-node](https://github.com/nbbk/relay-node) —— 中转 + 管理面板（1.3.29），订阅、分组、按人限流、备份整机迁移
- 本仓：`nbbk/zhexuexi-client` —— 哲学系客户端 + 节点侧 agent，只做这两样，不动上面两个仓库

## 文档入口

- [DEV-PLAN.md](DEV-PLAN.md) —— 完整开发流程与方案（先读这份）
- [docs/zhexuexi-client-plan.md](docs/zhexuexi-client-plan.md) —— 客户端落地方案（产品定义、技术选型、界面、远程配置）
- 更新日志：[CHANGELOG.md](CHANGELOG.md)

## 状态

方案与建仓阶段：只做了方案与建仓，**不写应用代码、不打包**。开发按 [DEV-PLAN.md](DEV-PLAN.md) §8 的进度表走，约 9–13 周（A 线先行、B 线并行，验收不过就顺延）。

## 硬性边界

绝不动现有仓库：`landing-node`、`relay-node`、`tiktok-node`、`sing-box-node` 一个文件都不要碰。节点侧计量与客户端的开发全部在新仓里做，现有两仓只作为被对接的上游；若执行中发现必须改现有两仓才能实现，停下来写进 DEV-PLAN §7“待用户拍板”清单，不要擅自改。
