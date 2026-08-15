---
format: https://specscore.md/feature-specification
status: Draft
---

# Feature: CI and coverage policy

> [SpecScore.**Studio**](https://specscore.studio): | [Explore](https://specscore.studio/app/github.com/sneat-co/cicd/spec/features/ci-coverage-policy?op=explore) | [Edit](https://specscore.studio/app/github.com/sneat-co/cicd/spec/features/ci-coverage-policy?op=edit) | [Ask question](https://specscore.studio/app/github.com/sneat-co/cicd/spec/features/ci-coverage-policy?op=ask) | [Request change](https://specscore.studio/app/github.com/sneat-co/cicd/spec/features/ci-coverage-policy?op=request-change) |
**Status:** Draft
**Source Ideas:** —

## Summary

Fleet CI coverage policy, including how declaration-only packages are validated without manufacturing metrics.

## Problem

Fleet CI requires positive coverage where executable production behavior exists.
Some contract packages intentionally contain only declarations, however, so Go
coverage reports zero instrumented statements even when their wire-format tests,
lint, race test, and build all pass. Without an explicit policy, a team must
either manufacture runtime code to satisfy a metric or silently weaken a gate.

## Behavior

The CI policy will distinguish executable packages from declaration-only
packages using reproducible instrumentation evidence. It will keep the existing
requirement for real tests and positive coverage where production statements are
instrumentable, while making any exception explicit, narrowly proved, and
reviewable.

## Acceptance Criteria

- The policy question records the observed zero-instrumentable-statement case
  without changing a coverage floor or claiming an exemption.
- Any future exemption requires reproducible proof that the package has zero
  instrumentable production statements and retains lint, build, race, and wire
  contract validation.
- Any future non-exemption path names the approved runtime validation scope
  instead of adding artificial behavior solely for metric compliance.

## Open Questions

- For a declaration-only Go contract package that has zero instrumentable
  production statements, should the fleet CI policy grant an explicit coverage
  exemption when the build proves that fact and lint, race, and wire-contract
  tests pass, or should it require an approved runtime validation scope before
  the package can satisfy CI? This Feature does not choose either policy.

---
*This document follows the https://specscore.md/feature-specification*
