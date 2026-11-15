// URL shortener Lambda (API Gateway REST proxy integration).
//   POST /links          {"url": "https://..."}  -> 201 {"code": "...", "url": "..."}
//   GET  /links/{code}                           -> 301 redirect (+ hit counter)
//
// The AWS SDK v3 ships with the nodejs22.x runtime, so nothing is bundled.
import {
  DynamoDBClient,
  PutItemCommand,
  UpdateItemCommand,
} from "@aws-sdk/client-dynamodb";
import { randomBytes } from "node:crypto";

const ALPHABET =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

export function generateCode(length = 7) {
  return [...randomBytes(length)]
    .map((b) => ALPHABET[b % ALPHABET.length])
    .join("");
}

export function isValidUrl(value) {
  if (typeof value !== "string" || value.length > 2048) return false;
  try {
    const u = new URL(value);
    return u.protocol === "http:" || u.protocol === "https:";
  } catch {
    return false;
  }
}

const response = (statusCode, body, headers = {}) => ({
  statusCode,
  headers: { "Content-Type": "application/json", ...headers },
  body: JSON.stringify(body),
});

function parseBody(event) {
  if (!event.body) return {};
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body, "base64").toString("utf8")
    : event.body;
  return JSON.parse(raw);
}

export function createHandler({ client, tableName }) {
  async function createLink(event) {
    let payload;
    try {
      payload = parseBody(event);
    } catch {
      return response(400, { error: "body must be valid JSON" });
    }
    // JSON.parse also accepts null, strings, numbers and arrays.
    if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
      return response(400, { error: "body must be a JSON object" });
    }
    if (!isValidUrl(payload.url)) {
      return response(400, { error: "field 'url' must be an http(s) URL" });
    }

    // Retry on the (very unlikely) event of a code collision.
    for (let attempt = 0; attempt < 3; attempt++) {
      const code = generateCode();
      try {
        await client.send(
          new PutItemCommand({
            TableName: tableName,
            Item: {
              code: { S: code },
              url: { S: payload.url },
              hits: { N: "0" },
              createdAt: { S: new Date().toISOString() },
            },
            ConditionExpression: "attribute_not_exists(code)",
          }),
        );
        return response(201, { code, url: payload.url });
      } catch (err) {
        if (err.name !== "ConditionalCheckFailedException") throw err;
      }
    }
    return response(500, { error: "could not allocate a unique code" });
  }

  async function resolveLink(code) {
    try {
      const out = await client.send(
        new UpdateItemCommand({
          TableName: tableName,
          Key: { code: { S: code } },
          UpdateExpression: "ADD hits :one",
          ConditionExpression: "attribute_exists(code)",
          ExpressionAttributeValues: { ":one": { N: "1" } },
          ReturnValues: "ALL_NEW",
        }),
      );
      const url = out.Attributes.url.S;
      const hits = Number(out.Attributes.hits.N);
      return response(301, { code, url, hits }, { Location: url });
    } catch (err) {
      if (err.name === "ConditionalCheckFailedException") {
        return response(404, { error: `unknown code '${code}'` });
      }
      throw err;
    }
  }

  return async (event) => {
    try {
      const method = event.httpMethod;
      const code = event.pathParameters?.code;

      if (method === "POST" && !code) return await createLink(event);
      if (method === "GET" && code) return await resolveLink(code);
      return response(404, { error: "route not found" });
    } catch (err) {
      console.error(JSON.stringify({ level: "error", message: err.message, name: err.name }));
      return response(500, { error: "internal error" });
    }
  };
}

export const handler = createHandler({
  client: new DynamoDBClient({}),
  tableName: process.env.TABLE_NAME,
});
