# 更新日志

哲学系客户端与节点侧 agent 的版本更新记录（按版本从旧到新）。

### v0.0.1 建仓（2026-11-21）

- 新仓 `nbbk/zhexuexi-client` 建仓首版：只推方案与 Logo，不写应用代码、不打包。
- 首版内容：`README.md`、`DEV-PLAN.md`（完整开发流程与方案，950 行）、`docs/zhexuexi-client-plan.md`（客户端落地方案复制件）、`assets/logo.png`（Logo v1 定稿）+ `assets/logo-v2.png`（负空间版备选）。
- 两条线定稿：A 线节点侧按人计量（方案 2，所有节点都能限流）先行 / 并行，B 线哲学系客户端（Flutter + sing-box，Win + Android）随后，汇合点是客户端首页流量同时含中转和直连、超量停用在直连节点上真实生效。
- 未做：应用代码、打包、真机验证。
