import assert from "node:assert/strict";
import test from "node:test";

import worker from "./index.ts";

const CLIENT_TOKEN = "unit-test-client-token";
const UNSET_CLIENT_TOKEN = Symbol("unset-client-token");
const PROVIDER_ROUTES = [
  { path: "/tts", body: { text: "hello" } },
  { path: "/v1/tts/stream", body: { text: "hello" } },
  { path: "/v1/stt/session-token", body: {} },
];

function makeEnv(clientToken = CLIENT_TOKEN) {
  const env = {
    ELEVENLABS_API_KEY: "unit-test-elevenlabs-key",
    ELEVENLABS_VOICE_ID: "UnitTestVoice1",
  };
  if (clientToken !== UNSET_CLIENT_TOKEN) {
    env.HEYMATE_CLIENT_TOKEN = clientToken;
  }
  return env;
}

function makeRequest(path, { method = "POST", authorization, body } = {}) {
  const headers = new Headers();
  if (authorization !== undefined) {
    headers.set("authorization", authorization);
  }
  if (body !== undefined) {
    headers.set("content-type", "application/json");
  }

  return new Request(`https://worker.test${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function withMockedProviderFetch(run, providerFailure) {
  const originalFetch = globalThis.fetch;
  const calls = [];

  globalThis.fetch = async (input, init = {}) => {
    const url = input instanceof Request ? input.url : String(input);
    calls.push({ url, init });

    if (providerFailure) {
      return new Response(providerFailure.body, {
        status: providerFailure.status,
        headers: { "content-type": "application/json" },
      });
    }

    if (url === "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe") {
      return new Response('{"token":"unit-test-single-use-token"}', {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    if (url.startsWith("https://api.elevenlabs.io/")) {
      return new Response(new Uint8Array([1, 2, 3]), {
        status: 200,
        headers: { "content-type": "audio/mpeg" },
      });
    }
    throw new Error(`Unexpected provider URL: ${url}`);
  };

  try {
    await run(calls);
  } finally {
    globalThis.fetch = originalFetch;
  }
}

async function assertProviderRoutesUnauthorized(env, authorization) {
  await withMockedProviderFetch(async (calls) => {
    for (const route of PROVIDER_ROUTES) {
      const response = await worker.fetch(
        makeRequest(route.path, { authorization, body: route.body }),
        env
      );
      assert.equal(response.status, 401, route.path);
      assert.deepEqual(await response.json(), { error: "unauthorized" }, route.path);
    }
    assert.equal(calls.length, 0, "authorization failure must stop before provider fetch");
  });
}

test("provider routes fail closed when the client token is unset", async () => {
  await assertProviderRoutesUnauthorized(
    makeEnv(UNSET_CLIENT_TOKEN),
    `Bearer ${CLIENT_TOKEN}`
  );
});

test("provider routes reject a wrong Bearer token", async () => {
  await assertProviderRoutesUnauthorized(
    makeEnv(),
    "Bearer wrong-unit-test-token"
  );
});

test("provider routes reject missing and malformed authorization", async () => {
  const malformedHeaders = [
    undefined,
    "Bearer",
    "Bearer ",
    `Bearer  ${CLIENT_TOKEN}`,
    `bearer ${CLIENT_TOKEN}`,
    `Basic ${CLIENT_TOKEN}`,
    CLIENT_TOKEN,
  ];

  for (const authorization of malformedHeaders) {
    await assertProviderRoutesUnauthorized(makeEnv(), authorization);
  }
});

test("correct Bearer token reaches every legacy and versioned provider route", async () => {
  await withMockedProviderFetch(async (calls) => {
    for (const route of PROVIDER_ROUTES) {
      const response = await worker.fetch(
        makeRequest(route.path, {
          authorization: `Bearer ${CLIENT_TOKEN}`,
          body: route.body,
        }),
        makeEnv()
      );
      assert.equal(response.status, 200, route.path);
    }

    assert.equal(calls.length, PROVIDER_ROUTES.length);
    assert.equal(
      calls.filter(({ url }) => url.startsWith("https://api.elevenlabs.io/v1/text-to-speech/")).length,
      2
    );
    assert.equal(
      calls.filter(({ url }) => url === "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe").length,
      1
    );
  });
});

test("provider failure logs omit upstream response text", async () => {
  const privateResponseBody = "upstream body contains customer payroll row 17";
  const status = 429;
  const responseBytes = new TextEncoder().encode(privateResponseBody).byteLength;
  const originalConsoleError = console.error;
  const logs = [];
  console.error = (...arguments_) => {
    logs.push(arguments_.map(String).join(" "));
  };

  try {
    await withMockedProviderFetch(
      async (calls) => {
        for (const route of PROVIDER_ROUTES) {
          const response = await worker.fetch(
            makeRequest(route.path, {
              authorization: `Bearer ${CLIENT_TOKEN}`,
              body: route.body,
            }),
            makeEnv()
          );
          assert.equal(response.status, status, route.path);
          assert.equal(await response.text(), privateResponseBody, route.path);
        }
        assert.equal(calls.length, PROVIDER_ROUTES.length);
      },
      { status, body: privateResponseBody }
    );
  } finally {
    console.error = originalConsoleError;
  }

  const renderedLogs = logs.join("\n");
  assert.equal(logs.length, PROVIDER_ROUTES.length);
  assert.doesNotMatch(renderedLogs, new RegExp(privateResponseBody));
  for (const route of PROVIDER_ROUTES) {
    assert.match(
      renderedLogs,
      new RegExp(
        `\\[${route.path.replaceAll("/", "\\/")}\\] Provider error status=${status} response_bytes=${responseBytes}`
      ),
      route.path
    );
  }
});

test("Scribe session token comes from ElevenLabs with the server key", async () => {
  await withMockedProviderFetch(async (calls) => {
    const response = await worker.fetch(
      makeRequest("/v1/stt/session-token", {
        authorization: `Bearer ${CLIENT_TOKEN}`,
        body: {},
      }),
      makeEnv()
    );
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { token: "unit-test-single-use-token" });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].init.method, "POST");
    assert.equal(calls[0].init.headers["xi-api-key"], "unit-test-elevenlabs-key");
  });
});

test("retired AssemblyAI legacy token route is gone", async () => {
  await withMockedProviderFetch(async (calls) => {
    const response = await worker.fetch(
      makeRequest("/transcribe-token", {
        authorization: `Bearer ${CLIENT_TOKEN}`,
        body: {},
      }),
      makeEnv()
    );
    assert.equal(response.status, 404);
    assert.equal(calls.length, 0);
  });
});

test("authorized account routes return locally without provider fetch", async () => {
  await withMockedProviderFetch(async (calls) => {
    for (const path of ["/v1/me", "/v1/usage"]) {
      const response = await worker.fetch(
        makeRequest(path, {
          method: "GET",
          authorization: `Bearer ${CLIENT_TOKEN}`,
        }),
        makeEnv()
      );
      assert.equal(response.status, 200, path);
    }
    assert.equal(calls.length, 0);
  });
});

test("versioned OPTIONS preflight stays open and never reaches a provider", async () => {
  await withMockedProviderFetch(async (calls) => {
    for (const path of ["/v1/tts/stream", "/v1/future-route"]) {
      const response = await worker.fetch(
        makeRequest(path, { method: "OPTIONS" }),
        makeEnv(UNSET_CLIENT_TOKEN)
      );
      assert.equal(response.status, 204, path);
      assert.equal(response.headers.get("access-control-allow-origin"), "*", path);
      assert.match(
        response.headers.get("access-control-allow-headers") ?? "",
        /Authorization/,
        path
      );
    }

    const legacyResponse = await worker.fetch(
      makeRequest("/chat", { method: "OPTIONS" }),
      makeEnv(UNSET_CLIENT_TOKEN)
    );
    assert.equal(legacyResponse.status, 405);
    assert.equal(calls.length, 0);
  });
});

test("unknown routes preserve their authenticated boundary", async () => {
  await withMockedProviderFetch(async (calls) => {
    for (const authorization of [undefined, `Bearer ${CLIENT_TOKEN}`]) {
      const legacyUnknown = await worker.fetch(
        makeRequest("/unknown", { authorization, body: {} }),
        makeEnv(UNSET_CLIENT_TOKEN)
      );
      assert.equal(legacyUnknown.status, 404);
    }

    const unauthorizedCases = [
      {
        label: "unset server token",
        env: makeEnv(UNSET_CLIENT_TOKEN),
        authorization: `Bearer ${CLIENT_TOKEN}`,
      },
      { label: "missing header", env: makeEnv(), authorization: undefined },
      {
        label: "wrong token",
        env: makeEnv(),
        authorization: "Bearer wrong-unit-test-token",
      },
      {
        label: "malformed scheme",
        env: makeEnv(),
        authorization: `Basic ${CLIENT_TOKEN}`,
      },
    ];
    for (const { label, env, authorization } of unauthorizedCases) {
      const response = await worker.fetch(
        makeRequest("/v1/future-route", { method: "GET", authorization }),
        env
      );
      assert.equal(response.status, 401, label);
    }

    const authorizedVersioned = await worker.fetch(
      makeRequest("/v1/future-route", {
        method: "GET",
        authorization: `Bearer ${CLIENT_TOKEN}`,
      }),
      makeEnv()
    );
    assert.equal(authorizedVersioned.status, 501);
    assert.deepEqual(await authorizedVersioned.json(), {
      error: "not_implemented",
      endpoint: "GET /v1/future-route",
    });
    assert.equal(calls.length, 0);
  });
});
