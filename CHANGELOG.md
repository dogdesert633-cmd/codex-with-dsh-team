# Changelog

All notable changes to the Codex × DSH Team Toolkit are recorded here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

- 中文安装窗口：选择项目、查看进度与日志，安装完成后可直接打开项目。
- 首次启动找不到 DSH 配置时提供目录选择窗口，并记住用户选择。
- 默认模型跟随每位用户自己的最新配置，同步失败时阻止任务启动。
- Git 改为可选，空白目录也能使用 DSH 路由，无需预先创建仓库或提交。

## [1.1.0] — 2026-09-19 — **Pre-release**

Published as a **pre-release**, not a stable release. Open items remain (see below), so this
version is offered for evaluation rather than as a finished product.

- **Three independent Skills.** The payload now ships `codex-team` (universal multi-role template),
  `dsh-role-boundaries` (what DSH may and may not be given) and `mcp-to-dsh` (DSH call path and
  Monitor). They do not inherit from or load each other; a caller reads the ones a task needs.
- **Complete-package installation is the primary path.** One run of the package-root installer
  (`CodexDshTeamToolkit.Install.exe` or `Install.cmd`) writes all three Skills into an existing
  project's `.agents/skills/` in one pass, together with the project-root launchers and the thin
  uninstaller; everything is declared by the package inventory and tracked in the ownership ledger.
- **Replaced the older mixed team skill.** The previous single `codex-dsh-team` skill is no longer
  part of the payload; this release ships and installs the three independent skills instead.
- **Bilingual documentation.** `README.md` (English) and `README.zh-CN.md` (Chinese) are kept in
  step and cross-linked, and the `docs/` set covers installation, configuration, security and
  troubleshooting.
- **Security disclosures corrected.** The docs now distinguish message redaction from the byte
  copies the toolkit deliberately keeps (`pristine/` baselines, transaction `backup/` and
  `quarantine/`, the credential copy in the owned Team Home), state the DSH execution permission
  and automatic tool-approval behaviour, and tell you which runtime output directories to ignore in
  your own project.
- **Dependencies.** The payload's own package version is `1.1.0`; runtime requirement is
  **Node ≥ 22.19.0** with the DSH runtime dependency pinned and tested against
  `@deepseek-ai/dsh 0.1.5-rc.1`.
- **First start now prepares the ACP profile itself.** The installer stays an offline file copy and
  no longer needs to pre-place a profile: after `npm ci` in the installed skill directory, the
  launcher prepares the ACP configuration inside the **owned Team Home** from the installed, pinned
  DSH's own template (a custom profile name is initialised with that DSH's
  `--from-default-profile acp`). No hand-written `package.json` and no second dependency tree
  inside the profile directory are required.
- **One profile name, consistently routed.** The ACP profile travels as one explicit value from the
  launcher (`-TeamProfile`, or `CODEX_DSH_TEAM_PROFILE`) to the Monitor (`--dsh-profile`, echoed in
  `/api/health` as `dshProfile` and in the local Monitor record as `dsh_profile`), to the bridge
  child as `CODEX_DSH_ACP_PROFILE`, and to the one-click configuration sync as `-TeamProfile`, so a
  task can never be planned under one profile while the DSH child runs another. Monitor reuse
  requires workspace, Team Home **and** profile to match; a legacy record or health projection
  without the field is read as the historical `acp`. The name is resolved as `-TeamProfile` →
  `CODEX_DSH_TEAM_PROFILE` → the one optional profile already in the owned Team Home → the default
  `acp`, which is then prepared; only **several** existing optional profiles are ambiguous and must
  be chosen explicitly, and the DSH built-in helper templates (`web`, `headless`, `sdk`,
  `sdk-minimal`) are ignored as candidates and refused as the Team ACP entry (as is the reserved
  name `node_modules`).

### Known limitations in this release

- The PowerShell test entry can count a missing-dependency skip as a pass; install the payload
  dependencies and read the Node suite's real results (including the SKIP count) before treating
  the suite as fully executed.
- Real provider runs, the GUI folder picker, and some ACL / credential / partial-permission
  scenarios are not fully verified.
