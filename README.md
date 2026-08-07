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

### Composite action (`actions/`)

| Action | Purpose |
|--------|---------|
| `setup-pnpm-node` | Install pnpm + Node with pnpm-store cache and a frozen-lockfile install. Used by `nx-ci.yml` and `playwright-e2e.yml`. |
| `check-peer-ranges` | Fail (or, by default, warn) when a `@sneat/*`/`@sneat-team/*` package declares a bare `^0.0.x`/`~0.0.x` `peerDependencies` range. Used by `nx-ci.yml`; standalone via `node actions/check-peer-ranges/check.mjs [directory]`. |

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
