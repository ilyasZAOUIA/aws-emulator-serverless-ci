# Engineering decisions

Why the project is built the way it is, what each choice costs, and what is
still open. Observed emulator behaviour is detailed in
[`emulator-findings.md`](emulator-findings.md).

## Architecture: API Gateway, Lambda, DynamoDB

A URL shortener has two operations, create and resolve, each a single key-value
access. That fits a serverless design:

- **No idle cost or servers to patch.** Lambda and on-demand DynamoDB are billed
  per request.
- **DynamoDB matches the access pattern.** Every request reads or writes one item
  by its key (`code`). Two writes rely on DynamoDB guarantees instead of extra
  code:
  - `PutItem` with `attribute_not_exists(code)` makes code creation safe against
    collisions (the handler retries up to three times);
  - `UpdateItem` with `ADD hits :one` increments the counter atomically, so
    concurrent visits are not lost.
- **API Gateway REST API rather than HTTP API.** The REST API supports X-Ray
  tracing (enabled on the stage) and request validation, which HTTP APIs do
  not. An HTTP API would be cheaper and simpler, and would be a reasonable
  choice without those two needs.

The trade-off is cold starts on the first request after idle time. For a
redirect service that is acceptable.

## Redirect: 302, not 301

`GET /links/{code}` returns `302 Found` with `Cache-Control: no-store`.

A `301` is permanent: browsers cache it and later visits go straight to the
target without calling the API, so the hit counter would only see the first
visit from each browser. A `302` is temporary, so every visit goes through the
Lambda function and is counted. `no-store` makes the intent explicit for any
cache in between. The cost is one extra round trip on every visit, which is
the price of counting them.

## IAM: only what the function does

The execution role has one inline policy with three statements:

| Statement | Actions | Resource | Why |
| --- | --- | --- | --- |
| `LinksTable` | `dynamodb:PutItem`, `dynamodb:UpdateItem` | The table | The only two calls in the handler |
| `FunctionLogs` | `logs:CreateLogStream`, `logs:PutLogEvents` | Streams of the function's log group | The log group is created by Terraform, so `logs:CreateLogGroup` is not needed |
| `XRayTraces` | `xray:PutTraceSegments`, `xray:PutTelemetryRecords` | `*` | Required by active tracing; these actions support no narrower resource |

It replaced a policy that also allowed `dynamodb:GetItem` (unused) and the AWS
managed `AWSLambdaBasicExecutionRole` (logs on `*`, including
`CreateLogGroup`).

How it is checked:

- **Statically:** Checkov (no failed checks) and the action names and resource
  types against the AWS service authorization reference.
- **On the emulator:** the DynamoDB statement is enforced. The end-to-end tests
  fail if either action is removed.
- **Not checked:** the logs and X-Ray statements (the emulator neither delivers
  Lambda logs nor checks X-Ray permissions), and how AWS itself evaluates the
  policy.

## No throttling in Terraform (yet)

The API is public and unauthenticated, so it should have stage throttling
before any real deployment. The emulator stores throttling settings but does
not apply them: with a limit of 1 request per second, 30 parallel requests all
reached the function.

A setting that no test can exercise would only be checked by `terraform plan`,
whatever its values. It is left out until it can be validated on a real AWS
account; the test plan is in
[`emulator-findings.md`](emulator-findings.md#what-would-be-needed-on-real-aws).

## Terraform

- **Infrastructure as code** so that the CI can create and destroy the whole
  stack on every run, and so that a second `plan` can prove it is idempotent.
- **No endpoint in the provider block.** `AWS_ENDPOINT_URL`, `AWS_CA_BUNDLE` and
  the shared credentials and config files decide where the provider talks to.
  The emulator-specific values exist only in the environment and in an
  optional `emulator_dir` variable.
- **Local state.** Each CI environment lives for one run, so there is nothing to
  share or lock. A long-lived environment would need a remote backend (S3 with
  locking).

## AWS Emulator instead of mocks or a real account

| Approach | What it shows | Cost |
| --- | --- | --- |
| Mocks (the unit tests) | The handler logic, with DynamoDB replaced by a fake client | Fast, no infrastructure, but proves nothing about the deployed stack |
| AWS Emulator (the CI) | The same Terraform code and the same SDK calls work against AWS-compatible APIs: resources are created, the API routes to the function, the function writes to DynamoDB with its role | Free, no credentials in CI; fidelity depends on the emulator |
| Real AWS account | Everything, including IAM evaluation, logs, tracing and throttling | Costs money and requires cloud credentials in CI |

Both kinds of test are kept because they fail for different reasons. A unit
test pins down one behaviour precisely and runs in under a second. The
end-to-end tests catch problems the mocks cannot see: wrong IAM permissions,
API Gateway routing, Terraform wiring, or a difference between the fake client
and the real API.

What the emulator does not validate is listed in the README and in
[`emulator-findings.md`](emulator-findings.md).

## CI: two jobs

- **Job 1 (static checks)** runs in about 40 seconds without any infrastructure:
  JavaScript syntax, unit tests, Ruff, `terraform fmt` and `validate`, Checkov.
- **Job 2 (deploy and test)** starts the emulator, applies, checks idempotency,
  runs the end-to-end tests and destroys the stack. It `needs` job 1, so a
  formatting error or a failing unit test stops the run before any
  infrastructure is created.

How the pipeline handles failures:

- `terraform destroy` and the upload of the emulator log run with
  `if: always()`, so a failed test still cleans up and leaves a log to read.
- The idempotency step fails the job if a plan run right after apply is not
  empty (`-detailed-exitcode` exits with 2).
- `start-emulator.sh` fails if the emulator is not healthy within 60 seconds
  and prints its log, and warns if the installed version is not the tested one.
- `concurrency` with `cancel-in-progress` stops an older run on the same branch
  when a new commit is pushed.
- The workflow token is read-only (`permissions: contents: read`).

## Pinned versions

| What | Pinned to | Where |
| --- | --- | --- |
| Terraform | 1.17.2 | `TERRAFORM_VERSION` in `ci.yml` |
| Providers (aws, archive) | Exact versions and hashes | `infra/.terraform.lock.hcl` |
| GitHub Actions | Commit SHAs of release tags | `ci.yml` |
| Checkov | 3.4.5, through the pinned action | `ci.yml` |
| Ruff, pytest, requests, boto3 | Exact versions | `tests/requirements*.txt` |
| AWS SDK (unit tests) | `package-lock.json` | `app/` |

A CI run should only change when a commit changes something. Dependabot opens
weekly update PRs for actions, npm, pip and Terraform providers, and each one
goes through the full pipeline.

AWS Emulator is the exception: only the latest LTS build has a stable download
URL, so its version cannot be pinned at download time. The start script prints
the installed version, fails if it cannot read it, and warns if it differs
from the tested version (1.0.385).

## Before a real AWS deployment

1. Run the same Terraform code against a real account, with credentials from
   GitHub OIDC rather than long-lived keys.
2. Check that the role policy is sufficient: links are created and resolved,
   logs appear in the log group and traces in X-Ray.
3. Add stage throttling and test it with a burst of requests.
4. Move Terraform state to a remote backend.
5. Revisit the accepted Checkov findings in `.checkov.yaml` (access logging,
   WAF, KMS keys), several of which were accepted for a demo, not for
   production.
