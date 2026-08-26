# cicd

Shared CI/CD workflows and composite actions for Sneat repositories.

## Build once, deploy the validated artifact

`nx-ci.yml` can package repository-relative build outputs after lint, tests,
coverage and build complete. The artifact contains a reproducible tar archive,
the full source SHA, a JSON provenance manifest and a SHA-256 checksum.

`firebase-deploy.yml` downloads that artifact from the exact successful CI run,
verifies the SHA and checksum, and deploys it without installing application
dependencies or rebuilding source. Automatic and recovery deployments therefore
promote the same bytes that CI validated.

Coverage is part of the reusable Nx contract: callers provide a coverage command,
an LCOV path and an explicit minimum line-coverage percentage. A missing report or
a result below the threshold fails CI.

`playwright-artifact-e2e.yml` restores the same build artifact and can run several
Playwright suites sequentially after a single dependency/browser setup. Its SPA
server handles client-side routes, and Playwright configs opt out of their normal
development web server via `E2E_SKIP_WEBSERVER`, so E2E never rebuilds the app.

## Peer dependency ranges on packages we publish

`nx-ci.yml` scans every `package.json` in the checked-out repo for a bare
`^0.0.x` (or `~0.0.x`) range in `peerDependencies` on a `@sneat/*` or
`@sneat-team/*` package. Under semver, a caret on a `0.0.x` version permits
nothing but that exact patch, so the moment the dependency publishes its next
`0.0.x` patch, pnpm installs two physical copies side by side. Two copies
means two distinct `InjectionToken` objects, and Angular DI matches providers
by object identity — the app resolves one token, the library asks for the
other, and specs fail with `NG0201: No provider found for InjectionToken ...`
while TypeScript stays green throughout, because both copies are structurally
identical. Widen the range instead: an explicit union
(`^0.0.5 || ^0.0.6`), an interval (`>=0.0.5 <0.1.0`), or an exact pin all
resolve to a single installed copy.

The check runs via the `check-peer-ranges` composite action and is
report-only by default (`continue-on-error`, driven by the `peer-range-strict`
input) while the fleet clears its existing bare ranges; pass
`peer-range-strict: true` once a repo's own `@sneat/*` peerDependencies are
clean to make it a hard gate. Run it standalone with
`node actions/check-peer-ranges/check.mjs [directory]` (defaults to the
current directory) — this is also how `wb` and local runs invoke it.

Shared **reusable GitHub Actions workflows** and **composite actions** for
sneat-co repositories (e.g. [`assetus`](https://github.com/sneat-co/assetus),
[`listus`](https://github.com/sneat-co/listus)). One place to define how we lint,
test, build and e2e Go backends and Nx/Angular frontends, so consumer repos stay
a few lines long and upgrades happen once.

## What's here

### Reusable workflows (`.github/workflows/*.yml`, `on: workflow_call`)

| Workflow | Purpose | Key inputs |
|----------|---------|-----------|
| `go-ci.yml` | Lint (`gofmt` + `go vet`), `go test`, `go build` a Go module | `working-directory` (default `backend`); `gofmt` = `error` (default, fail on unformatted) / `warn` (annotate only) / `off` |
| `nx-ci.yml` | `pnpm install` + `nx run-many -t <targets>` | `working-directory` (default `frontend`), `targets` (default `lint test build`), `node-version`, `pnpm-version`, `peer-range-strict` (default `false`; gates bare `^0.0.x` peer ranges on `@sneat/*` packages when `true`) |
| `playwright-e2e.yml` | Playwright e2e for an Nx app (with browser cache) | `working-directory`, `e2e-project-directory` (required), `project` (default `chromium`) |
| `cf-deploy.yml` | Build a project (Astro landing, Nx app, or landing + assembled root-mounted app) and deploy to Cloudflare (Workers static assets) via wrangler | `working-directory` (default `frontend`), `build-command` (e.g. `pnpm build`; falls back to `pnpm exec nx build <build-target>` when empty), `build-target` (Nx fallback), `extra-install-directory` (second workspace to `pnpm install`, e.g. `.` or `frontend` for assembled apps), `cloudflare-account-id` (pass `${{ vars.CLOUDFLARE_ACCOUNT_ID }}`), `wrangler-config` (default `wrangler.jsonc`), `smoke-command` (optional post-deploy smoke), `setup-tinygo` (default `false`, installs TinyGo before the build for callers compiling Go to wasm), `tinygo-version` (default `0.41.1`); secret `CLOUDFLARE_API_TOKEN` |
| `deps-policy.yml` | Gate a Go module against the fleet's dependency and layering policy (`policy/sneat-backend.yaml`). Lexical scan of import blocks and `go.mod` — **no credentials, no module downloads**, so it still reports when the build cannot start | `working-directory` (default `backend`), `policy` (override the document), `policy-ref` (ref of this repo the default policy is read from, default `main`), `wb-version` (default `v0.37.0`, the release that introduced the command; pinned rather than `latest`), `strict` (default `false`; only ever tightens) |
| `go-module-tags.yml` | Create and push idempotent, validated annotated Git tags (`<module-dir>/v<version>`) for one or more Go modules in subdirectories of the calling repository. The caller passes explicit `{dir, version}` pairs (e.g. from its own consumed Nx release version plans) — this workflow never guesses versions or scans for changes. Fails loudly on a `go.mod` module-path mismatch and refuses to move an existing tag onto a different commit; requires `permissions: contents: write` in the caller | `modules` (required JSON array of `{"dir", "version"}` pairs), `ref` (optional commit SHA, default `github.sha`) |

### Composite action (`actions/`)

| Action | Purpose |
|--------|---------|
| `setup-pnpm-node` | Install pnpm + Node with pnpm-store cache and a frozen-lockfile install. Used by `nx-ci.yml` and `playwright-e2e.yml`. |
| `check-peer-ranges` | Fail (or, by default, warn) when a `@sneat/*`/`@sneat-team/*` package declares a bare `^0.0.x`/`~0.0.x` `peerDependencies` range. Used by `nx-ci.yml`; standalone via `node actions/check-peer-ranges/check.mjs [directory]`. |
| `go-module-tags` | Validate `{dir, version}` pairs against each module's `go.mod`, then create and push idempotent annotated `<dir>/v<version>` tags. Used by `go-module-tags.yml`; standalone via `GO_MODULE_TAGS_MODULES=... GITHUB_REPOSITORY=... actions/go-module-tags/tag-modules.sh`. |

## Dependency policy (`policy/`)

`policy/sneat-backend.yaml` states which kinds of repository may depend on
which kinds of dependency, and which direction imports may travel between
packages inside a repository. It replaces the hand-written `git grep`
architecture guards that calendarius, competios, togethered and gametable each
carried separately, with four differently-encoded allowlists between them.

It is applied by [`wb deps policy`](https://github.com/sneat-dev/wb), either
through `deps-policy.yml` above or locally:

```sh
wb deps policy check ./backend --policy sneat-co/cicd//policy/sneat-backend.yaml
wb deps policy explain github.com/dal-go/dalgo2firestore ./backend
```

A consuming repository declares two lines and may tighten but never loosen:

```yaml
# backend/.wb-deps-policy.yaml
policy: sneat-co/cicd//policy/sneat-backend.yaml
type: extension-implementation      # optional — detected from the module path
```

It names the policy **source** and never a release. That is deliberate: a
repository frozen on an old policy would be carrying an exception nobody wrote
down. The release is resolved by the caller — `policy-ref` in the workflow
above — so a tightened rule reaches every repository at once.

**Changing this file changes the rules everywhere.** `validate-policy.yml`
runs `wb deps policy validate` and `wb deps policy test` on every pull request
touching `policy/`. Those catch mistakes in the document — chiefly a pattern an
earlier declaration already claims in full, which silently changes every verdict
downstream and errors nowhere. They do not measure who the change would break,
so run that yourself before merging and paste the output into the pull request:

```sh
wb deps policy impact policy/sneat-backend.yaml --match 'sneat-co/*'
```

Layer rules currently ship in `report` mode. Their mode lives in this document,
not in any repository, so no repository can demote a rule that binds everyone
else — and promoting them to `enforce` is one commit here once the burn-down
(`wb deps policy report --match 'sneat-co/*'`) reaches zero.

There is no exception mechanism: no baseline, no per-repository allowlist, no
severity dial. A repository either satisfies the rules or cannot gate on them.

## Deploy auth (org-level, one place)

Cloudflare deploys via `cf-deploy.yml` authenticate with two org-level values
(no per-repo secrets needed):

- **`CLOUDFLARE_API_TOKEN`** — org **secret** (Workers Scripts:Edit; Workers
  Routes / Zone:DNS:Edit only needed when CI must (re)attach custom domains).
- **`CLOUDFLARE_ACCOUNT_ID`** — org **variable** (an identifier, not a secret;
  it appears in dashboard URLs). Callers pass it as the
  `cloudflare-account-id` input: `${{ vars.CLOUDFLARE_ACCOUNT_ID }}`.
  Passing it explicitly avoids wrangler's `/memberships` auto-detect, which a
  scoped token can't call.

The canonical consumer shape:

```yaml
# .github/workflows/deploy-landings.yml in the consumer repo
name: Deploy landing (Cloudflare)
on:
  workflow_dispatch:
  push:
    branches: [main]
    paths: [landings/**]

jobs:
  deploy:
    uses: sneat-co/cicd/.github/workflows/cf-deploy.yml@main
    with:
      working-directory: landings
      build-command: pnpm build
      cloudflare-account-id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
      # extra-install-directory: "."      # when the landing assembles a root-mounted app
      # smoke-command: node scripts/post-deploy-smoke.mjs https://example.com
    secrets:
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

## Usage

A consumer repo with a Go `backend/` and an Nx `frontend/` gets a single CI
workflow: backend and frontend run in parallel, e2e runs only if both pass.

```yaml
# .github/workflows/ci.yml in the consumer repo
name: CI
on:
  push: { branches: [main] }
  pull_request:
permissions: { contents: read }
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  backend:
    uses: sneat-co/cicd/.github/workflows/go-ci.yml@main
    with:
      working-directory: backend

  frontend:
    uses: sneat-co/cicd/.github/workflows/nx-ci.yml@main
    with:
      working-directory: frontend
      targets: "lint test build"

  e2e:
    needs: [backend, frontend]      # runs only when both succeed
    uses: sneat-co/cicd/.github/workflows/playwright-e2e.yml@main
    with:
      working-directory: frontend
      e2e-project-directory: frontend/apps/<app>-e2e
```

## Versioning

Consumers pin `@main` for always-latest, or a tag/SHA for stability
(e.g. `@v1`). Prefer a moving `v1` tag for breaking-change isolation once this
stabilises.

## Shared Renovate policy

`default.json` is the shared Renovate preset for Sneat repositories. It runs
early on Monday mornings in the `Europe/Dublin` timezone and groups:

- GitHub Actions updates;
- JavaScript dependency updates detected by Renovate's `npm` manager, including
  pnpm workspaces and lockfiles;
- dependencies published from the `sneat-co` GitHub organization.

Consumer repositories enable it with:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    "github>sneat-co/cicd"
  ]
}
```

Add ecosystem-specific presets before `github>sneat-co/cicd` when needed. Go
repositories currently also extend `github>sneat-co/sneat-renovate-go`.

## Prerequisite for private consumers

Because sneat-co repos are private, this repo must **allow Actions access from
other repositories in the organisation** so they can call these workflows/actions
(repo → Settings → Actions → General → *Access*, set to
"Accessible from repositories in the 'sneat-co' organization"). This is set via:

```bash
gh api -X PUT repos/sneat-co/cicd/actions/permissions/access \
  -f access_level=organization
```
