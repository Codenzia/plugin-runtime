# plugin-runtime

Reusable GitHub Actions workflows for the Codenzia Filament / Laravel package
suite. Mirrors the `deploy-runtime` pattern — one source of truth, every
plugin repo invokes the workflows via `uses:`.

Two reusable workflows live here:

| Workflow | Trigger in caller | Purpose |
|---|---|---|
| [`plugin-tests.yml`](.github/workflows/plugin-tests.yml) | `push` to `main` + `pull_request` | Matrix Pest tests (Laravel 12/13 × Filament 4/5 for Filament plugins; Laravel 12/13 for pure-Laravel plugins) + `pint --test`. Laravel 11 was dropped from the default matrix on 2026-05-20 — no Codenzia app or plugin still runs on it. |
| [`plugin-release.yml`](.github/workflows/plugin-release.yml) | `push` of a `v*` tag | Force-pushes the tagged commit + tag from the `-dev` repo to the public mirror, then creates a GitHub Release on the public repo. Packagist auto-detects via its webhook. |

## Caller examples

### Filament plugin (`filament-panel-base-dev/.github/workflows/tests.yml`)

```yaml
name: tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  tests:
    uses: Codenzia/plugin-runtime/.github/workflows/plugin-tests.yml@main
```

### Pure-Laravel plugin (`browser-console-dev/.github/workflows/tests.yml`)

```yaml
name: tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  tests:
    uses: Codenzia/plugin-runtime/.github/workflows/plugin-tests.yml@main
    with:
      pure_laravel: true
```

### Release (`filament-panel-base-dev/.github/workflows/release.yml`)

```yaml
name: release
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: Codenzia/plugin-runtime/.github/workflows/plugin-release.yml@main
    with:
      public_repo: Codenzia/filament-panel-base
    secrets: inherit
```

### Release for plugins without a `-dev` mirror (e.g. `laravel-superadmin`)

```yaml
name: release
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: Codenzia/plugin-runtime/.github/workflows/plugin-release.yml@main
    # public_repo omitted → workflow creates the release on the current repo
    secrets: inherit
```

## Secrets

- `CODENZIA_PAT` — classic personal access token with `repo` scope. Required
  in the calling repo's secrets (org-level secrets don't propagate to private
  repos on the GitHub Free plan). Used to force-push to the public mirror and
  to create the GitHub Release on the public repo.

## Release flow end-to-end

1. Land changes on `main` of `Codenzia/<plugin>-dev`. Tests run automatically.
2. Bump version in `composer.json` (and update `CHANGELOG.md`).
3. Tag and push:
   ```bash
   git tag -a v1.2.0 -m "Release v1.2.0"
   git push origin v1.2.0
   ```
4. The release workflow fires:
   - Re-validates that the tag is semver-shaped (`v1.2.0`, `v1.2.0-beta.1`, etc.).
   - Pushes `HEAD` and the tag to `Codenzia/<plugin>` (the public mirror).
   - Creates a GitHub Release on the public repo, with notes extracted from
     the matching `CHANGELOG.md` section.
5. Packagist's webhook (configured once on Packagist when the public repo
   was submitted) detects the new tag and publishes it. End users can now
   `composer require codenzia/<plugin>:^1.2`.

## One-time per plugin

- **Submit to Packagist**: log in at packagist.org → Submit → paste the
  **public** repo URL. After submission, Packagist auto-syncs on every push.
- **Add `CODENZIA_PAT` secret** to the `-dev` repo: GitHub → Settings →
  Secrets and variables → Actions → New repository secret.
- **Drop the two caller workflow files** (`.github/workflows/tests.yml` and
  `.github/workflows/release.yml`) into the `-dev` repo.

## Customization

Both reusable workflows accept inputs (PHP extensions, branch name, whether
to run Pint, etc.) — see the `inputs:` blocks at the top of each workflow
file for the full list. Defaults match the Codenzia plugin conventions
(PHP 8.3, Laravel 11/12/13, Filament 4/5, Pest, Pint).
