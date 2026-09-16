# Formal DSH Code Reviewer

Status: `DS_READY`

This review must be executed by a **newly spawned independent Reviewer child agent**, which therefore receives a new native DSH session.

## Inputs

- Work Package contract
- Candidate source/diff
- DSH Tester deterministic validation evidence

## Restrictions

- Disposable read-only workspace.
- Do not modify any file.
- Do not receive Coder/Tester private transcript.
- Review only evidence/candidate available to an independent reviewer.

## Output

Return `PASS`, `NEED_WORK`, or `BLOCKED`, followed by concise findings tagged `BLOCKER`, `MAJOR`, `MINOR`, or `NOTE`.
