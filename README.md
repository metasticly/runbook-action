# Runbook: start checklist run

A GitHub Action that opens a [Runbook](https://runbook.metastic.ch) checklist run from your pipeline.
Use it to open the release checklist when a tag is pushed, to open the patching checklist every month, or to
**gate a deploy** until someone has checked every required step.

It is a composite action made of one bash script that uses `curl` and `jq`, so it has no Node.js dependencies.
Both tools are preinstalled on GitHub-hosted runners. The same script also runs in GitLab CI, Forgejo Actions or
cron (see [examples/](examples/)).

## Quick start

1. In Runbook, open **Settings → API tokens** and create a token. It starts with `rb_`.
2. In GitHub, add the token as a repository secret named `RUNBOOK_TOKEN`.
3. Create a template in Runbook, for example `Release {{version}}`.
4. Add a workflow:

```yaml
on:
  push:
    tags: ["v*"]

jobs:
  checklist:
    runs-on: ubuntu-latest
    steps:
      - id: runbook
        uses: metasticly/runbook-action@v1
        with:
          api-token: ${{ secrets.RUNBOOK_TOKEN }}
          template: release-version   # slug of "Release {{version}}" (or its id or name)
          variables: |
            version=${{ github.ref_name }}
      - run: echo "Checklist: ${{ steps.runbook.outputs.run-url }}"
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api-token` | yes | | Runbook API token (`rb_…`). Always pass it from a secret. |
| `template` | yes | | Template id (for example `12`), **slug** (for example `release-checklist`, shown in the template editor) or exact name. Runbook tries id, then slug, then name (case-insensitive; if several templates share a name, the oldest one wins). Prefer the slug: it stays the same when someone renames the template. |
| `title` | no | template name | Run title, up to 200 characters. |
| `variables` | no | | One `key=value` per line. Every variable the template uses must be set, or Runbook answers 422. Whitespace around keys and values is trimmed. Blank lines and lines starting with `#` are ignored. Values can contain `=`. |
| `due-date` | no | | Due date, `YYYY-MM-DD`. Runbook notifies when the run is overdue. |
| `base-url` | no | `https://runbook.metastic.ch` | Must be `https://`. Plain `http://` is only accepted for localhost. |
| `wait-for-completion` | no | `false` | `true` makes the step poll the run and succeed only once it is **completed**, meaning all required items are checked and someone pressed *Complete*. |
| `timeout` | no | `3600` | Seconds to wait. After this the step fails with exit code 3. |
| `poll-interval` | no | `30` | Seconds between status checks. The minimum is 2. |
| `idempotency-key` | no | `${{ github.run_id }}-${{ github.run_attempt }}` | Sent as `Idempotency-Key` (with a 12-character hash of the request appended, so two Runbook steps in one workflow do not collide). Within 24 hours, the same key returns the run that was already opened instead of a new one. Set it to `""` to send no key. |

## Outputs

| Output | Description |
|---|---|
| `run-id` | Id of the created run |
| `run-url` | Browser URL of the run, which you can post to Slack or a PR |
| `status` | `open`, `completed` after a successful wait, or `cancelled` |

The step also writes a link to the run into the job summary.

## Examples

### Deploy gate

```yaml
jobs:
  checklist:
    runs-on: ubuntu-latest
    timeout-minutes: 125
    steps:
      - uses: metasticly/runbook-action@v1
        with:
          api-token: ${{ secrets.RUNBOOK_TOKEN }}
          template: production-deploy-version
          variables: |
            version=${{ github.sha }}
          wait-for-completion: "true"
          timeout: "7200"
  deploy:
    needs: checklist
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh
```

A waiting job keeps a runner busy, and GitHub bills hosted minutes while it waits.
Keep `timeout` short, or run the waiting job on a self-hosted runner.
For sign-offs that can take hours, open the run in one workflow and let a human trigger the deploy (`workflow_dispatch`) once it is done.

### Monthly release

```yaml
on:
  schedule:
    - cron: "0 7 1 * *"   # 07:00 UTC on the 1st of every month
jobs:
  open-checklist:
    runs-on: ubuntu-latest
    steps:
      - id: meta
        run: |
          echo "version=$(date -u +%Y.%m)" >> "$GITHUB_OUTPUT"
          echo "due=$(date -u -d '+6 days' +%Y-%m-%d)" >> "$GITHUB_OUTPUT"
      - uses: metasticly/runbook-action@v1
        with:
          api-token: ${{ secrets.RUNBOOK_TOKEN }}
          template: monthly-release-version
          variables: version=${{ steps.meta.outputs.version }}
          due-date: ${{ steps.meta.outputs.due }}
```

Complete files:

- [examples/github-deploy-gate.yml](examples/github-deploy-gate.yml)
- [examples/github-monthly-release.yml](examples/github-monthly-release.yml)
- [examples/gitlab-ci.yml](examples/gitlab-ci.yml) (uses the script directly and exposes the run via a dotenv artifact)
- [examples/forgejo-release.yml](examples/forgejo-release.yml) (Forgejo and Gitea Actions)

## Errors

The step fails with a GitHub error annotation and a clear message:

| Exit code | Cause |
|---|---|
| 1 | HTTP 401 (bad or revoked token), 402 (plan limit reached, e.g. the Free plan allows 10 API runs a month), 404 (template not found), 422 (missing variable or invalid date), 429 (rate limit of 120 requests per minute per token), 5xx, or network errors |
| 2 | Invalid input, or `curl`/`jq` missing |
| 3 | `wait-for-completion` timed out. The `run-id` and `run-url` outputs are still set. |
| 4 | The run was **cancelled** in Runbook while the step was waiting (the reason is shown). `status` is `cancelled`. |

With an idempotency key (the default), starting the run is retried up to 3 times on network errors, 429 and 5xx:
the key guarantees that a retry cannot open a second run. Re-running a job in the same workflow attempt also returns
the existing run. Without a key (`idempotency-key: ""`) the POST is never retried. While waiting, the step
tolerates up to 5 failed status checks in a row (5xx, 429 or network errors).

The 402 message includes the quota from Runbook, for example `(api_runs: 10/10 on the Free plan, resets 2026-12-01T00:00:00Z)`.

## Security

- Inputs reach the script as environment variables. They are never interpolated into shell code, so a template
  name or variable value like `$(rm -rf /)` is just text.
- The token is masked in logs, and it goes to curl through a temporary header file (mode 0600). It never appears
  on a command line, so other processes on a shared runner cannot read it from the process list.
- Only HTTPS is allowed, except for `localhost`.

## API used

| Call | Purpose |
|---|---|
| `POST /api/v1/runs` with `{"template" \| "template_id", "title", "variables", "due_date"}` and `Idempotency-Key` | Create the run (201, `{"id", "url", "status", …}`; 200 with the original run when the key was used before) |
| `GET /api/v1/runs/{id}` | Poll `status` (`open`, `completed` or `cancelled`), `items_checked`, `items_total`, `required_open` |

Runbook's REST API can do more (list runs, cancel a run, check items from CI, import templates, completion
callbacks). Create a token under **Settings → API tokens** to use it from any pipeline.

Both calls authenticate with `Authorization: Bearer rb_…`.

## Development

```sh
tests/run-tests.sh                                     # runs the script against a mock API (bash, curl, jq, python3)
shellcheck -x scripts/start-run.sh tests/run-tests.sh
actionlint examples/github-*.yml
```

`.github/workflows/test.yml` runs shellcheck, the tests and the action itself against the mock API on every push and
pull request. It uses no secrets and never calls the real Runbook API.

The tests start `tests/mock_server.py` on a random localhost port. They cover success by name and by id,
request body encoding (including shell metacharacters), 401, 402 (with quota), 404, 500 (not retried without a key),
templates by slug, the idempotency key (fingerprint suffix, replay with 200, different keys per request, retry of a
503 with the same key, giving up after 3 retries), waiting until completion, a cancelled run (exit 4), a transient
503 while waiting, timeout, an unreachable server, and input validation.

## Versioning

Use `metasticly/runbook-action@v1` to get compatible updates automatically, or pin a release (`@v1.0.0`) or a
commit SHA. `v1` moves with every `v1.x.y` release, breaking changes get a new major tag.

## Feedback

Found a bug or missing an input? Open an issue in [metasticly/runbook-action](https://github.com/metasticly/runbook-action/issues)
or use the feedback link in Runbook.

## Publishing (maintainers)

The source of truth is `integrations/github-action/` in the Runbook monorepo. `scripts/publish.sh` there exports that
directory (without the publish script itself) to the root of [metasticly/runbook-action](https://github.com/metasticly/runbook-action),
pushes `main`, creates the release tag and moves the major tag. Don't commit to the GitHub repository directly:
the next publish overwrites it.

## License

MIT, see [LICENSE](LICENSE).
