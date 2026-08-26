---
format: https://specscore.md/feature-specification
status: Implementing
---

# Feature: NPM publisher package identity

> [SpecScore.**Studio**](https://specscore.studio): | [Explore](https://specscore.studio/app/github.com/sneat-co/cicd/spec/features/npm-publish-package-identity?op=explore) | [Edit](https://specscore.studio/app/github.com/sneat-co/cicd/spec/features/npm-publish-package-identity?op=edit) | [Ask question](https://specscore.studio/app/github.com/sneat-co/cicd/spec/features/npm-publish-package-identity?op=ask) | [Request change](https://specscore.studio/app/github.com/sneat-co/cicd/spec/features/npm-publish-package-identity?op=request-change) |
**Status:** Implementing
**Source Ideas:** —

## Summary

Provider-owned verification that binds an automatic NPM publisher to its repository and package identities.

## Problem

A reusable publisher accepted an arbitrary publish command after checkout. A
copied extension-contract scaffold could therefore keep its placeholder package
name, placeholder dependency and automatic publish workflow, then publish the
canonical template package from the wrong repository. The same lack of an
organization-wide ownership check allowed two automatic workflows to claim one
package without a deterministic failure.

## Behavior

`npm-publish.yml` is retained as a legacy migration-compatible reusable
workflow for the current caller fleet. It checks source package manifests after
checkout, before dependency installation and build, but it still accepts a
caller-controlled `publish-command` under `NPM_TOKEN` and `NODE_AUTH_TOKEN`.
It is therefore explicitly non-enforced: source preflight cannot prove which
post-build identity an arbitrary caller command will publish.

The provider-first strict contract is the intended cutover surface. A caller
will declare one static package directory and exact package name, and may run
token-free install/prepare steps. After prepare, the provider will validate the
exact source manifest, create a tarball with `npm pack --ignore-scripts`, read
the tarball's `package/package.json`, require that manifest bytes and package
identity match the approved source manifest, then publish only that tarball
from a provider-owned isolated step. The provider, not caller shell, will own
the only step with the npm credential. The strict reusable workflow is not yet
enabled, so this Feature cannot claim enforcement before its implementation,
caller cutover, and legacy retirement.

This closes identity selection through source and post-prepare packing. It does
not claim to validate arbitrary generated package contents or build side
effects; those are intentionally outside the package-identity contract.

For normal package identities, ownership is derived without a new caller input:

- `sneat-co/ext-<id>` owns `@sneat/extension-<id>-contract`.
- `sneat-co/<id>` owns its `@sneat/extension-<id>` package family.
- A package that declares `repository` must name the caller repository.
- Any other public package must have an exact provider-owned policy mapping or
  is refused. The current narrow mapping is
  `sneat-co/debtus` → `@sneat/extension-splitus` package family.
  Exact legacy-spelling mappings retain the existing callers
  `ext-kids-club` → `@sneat/extension-kidsclub-contract`,
  `ext-rsvp-express` → `@sneat/extension-rsvpexpress-contract`, and
  `ext-sneat-team` → `@sneat/extension-team-contract`. The reviewed public
  package list in `sneat-co/sneat-libs` is likewise an exact provider-owned
  mapping, never a caller-supplied package prefix.
- Unscoped public packages and publish workspaces with zero approved
  source-visible public package identities are refused. A post-build package
  generated after source preflight has no strict provider identity until it has
  a provider-owned source identity and policy path.

The template rule is distinct from that ownership mapping:

- Only `sneat-co/sneat-ext-contract-template` may publish
  `@sneat/extension-template-contract`.
- Any other repository fails for the template package, a placeholder manifest
  name, a template-named project/path, or a retained `@sneat/*template*`
  dependency.

The provider emits a stable JSON receipt containing the repository, the NPM
publisher identity policy version 1, and every accepted package manifest. It
never prints a credential or raw secret-bearing manifest value.

The companion audit scans immediate, non-hidden, non-symlinked children of an
organization checkout so `.worktrees`, historical copies, and node modules do
not become publishers. It structurally resolves top-level triggers, anchors,
aliases, reusable calls, local actions, scripts, package scripts, workspace
commands, credential propagation, and static working directories. It fails
closed for unresolved or dynamic evidence that could reach a publish sink;
dynamic values proven outside every publish-capable chain remain diagnostic.
An unproven relevant chain makes the audit `inconclusive`, never clean.

The audit records the repository, Git ref, workflow, automatic/manual/disabled
trigger class, manifest, and package for every detected publisher. It rejects a
direct automatic publisher alongside a shared-provider publisher, and rejects
the same package with automatic owners in more than one repository. The
provider-owned, manual-only audit workflow is the only authoritative path. It
uses `SNEAT_ORGANIZATION_AUDIT_TOKEN` only after verifying a classic user token
with the `repo` scope, active Sneat Co. organization-owner membership, and no
SSO ambiguity; fine-grained or limited tokens fail closed because they cannot
prove complete repository visibility. It enumerates the non-archived owner set,
records each default ref/SHA and fetched time, detached-checks out every
recorded SHA, then obtains fresh GitHub API evidence during the audit. Its run
log is the immutable receipt and no artifact is retained. A local scan or
hand-authored `--inventory` JSON stays diagnostic; `--require-authoritative`
requires the closed `--github-api` path and refuses it. A manual-only scaffold
remains visible but unarmed; if it is dispatched, the legacy runtime preflight
still refuses unrebranded template source content. Identity findings are
retained in every audit receipt, and `--require-publish-identities` refuses
them when a rebrand audit intentionally includes manual scaffolds.

## Journey

1. A maintainer moves a legitimate package release to the strict provider
   contract and declares its exact package directory and exact package name.
   Observable good result: the provider validates the accepted source identity
   before install/prepare and records the declaration.
2. The caller installs and prepares without an npm credential. Observable good
   result: no caller-controlled shell has `NPM_TOKEN` or `NODE_AUTH_TOKEN`.
3. The provider packs the declared directory with `npm pack --ignore-scripts`,
   verifies the packed manifest against the approved source manifest, and
   publishes only that tarball. Observable good result: the token-bearing step
   has a closed artifact input rather than caller shell.
4. A copied template, wrong-repository package, incomplete rebrand, retained
   template dependency, unscoped/zero-package workspace, duplicate automatic
   publisher, or unresolved publishing chain instead stops before publishing.
   Observable good result: its deterministic code and workflow/manifest
   evidence identify the owning fix.

The legacy journey remains available only so current callers do not silently
break before the migration decision. It must not be described as the strict
journey or as an enforcement result.

## Acceptance Criteria

- The strict reusable publisher accepts exactly one static package directory
  and exact package name; it accepts no caller `publish-command` or npm-token
  value.
- Its install/prepare phase is credential-free. The provider validates the
  source manifest, packs with `npm pack --ignore-scripts`, verifies the packed
  manifest bytes and identity, and publishes only the packed tarball under the
  npm token.
- A legitimate conventional package and the canonical contract template pass
  the strict contract with a declarative caller identity.
- Wrong-repository identities, unknown public identities, unscoped public
  identities, and zero-package publish workspaces fail.
- A copied template package, an incompletely rebranded project, and a retained
  template dependency fail unless the repository is exactly
  `sneat-co/sneat-ext-contract-template`.
- The Debtus-to-Splitus exception is limited to the provider policy and cannot
  satisfy the template exception.
- The audit distinguishes automatic, manual-only, disabled, and other
  non-release workflows; it exits non-zero with exact repository/ref/workflow/
  package evidence for duplicate automatic owners, and is inconclusive rather
  than clean for relevant unresolved/dynamic paths.
- The authoritative audit only runs manually, uses a verified all-repository
  entitlement, fetches and audits exact default-branch SHAs, and retains no
  artifact or cache receipt.
- The adversarial test corpus covers the positive strict package journey and
  all stated negative cases, including token-step ordering, duplicate JSON
  keys, credential redaction, path/symlink escape, dynamic publish chains, and
  4-space job indentation.

These criteria are not yet Enforced: the strict workflow, all caller cutovers,
and duplicate-owner resolution are still required. The associated Backstage
lesson must remain below Enforced until those conditions are met.

## Organization Audit and Migration Set

Run the provider-owned manual audit workflow for the organization-clean result;
it intentionally excludes archived repositories and records that policy. The
2026-08-27 local canonical scan below is non-authoritative diagnostic evidence,
not an organization-clean receipt: its checked-out root had 123 canonical-name
repositories but does not prove the remote owner set, and
`sneat-co/sneat-ext-contracts` local `main` was four commits behind its
`origin/main`. It nevertheless found 40 legacy shared-provider caller records,
five direct-publisher records, 28 duplicate package owners, and relevant
identity/workflow findings. Those results are migration evidence only; the
authoritative manual audit must resolve the exact current default-branch state.

The required additive migration set is:

1. `sneat-co/ext-circleus` at
   `b951948f483b6f1da80958fe7bbd9b78c050488b`,
   `.github/workflows/publish.yml`, automatically claims
   `@sneat/extension-template-contract`, which is also claimed by
   `sneat-co/sneat-ext-contract-template` at
   `c5440031372253759ad1835907caabc0ccf51f23`. The provider preflight blocks
   the copied source. Its owner must rebrand package names, project names/paths,
   and retained template dependencies before retaining an automatic publisher,
   or remove that publisher.
2. Twenty-eight `ext-*` shared callers use the legacy provider from
   `frontend`: `ext-assetus`, `ext-bookius`, `ext-budgetus`,
   `ext-calendarius`, `ext-circleus`, `ext-contactus`, `ext-debtus`,
   `ext-docus`, `ext-eventius`, `ext-formius`, `ext-gameboard`,
   `ext-kids-club`, `ext-listus`, `ext-localius`, `ext-remindius`,
   `ext-renewon`, `ext-requoter`, `ext-rsvp-express`, `ext-schoolus`,
   `ext-sizeus`, `ext-sneat-team`, `ext-sourcer`, `ext-splitus`,
   `ext-sportius`, `ext-taxus`, `ext-trackus`, `ext-work`, and `ext-yardius`.
   All but the copied `ext-circleus` scaffold are ordinary exact-identity
   candidates for the declarative strict contract. They must remain on legacy
   compatibility until an owner deliberately migrates each caller; this
   provider repository makes no consumer edit or rollout choice on their
   behalf.
3. Ten non-extension shared callers need explicit per-package declarations
   rather than a convention-only migration: `assetus`, `bookius`,
   `calendarius`, `contactus`, `eventius`, `listus`, `sizeus`, `sneat-astro`,
   `sneat-libs`, and `trackus`. Their current records span root and `frontend`
   working directories, multi-package workspaces, and manual/automatic
   triggers. `sneat-libs` is the reviewed exact package-set policy case, not a
   prefix bypass. Each package must become one strict declaration and provider
   packed artifact, so multi-package callers may require more than one strict
   job.
4. `sneat-co/debtus` at
   `68d1ab4715136317125071b10b8634b77f3edf46`,
   `.github/workflows/publish.yml`, has a manual shared publisher whose
   `frontend` workspace contains zero source-visible public package manifests.
   It now fails `NO_PUBLISHABLE_PACKAGE_IDENTITY` before installation and token
   exposure. Its owner must add the real source package manifest/identity (with
   the narrow Debtus-to-Splitus policy still applying), or retire/replace that
   publisher; the provider does not allow a post-build generated package to
   bypass identity verification.
5. `sneat-co/sneat-ext-contracts` at
   `c49c43b16f122f0d5a4622b7b2b3cd607b1dfdc0`,
   `.github/workflows/publish.yml`, is an automatic direct publisher that
   claims extension-contract packages also claimed by the corresponding
   `sneat-co/ext-*` repositories. The audit emits each exact pair, including
   assetus, bookius, budgetus, calendarius, contactus, debtus, docus, eventius,
   formius, gameboard, kids-club, listus, localius, remindius, renewon,
   requoter, rsvp-express, schoolus, sizeus, sourcer, splitus, sportius, taxus,
   sneat-team, trackus, work, and yardius. The local scan also found direct
   publisher records in `ext-calendarius` (manual), `sneat-apps` (manual), and
   two workflows in `sneat-libs` (one manual and one automatic). Their owners
   need an explicit strict-provider migration or retirement decision.

Duplicate ownership is an ownership migration, not a safe provider-only edit.
The owners must select one source of truth per package (the `ext-*` repositories
or `sneat-ext-contracts`) and retire the other automatic publisher only after
that cutover. This Feature does not choose a fleet rollout policy. Until all
classes cut over and an authoritative manual audit is clean, current duplicate
owners are expected audit failures and no Backstage lesson may claim Enforced.

## Open Questions

- Which repository owns each duplicated extension-contract package found by the
  organization audit, and what release order retires the losing automatic
  publisher without an unpublished interval?
- When will each of the 40 current legacy shared callers move to the strict
  declarative contract, and which maintainer owns the multi-package job split?
- Is the provider-owned credential-bearing strict workflow authorized for
  implementation in this branch now, or should the completed parser/audit
  hardening remain the frozen candidate while that separate authority is
  resolved?

---
*This document follows the https://specscore.md/feature-specification*
