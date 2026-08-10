/**
 * Tests for the contact form submission module.
 *
 *   node --test
 *
 * No dependencies and no test framework: `node --test` is built into
 * Node 18+, so this repo has no node_modules. crypto.subtle exists in
 * both Node and the browser, which means sha256Hex is exercised here as
 * the very same function that runs for a visitor.
 */

import assert from "node:assert/strict";
import { test, describe } from "node:test";

import { sha256Hex, buildPayload, buildBody, submit } from "./contact-form.js";

/**
 * A real FormData with the form's fields set.
 *
 * No stubbing anywhere in this file: buildPayload and submit take a
 * FormData rather than a <form>, and Node's FormData constructs happily
 * without a DOM. These tests therefore run the same code a browser does.
 */
function formDataFor(values = {}) {
  const fields = {
    name: "Ada Lovelace",
    email: "ada@example.com",
    topic: "collaboration",
    message: "Would you like to work together?",
    website: "",
    ...values,
  };
  const data = new FormData();
  for (const [key, value] of Object.entries(fields)) data.set(key, value);
  return data;
}

describe("sha256Hex", () => {
  test("matches the published SHA-256 test vector for 'abc'", async () => {
    // A known-answer test, not a self-consistent one: this value comes
    // from FIPS 180-4, so it would catch an implementation that is
    // internally consistent but wrong.
    const bytes = new TextEncoder().encode("abc");
    assert.equal(
      await sha256Hex(bytes),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });

  test("matches the published vector for the empty input", async () => {
    assert.equal(
      await sha256Hex(new Uint8Array()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
  });

  test("returns 64 lowercase hex characters", async () => {
    const hex = await sha256Hex(new TextEncoder().encode("anything"));
    assert.match(hex, /^[0-9a-f]{64}$/);
  });

  test("pads bytes that render as a single hex digit", async () => {
    // A naive toString(16) drops the leading zero on bytes below 0x10,
    // producing a short hash that AWS rejects with a signature error
    // giving no hint that the encoding is at fault.
    const hex = await sha256Hex(new TextEncoder().encode("hello world"));
    assert.equal(hex.length, 64);
  });
});

describe("buildPayload", () => {
  test("collects every field the handler validates", () => {
    const payload = buildPayload(formDataFor());
    assert.deepEqual(Object.keys(payload).sort(), [
      "email",
      "message",
      "name",
      "topic",
      "website",
    ]);
  });

  test("keeps the honeypot field rather than stripping it", () => {
    // Dropping `website` here would disable the honeypot entirely: the
    // server can only recognise a bot if the field arrives filled in.
    const payload = buildPayload(formDataFor({ website: "spam.example" }));
    assert.equal(payload.website, "spam.example");
  });

  test("defaults topic to general when absent", () => {
    const payload = buildPayload(formDataFor({ topic: "" }));
    assert.equal(payload.topic, "general");
  });
});

describe("buildBody", () => {
  test("encodes to bytes, not a string", () => {
    assert.ok(buildBody({ a: 1 }) instanceof Uint8Array);
  });

  test("byte length reflects encoded unicode, not string length", () => {
    // 'é' is one JS character but two UTF-8 bytes. Hashing string length
    // rather than encoded bytes would desynchronise the hash from the
    // body for any non-ASCII message.
    const bytes = buildBody({ m: "é" });
    const asString = JSON.stringify({ m: "é" });
    assert.ok(bytes.length > asString.length);
  });
});

describe("submit", () => {
  test("sends exactly the bytes that were hashed", async () => {
    // The regression this guards is invisible from the outside:
    // re-serialising the payload for the request body means the hash
    // describes one byte string while another is transmitted, and the
    // only symptom is an opaque signature mismatch from Lambda.
    let captured;
    const fetchStub = async (_url, init) => {
      captured = init;
      return { ok: true, json: async () => ({ message: "ok" }) };
    };

    await submit(formDataFor(), fetchStub);

    const sentHash = captured.headers["x-amz-content-sha256"];
    const hashOfSentBody = await sha256Hex(captured.body);
    assert.equal(sentHash, hashOfSentBody);
  });

  test("declares the payload hash header at all", async () => {
    let captured;
    const fetchStub = async (_url, init) => {
      captured = init;
      return { ok: true, json: async () => ({}) };
    };
    await submit(formDataFor(), fetchStub);
    assert.ok(
      captured.headers["x-amz-content-sha256"],
      "CloudFront signs this header's value; without it every POST fails signature validation",
    );
  });

  test("posts JSON to the same-origin endpoint", async () => {
    let url, init;
    const fetchStub = async (u, i) => {
      url = u;
      init = i;
      return { ok: true, json: async () => ({}) };
    };
    await submit(formDataFor(), fetchStub);
    // Relative, not absolute: an absolute AWS URL would reintroduce CORS
    // and put the function hostname back into page source.
    assert.equal(url, "/api/contact");
    assert.equal(init.method, "POST");
    assert.equal(init.headers["content-type"], "application/json");
  });

  test("surfaces a non-JSON error body as a failure rather than throwing", async () => {
    // A signature rejection returns XML from Lambda, not JSON.
    const fetchStub = async () => ({
      ok: false,
      status: 403,
      json: async () => {
        throw new SyntaxError("Unexpected token <");
      },
    });
    const result = await submit(formDataFor(), fetchStub);
    assert.equal(result.ok, false);
    assert.equal(result.status, 403);
    assert.deepEqual(result.payload, {});
  });
});
