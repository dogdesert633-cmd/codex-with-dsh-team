# Task Capability Routing

Coordinator classifies each Task before routing.

## DSH-preferred

Short/medium-duration, non-visual Tasks may go to DSH, including:

- code implementation/repair;
- test/fixture/helper code;
- short/medium smoke tests;
- PowerShell/CMD commands;
- Git operations;
- file copy/move/create/rename;
- text/code search;
- short Python/Node/PowerShell scripts;
- normal process start/stop;
- port/PID/environment checks;
- logs, stderr, exit-code inspection;
- non-visual local configuration work.

## Visual tasks: never DSH

Do not route Tasks requiring image/screenshot/visual understanding to DSH:

- image or screenshot recognition;
- GUI screenshot acceptance;
- layout/font/spacing/color/alignment judgment;
- visual chart inspection;
- image before/after comparison;
- OCR-dependent visual work;
- “is this UI attractive/crowded/overlapping?” judgments.

Route these to Codex-side vision-capable execution.

Mixed work must be split, e.g.:

- implement Sidebar -> DSH;
- automated behavior validation -> DSH;
- screenshot/visual acceptance -> Codex-side vision.

## Long-wait / long-running tasks: not DSH

Do not occupy DSH with long-running or mostly-waiting execution such as:

- long simulations;
- large/slow test suites;
- long builds;
- long dependency installs;
- benchmarks;
- long scans;
- scripts taking several minutes or more;
- waiting on external processes/services.

DSH may prepare code, tests, commands, and validation scripts. Codex side starts, waits for, monitors, and collects the long-running result.

Suggested `execution_type`:

`normal | long_wait | visual`

Routing:

- `normal + non_visual` -> DSH preferred;
- `long_wait` -> Codex-side execute/monitor;
- `visual` -> Codex-side vision.

Visual and long-wait Tasks do not enter the normal DSH recovery/polling pipeline.

configured-model fallback applies only to Tasks that were legitimately DSH-eligible in the first place.


## Late discovery / misroute

If a DSH child discovers only after execution starts that the Task is actually `visual` or `long_wait`, it must not improvise around the routing boundary. Return `DSH_STOPPED_VISUAL_MISROUTE` or `DSH_STOPPED_LONG_WAIT_MISROUTE` with partial evidence, then let Coordinator re-route the Task.

## Tester backend override

即使某个普通测试技术上可由 DSH 执行，本团队正式 Tester 仍默认由 Codex child 承担：

```text
<team-configured-fallback-model> + medium
```

DSH Coder 可以在 self-check 中运行短 smoke，但正式 Tester verdict 由 Codex Tester 给出。
