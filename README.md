# cicd

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
| `nx-ci.yml` | `pnpm install` + `nx run-many -t <targets>` | `working-directory` (default `frontend`), `targets` (default `lint test build`), `node-version`, `pnpm-version` |
| `playwright-e2e.yml` | Playwright e2e for an Nx app (with browser cache) | `working-directory`, `e2e-project-directory` (required), `project` (default `chromium`) |
| `cf-deploy.yml` | Build a project (Astro landing, Nx app, or landing + assembled root-mounted app) and deploy to Cloudflare (Workers static assets) via wrangler | `working-directory` (default `frontend`), `build-command` (e.g. `pnpm build`; falls back to `pnpm exec nx build <build-target>` when empty), `build-target` (Nx fallback), `extra-install-directory` (second workspace to `pnpm install`, e.g. `.` or `frontend` for assembled apps), `cloudflare-account-id` (pass `${{ vars.CLOUDFLARE_ACCOUNT_ID }}`), `wrangler-config` (default `wrangler.jsonc`), `smoke-command` (optional post-deploy smoke); secret `CLOUDFLARE_API_TOKEN` |

### Composite action (`actions/`)

| Action | Purpose |
|--------|---------|
| `setup-pnpm-node` | Install pnpm + Node with pnpm-store cache and a frozen-lockfile install. Used by `nx-ci.yml` and `playwright-e2e.yml`. |

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

## Prerequisite for private consumers

Because sneat-co repos are private, this repo must **allow Actions access from
other repositories in the organisation** so they can call these workflows/actions
(repo → Settings → Actions → General → *Access*, set to
"Accessible from repositories in the 'sneat-co' organization"). This is set via:

```bash
gh api -X PUT repos/sneat-co/cicd/actions/permissions/access \
  -f access_level=organization
```
