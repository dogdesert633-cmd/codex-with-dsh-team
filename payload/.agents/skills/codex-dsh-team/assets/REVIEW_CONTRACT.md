# Formal DSH Code Reviewer Contract — <RUN-ID>

Status: `DS_READY_REVIEW_ONLY`

## Objective

以正式 Code Reviewer 角色，在 disposable workspace 中独立审查 candidate 是否满足合同与 DSH Tester 证据。

## Inputs

- Work Package contracts
- Candidate source/diff
- DSH Tester deterministic validation evidence

## Restrictions

- 使用全新 DSH session；
- 不接收 Coder/Tester 私有 reasoning/transcript；
- 不修改任何文件；
- 只报告有证据的 correctness、scope、security、regression 和 validation 问题。

## Output

```text
VERDICT: PASS | NEED_WORK | BLOCKED
FINDINGS:
- ID: ...
  SEVERITY: BLOCKER | MAJOR | MINOR | NOTE
  FILE: ...
  EVIDENCE: ...
  IMPACT: ...
SUMMARY: ...
```
