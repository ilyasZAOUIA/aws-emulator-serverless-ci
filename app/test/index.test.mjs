// Unit tests: no AWS, no emulator — the DynamoDB client is replaced by a fake.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler, generateCode, isValidUrl } from "../src/index.mjs";

function fakeClient(impl) {
  const calls = [];
  return {
    calls,
    send: async (command) => {
      calls.push(command);
      return impl(command);
    },
  };
}

const conditionalFailure = () => {
  const err = new Error("conditional check failed");
  err.name = "ConditionalCheckFailedException";
  throw err;
};

test("generateCode returns 7 alphanumeric chars", () => {
  const code = generateCode();
  assert.match(code, /^[A-Za-z0-9]{7}$/);
});

test("isValidUrl accepts http(s) only", () => {
  assert.equal(isValidUrl("https://example.com"), true);
  assert.equal(isValidUrl("http://example.com/a?b=c"), true);
  assert.equal(isValidUrl("ftp://example.com"), false);
  assert.equal(isValidUrl("not a url"), false);
  assert.equal(isValidUrl(42), false);
});

test("POST /links stores the link and returns 201", async () => {
  const client = fakeClient(() => ({}));
  const handler = createHandler({ client, tableName: "links" });

  const res = await handler({
    httpMethod: "POST",
    body: JSON.stringify({ url: "https://example.com" }),
  });

  assert.equal(res.statusCode, 201);
  const body = JSON.parse(res.body);
  assert.equal(body.url, "https://example.com");
  assert.match(body.code, /^[A-Za-z0-9]{7}$/);
  assert.equal(client.calls[0].input.TableName, "links");
});

test("POST /links rejects an invalid URL with 400", async () => {
  const client = fakeClient(() => ({}));
  const handler = createHandler({ client, tableName: "links" });

  const res = await handler({ httpMethod: "POST", body: '{"url":"nope"}' });

  assert.equal(res.statusCode, 400);
  assert.equal(client.calls.length, 0);
});

test("POST /links rejects malformed JSON with 400", async () => {
  const handler = createHandler({ client: fakeClient(() => ({})), tableName: "t" });
  const res = await handler({ httpMethod: "POST", body: "{" });
  assert.equal(res.statusCode, 400);
});

test("POST /links decodes base64 bodies", async () => {
  const handler = createHandler({ client: fakeClient(() => ({})), tableName: "t" });
  const res = await handler({
    httpMethod: "POST",
    isBase64Encoded: true,
    body: Buffer.from('{"url":"https://example.com"}').toString("base64"),
  });
  assert.equal(res.statusCode, 201);
});

test("POST /links retries on code collision", async () => {
  let n = 0;
  const client = fakeClient(() => (n++ === 0 ? conditionalFailure() : {}));
  const handler = createHandler({ client, tableName: "t" });

  const res = await handler({ httpMethod: "POST", body: '{"url":"https://a.io"}' });

  assert.equal(res.statusCode, 201);
  assert.equal(client.calls.length, 2);
});

test("GET /links/{code} redirects with 301 and returns hits", async () => {
  const client = fakeClient(() => ({
    Attributes: { url: { S: "https://example.com" }, hits: { N: "3" } },
  }));
  const handler = createHandler({ client, tableName: "t" });

  const res = await handler({ httpMethod: "GET", pathParameters: { code: "abc1234" } });

  assert.equal(res.statusCode, 301);
  assert.equal(res.headers.Location, "https://example.com");
  assert.equal(JSON.parse(res.body).hits, 3);
});

test("GET /links/{code} returns 404 for an unknown code", async () => {
  const handler = createHandler({ client: fakeClient(conditionalFailure), tableName: "t" });
  const res = await handler({ httpMethod: "GET", pathParameters: { code: "zzzzzzz" } });
  assert.equal(res.statusCode, 404);
});

test("unexpected errors become a 500 without leaking details", async () => {
  const handler = createHandler({
    client: fakeClient(() => {
      throw new Error("boom");
    }),
    tableName: "t",
  });
  const res = await handler({ httpMethod: "GET", pathParameters: { code: "abc" } });
  assert.equal(res.statusCode, 500);
  assert.deepEqual(JSON.parse(res.body), { error: "internal error" });
});

test("unknown routes return 404", async () => {
  const handler = createHandler({ client: fakeClient(() => ({})), tableName: "t" });
  const res = await handler({ httpMethod: "DELETE" });
  assert.equal(res.statusCode, 404);
});
