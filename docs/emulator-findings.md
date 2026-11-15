# AWS Emulator findings

Behaviour observed while testing this project against AWS Emulator 1.0.385
(LTS), with the commands used so each result can be reproduced. Unless stated
otherwise, the stack was deployed with `make emulator` and `make deploy`, and
the commands were run with `.emulator.env` loaded
(`set -a; . ./.emulator.env; set +a`).

| Behaviour | Result |
| --- | --- |
| [IAM policies of the Lambda role](#iam-policies-of-the-lambda-role-are-enforced-for-dynamodb) | Enforced for DynamoDB calls |
| [Credentials used by the Lambda function](#the-function-runs-with-its-execution-role) | Its execution role, even with the emulator variables set |
| [Lambda logs](#lambda-logs-are-not-delivered-to-cloudwatch-logs) | Not delivered to CloudWatch Logs |
| [X-Ray permissions](#x-ray-traces-do-not-depend-on-the-role) | Not checked |
| [API Gateway throttling](#api-gateway-throttling-is-stored-but-not-enforced) | Stored, not enforced |
| [DynamoDB `on_demand_throughput`](#dynamodb-reports-on_demand_throughput---1) | Reported as `-1`, read as drift |

## IAM policies of the Lambda role are enforced for DynamoDB

Tested on 2026-11-15.

The role policy (`aws_iam_role_policy.lambda`) was replaced through the IAM
API with reduced versions, then the API was called:

| Role policy | `POST /links` | `GET /links/{code}` |
| --- | --- | --- |
| As defined in Terraform | 201 | 302 |
| Without `dynamodb:UpdateItem` | 201 | 500 |
| Without `dynamodb:PutItem` | 500 | 302 |
| Policy deleted | 500 | — |

With the policy deleted, the function log returned by `aws lambda invoke
--log-type Tail` shows the denial:

```text
User: arn:aws:sts::000000000000:assumed-role/url-shortener-lambda/url-shortener-api
is not authorized to perform: dynamodb:PutItem on resource:
arn:aws:dynamodb:us-east-1:000000000000:table/url-shortener-links because no
identity-based policy allows the dynamodb:PutItem action
```

An IAM user with no policy attached also gets `AccessDeniedException` on
`dynamodb:Scan` and `dynamodb:PutItem`.

The end-to-end tests were then run against each reduced policy:

| Role policy | End-to-end tests |
| --- | --- |
| Without `dynamodb:UpdateItem` | 2 failed (`test_redirect_and_hit_counter`, `test_unknown_code_returns_404`: resolving a code also uses `UpdateItem`) |
| Without `dynamodb:PutItem` | 3 failed (create, persistence, redirect) |
| As defined in Terraform | 6 passed |

**Consequence:** the pipeline does check that the policy is sufficient for the
DynamoDB calls. It does not show that AWS would evaluate the policy exactly the
same way.

## The function runs with its execution role

Tested on 2026-11-15.

`infra/main.tf` passes `AWS_ENDPOINT_URL`, `AWS_SHARED_CREDENTIALS_FILE`,
`AWS_CONFIG_FILE` and `NODE_EXTRA_CA_CERTS` to the function when
`emulator_dir` is set (`local.emulator_env`). The denial above was observed
with these variables set: the function still used its execution role
(`assumed-role/url-shortener-lambda`), not the emulator credentials file.

The stack was also deployed with `TF_VAR_emulator_dir=""`, so that the
function only had `TABLE_NAME` in its environment. Creating a link returned
201, the item was written to the emulator's DynamoDB table, and the six
end-to-end tests passed.

With this emulator version, `local.emulator_env` is not needed for the
function to reach DynamoDB. It is still in the Terraform code; removing it is
a separate change that has not been made yet.

## Lambda logs are not delivered to CloudWatch Logs

Tested on 2026-11-15.

After several invocations, `aws logs filter-log-events --log-group-name
/aws/lambda/url-shortener-api` returned no events, with the full role policy
in place. The function output is available from `aws lambda invoke --log-type
Tail`, but not in the log group. The `logs:CreateLogStream` and
`logs:PutLogEvents` permissions therefore cannot be checked on the emulator.

## X-Ray traces do not depend on the role

Tested on 2026-11-15.

Five requests were sent with the full role policy, then five without the
`XRayTraces` statement. `aws xray get-trace-summaries` counted five new traces
in both cases. The emulator records traces without checking
`xray:PutTraceSegments` on the role, so that permission is not tested.

## API Gateway throttling is stored but not enforced

Tested on 2026-11-15.

### What was tested

1. Stage-wide limit through the API Gateway API (equivalent to an
   `aws_api_gateway_method_settings` resource with `method_path = "*/*"`):

   ```bash
   aws apigateway update-stage --rest-api-id "$API_ID" --stage-name v1 \
     --patch-operations op=replace,path=/*/*/throttling/rateLimit,value=1 \
                        op=replace,path=/*/*/throttling/burstLimit,value=1
   ```

2. The same limit on one method (`/links/{code}` GET), after creating a new
   deployment of the stage. The `{code}` path segment needs the JSON form of
   `--patch-operations`:

   ```bash
   aws apigateway update-stage --rest-api-id "$API_ID" --stage-name v1 \
     --patch-operations '[{"op":"replace","path":"/~1links~1{code}/GET/throttling/rateLimit","value":"1"},
                          {"op":"replace","path":"/~1links~1{code}/GET/throttling/burstLimit","value":"1"}]'
   ```

3. After each change, 30 requests to `GET /v1/links/<unknown code>`, first one
   after the other, then 30 in parallel:

   ```bash
   seq 30 | xargs -P30 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
     --cacert "$AWS_CA_BUNDLE" -H "Host: $API_ID.execute-api.us-east-1.amazonaws.com" \
     "$AWS_ENDPOINT_URL/v1/links/nope" | sort | uniq -c
   ```

### Result

- `get-stage` returns both settings (`*/*` and `~1links~1{code}/GET`) with
  `throttlingRateLimit: 1.0` and `throttlingBurstLimit: 1`.
- Every request reached the Lambda function: 30 × `404` in each run, no
  `429 Too Many Requests`. The emulator log has no throttling entry.

The emulator accepts and stores the configuration but does not apply it.

### Decision

No throttling configuration was added to the Terraform code. A setting that
the test environment ignores would only be checked by `terraform plan`, not
by any test, and the pipeline would pass whether the values are sensible or
not.

### What would be needed on real AWS

The API is public and unauthenticated, so stage throttling should be added
before a real deployment. Without it, only the account-level default applies
(10,000 requests per second, burst 5,000, shared by all APIs in the region).

To validate it on a real AWS account:

1. Add an `aws_api_gateway_method_settings` resource for the stage
   (`method_path = "*/*"`) with `throttling_rate_limit` and
   `throttling_burst_limit` set from the expected traffic.
2. Deploy, then send a burst larger than the burst limit and check that the
   excess requests get `429` responses, which never reach the Lambda function
   (its invocation count in CloudWatch stays below the number of requests).
3. Check that the `4XXError` metric of the stage counts the throttled
   requests.

## DynamoDB reports `on_demand_throughput = -1`

Observed on 2026-11-14 with the same emulator version.

Right after `terraform apply`, `terraform plan -detailed-exitcode` exited with
code 2: the emulator returns `on_demand_throughput` with
`max_read_request_units` and `max_write_request_units` set to `-1` ("no limit")
for a `PAY_PER_REQUEST` table, and the AWS provider plans to remove them on
every run. The IAM policy also showed as changing, only because its policy
document depends on the table.

The table now has `lifecycle { ignore_changes = [on_demand_throughput] }`,
which ignores that block only, so the idempotency check stays strict for every
other attribute.
