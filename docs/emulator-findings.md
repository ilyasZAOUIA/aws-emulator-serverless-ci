# AWS Emulator findings

Behaviour observed while testing this project against AWS Emulator, with the
commands used, so each result can be reproduced.

## API Gateway throttling is stored but not enforced

Tested on 2026-11-15 with AWS Emulator 1.0.385 (LTS), with the stack from
this repository deployed by `make deploy`.

### What was tested

1. Stage-wide limit through the API Gateway API (equivalent to an
   `aws_api_gateway_method_settings` resource with `method_path = "*/*"`):

   ```bash
   aws apigateway update-stage --rest-api-id "$API_ID" --stage-name v1 \
     --patch-operations op=replace,path=/*/*/throttling/rateLimit,value=1 \
                        op=replace,path=/*/*/throttling/burstLimit,value=1
   ```

2. The same limit on one method (`/links/{code}` GET), after creating a new
   deployment of the stage.

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
