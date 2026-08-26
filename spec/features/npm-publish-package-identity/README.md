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

`npm-publish.yml` checks the caller's package manifests immediately after
checkout. The check runs before dependency installation, builds, and exposure
of `NPM_TOKEN` or `NODE_AUTH_TOKEN`.

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
  source-visible public package identities are refused. The publish command may
  only publish identities represented by those source manifests; a package
  generated after the preflight is unsupported until it has a provider-owned
  source identity and policy path.

The template rule is distinct from that ownership mapping:

- Only `sneat-co/sneat-ext-contract-template` may publish
  `@sneat/extension-template-contract`.
- Any other repository fails for the template package, a placeholder manifest
  name, a template-named project/path, or a retained `@sneat/*template*`
  dependency.

The provider emits a stable JSON receipt containing the repository, the NPM
publisher identity policy version 1, and every accepted package manifest. It
never prints a credential.

The companion audit scans immediate, non-hidden, non-symlinked children of an
organization checkout so `.worktrees`, historical copies, and node modules do
not become publishers. It records the repository, Git ref, workflow,
automatic/manual/disabled trigger class, manifest, and package for every
detected publisher. It rejects a direct automatic publisher alongside a shared
provider publisher, and rejects the same package with automatic owners in more
than one repository. The provider-owned, manual-only audit workflow is the
only authoritative path: it uses the existing organization-read
`SNEAT_ORGANIZATION_AUDIT_TOKEN` to enumerate the complete non-archived GitHub
owner set, records each default ref/SHA and fetched time, checks out every
recorded SHA, then obtains fresh GitHub API evidence during the audit. Its run
log is the immutable receipt and no artifact is retained. A local scan or
hand-authored `--inventory` JSON stays diagnostic; `--require-authoritative`
requires the closed `--github-api` path and refuses it. A manual-only scaffold
remains visible but unarmed; if it is dispatched, the runtime identity
preflight still refuses unrebranded template content. Identity findings are
retained in every audit receipt, and `--require-publish-identities` refuses
them when a rebrand audit intentionally includes manual scaffolds.

## Journey

1. A maintainer pushes a legitimate extension release workflow. Observable good
   result: the provider prints one accepted identity receipt before installation.
2. The provider installs and builds the caller workspace. Observable good
   result: the existing caller command remains unchanged and token-free until
   the final publish step.
3. The final step receives the npm token and executes the existing publish
   command. Observable good result: only the repository-bound package family
   can reach npm.
4. A copied template, wrong-repository package, incomplete rebrand, retained
   template dependency, or duplicate automatic publisher instead stops before
   installation and publishing. Observable good result: its deterministic code
   and manifest/workflow evidence identify the owning fix.

## Acceptance Criteria

- The reusable publisher invokes the identity action after checkout and before
  install, build, publish, `NPM_TOKEN`, and `NODE_AUTH_TOKEN` use.
- A legitimate conventional package and the canonical contract template pass
  without a new caller input.
- Wrong-repository identities and unknown public package identities fail.
- A copied template package, an incompletely rebranded project, and a retained
  template dependency fail unless the repository is exactly
  `sneat-co/sneat-ext-contract-template`.
- The Debtus-to-Splitus exception is limited to the provider policy and cannot
  satisfy the template exception.
- The audit distinguishes automatic, manual-only, disabled, and other
  non-release workflows; it exits non-zero with exact repository/ref/workflow/
  package evidence for duplicate automatic owners.
- The test corpus covers the positive release journey and all stated negative
  cases, including token-step ordering.

## Organization Audit and Migration Set

Run the provider-owned manual audit workflow for the organization-clean result;
it intentionally excludes archived repositories and records that policy. The
2026-08-26 local canonical scan below is non-authoritative diagnostic evidence,
not an organization-clean receipt: its checked-out root had 123 canonical-name
repositories but does not prove the remote owner set, and
`sneat-co/sneat-ext-contracts` local `main` was four commits behind its
`origin/main`. It nevertheless demonstrated three migration classes that the
authoritative audit must resolve:

1. `sneat-co/ext-circleus` at
   `b951948f483b6f1da80958fe7bbd9b78c050488b`,
   `.github/workflows/publish.yml`, automatically claims
   `@sneat/extension-template-contract`, which is also claimed by
   `sneat-co/sneat-ext-contract-template` at
   `c5440031372253759ad1835907caabc0ccf51f23`. The provider preflight blocks
   the copied source. Its owner must rebrand package names, project names/paths,
   and retained template dependencies before retaining an automatic publisher,
   or remove that publisher.
2. `sneat-co/sneat-ext-contracts` at
   `c49c43b16f122f0d5a4622b7b2b3cd607b1dfdc0`,
   `.github/workflows/publish.yml`, is an automatic direct publisher that
   claims extension-contract packages also claimed by the corresponding
   `sneat-co/ext-*` repositories. The audit emits each exact pair, including
   assetus, bookius, budgetus, calendarius, contactus, debtus, docus, eventius,
   formius, gameboard, kids-club, listus, localius, remindius, renewon,
   requoter, rsvp-express, schoolus, sizeus, sourcer, splitus, sportius, taxus,
   sneat-team, trackus, work, and yardius.

The latter is an ownership migration, not a safe provider-only edit. Its owner
must select one source of truth per package (the `ext-*` repositories or
`sneat-ext-contracts`) and retire the other automatic publisher only after that
cutover. This Feature does not choose that rollout policy.

3. `sneat-co/debtus` at
   `68d1ab4715136317125071b10b8634b77f3edf46`,
   `.github/workflows/publish.yml`, has a manual shared publisher whose
   `frontend` workspace contains zero source-visible public package manifests.
   It now fails `NO_PUBLISHABLE_PACKAGE_IDENTITY` before installation and token
   exposure. Its owner must add the real source package manifest/identity (with
   the narrow Debtus-to-Splitus policy still applying), or retire/replace that
   publisher; the provider does not allow a post-build generated package to
   bypass identity verification.

## Open Questions

- Which repository owns each duplicated extension-contract package found by the
  organization audit, and what release order retires the losing automatic
  publisher without an unpublished interval?

---
*This document follows the https://specscore.md/feature-specification*
