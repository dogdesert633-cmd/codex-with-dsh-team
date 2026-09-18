# Changelog

All notable changes to the Codex × DSH Team Toolkit are recorded here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-09-15

The first public release. This version provides:

- **A manifest-owned installer.** `CodexDshTeamToolkit.Install.exe` (package root) or
  `Install.cmd` installs the managed skill files declared by `release/payload-inventory.json`
  into an existing project. Unknown same-name files block the whole operation instead of being
  overwritten.
- **Thin launchers.** `CodexDshTeamToolkit.Install.exe` and
  `CodexDshTeamToolkit.Uninstall.exe` are small framework-dependent C# shells that locate the
  package and the project, show the plan produced by the shared engine, confirm, call that
  engine and forward its exit code. The installer launcher is package-only: it is never
  installed into a project and never enters the ownership ledger. The uninstaller is different
  by design — it **is** installed into the target project root as a managed file and **is**
  recorded in the ownership ledger, so the project can uninstall itself later.
- **Pristine-byte ownership.** Each managed file keeps a `pristine/<path>` copy of the exact
  installed bytes under the project's `.codex-dsh-team-toolkit/` state directory. A file is
  replaced or deleted only while it is byte-identical to that baseline, so a hand-edited file is
  preserved and reported. No checksum, hash or digest is computed, stored or trusted.
- **Transactional install, upgrade and uninstall.** Plan → read-only package preflight →
  exclusive lock → durable journal + backup → same-directory temp + atomic replace → verify →
  atomic ledger commit, with a verified reverse rollback and an in-lock TOCTOU guard.
- **Offline release tooling.** `tools/Build-Release.ps1` and `tools/Verify-Release.ps1` build and
  check a package with no network access and no push, and produce no checksum artefact.
- **A safety test suite.** `tests/` covers install, ownership, transactions, uninstall, path
  policy, confidentiality, relocation, recovery/TOCTOU, Windows hygiene, release tooling and the
  thin EXE, using temporary directories and fake credentials only.
- **Documentation.** `docs/` covers installation, configuration, security and troubleshooting,
  including the no-hash contract, credential/privacy rules and Windows-specific safety rules.

Runtime requirement: **Node ≥ 22.19.0**, with the DSH runtime dependency pinned and tested
against `@deepseek-ai/dsh 0.1.5-rc.1`.