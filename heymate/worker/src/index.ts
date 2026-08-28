/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude, ElevenLabs, and AssemblyAI APIs so the app never
 * ships with raw API keys. Keys are stored as Cloudflare secrets.
 *
 * Legacy routes (behavior unchanged, no auth):
 *   POST /chat             → Anthropic Messages API (streaming)
 *   POST /tts              → ElevenLabs TTS API
 *   POST /transcribe-token → AssemblyAI realtime websocket token
 *
 * Versioned routes (Bearer-gated when HEYMATE_CLIENT_TOKEN is set):
 *   POST /v1/chat/stream        → Anthropic Messages API (streaming)
 *   POST /v1/tts/stream         → ElevenLabs TTS API
 *   POST /v1/stt/session-token  → AssemblyAI realtime websocket token
 *   GET  /v1/me                 → placeholder account info
 *   GET  /v1/usage              → placeholder usage counters
 *   anything else under /v1/*   → 501 not_implemented
 */

interface Env {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;

  /**
   * WHY: optional shared client token for the /v1/* surface. It is deliberately
   * NOT a provider secret — the real API keys stay server-side behind this
   * proxy. Its only job right now is abuse damping (something cheap to demand
   * from callers and rotate) until real accounts exist. Unset → /v1 is open,
   * so local dev stays frictionless.
   */
  HEYMATE_CLIENT_TOKEN?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Querystrings never participate in routing — pathname alone decides.
    const path = url.pathname;

    const isVersionedPath = path === "/v1" || path.startsWith("/v1/");
    if (isVersionedPath) {
      try {
        return await handleVersionedRequest(request, env, path);
      } catch (error) {
        return internalError(path, error);
      }
    }

    // Everything outside /v1 keeps the original worker surface exactly:
    // non-POST anywhere answered plain-text 405, known POST paths proxied,
    // everything else plain-text 404.
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (path === "/chat") {
        return await handleChat(request, env);
      }

      if (path === "/tts") {
        return await handleTTS(request, env);
      }

      if (path === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      return internalError(path, error);
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleVersionedRequest(
  request: Request,
  env: Env,
  path: string
): Promise<Response> {
  // Browsers send preflight requests without credentials, so OPTIONS must be
  // answered before the auth check or browser-based clients could never pass.
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, POST, OPTIONS",
        "access-control-allow-headers": "Authorization, Content-Type",
        "access-control-max-age": "86400",
      },
    });
  }

  if (!bearerOk(request, env)) {
    return json({ error: "unauthorized" }, 401);
  }

  const method = request.method;

  if (method === "POST" && path === "/v1/chat/stream") {
    return await handleChat(request, env);
  }

  if (method === "POST" && path === "/v1/tts/stream") {
    return await handleTTS(request, env);
  }

  if (method === "POST" && path === "/v1/stt/session-token") {
    return await handleTranscribeToken(env);
  }

  if (method === "GET" && path === "/v1/me") {
    return json({
      id: "local",
      plan: "unmanaged",
      features: { agents: false, integrations: false },
    });
  }

  if (method === "GET" && path === "/v1/usage") {
    return json({
      talkMessages: null,
      dictationCharacters: null,
      agentRuns: null,
    });
  }

  // WHY 501 instead of 404: all of /v1 is a planned contract, so a missing
  // endpoint here means "known name, not built yet" rather than "wrong
  // address". Clients can feature-detect — 501 says the capability may arrive,
  // while 404 stays reserved for genuinely bad URLs.
  return json({ error: "not_implemented", endpoint: `${method} ${path}` }, 501);
}

function json(data: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": "*",
    },
  });
}

function bearerOk(request: Request, env: Env): boolean {
  // WHY: this checks the shared CLIENT token, never a provider secret — even a
  // full leak of it exposes no Anthropic/ElevenLabs/AssemblyAI keys. Plain
  // equality is intentional: the threat model is drive-by abuse damping, not a
  // determined attacker; real accounts will replace this gate later.
  if (!env.HEYMATE_CLIENT_TOKEN) {
    return true;
  }

  const authorizationHeader = request.headers.get("authorization");
  return authorizationHeader === `Bearer ${env.HEYMATE_CLIENT_TOKEN}`;
}

function internalError(path: string, error: unknown): Response {
  console.error(`[${path}] Unhandled error:`, error);
  return new Response(JSON.stringify({ error: String(error) }), {
    status: 500,
    headers: { "content-type": "application/json" },
  });
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] Anthropic API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

/**
 * WHY the strict pattern: the voice id is interpolated into the upstream URL
 * path. Anything containing a slash, a dot, or a query character would let a
 * caller steer the request at a different ElevenLabs endpoint, so a caller
 * supplied id is only honored when it is plain alphanumerics.
 */
const ELEVENLABS_VOICE_ID_PATTERN = /^[A-Za-z0-9]{1,64}$/;

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const rawBody = await request.text();

  // The client may name a voice; the configured var stays the fallback so an
  // older build that sends no voice_id keeps working unchanged.
  let voiceId = env.ELEVENLABS_VOICE_ID;
  let body = rawBody;

  try {
    const parsedBody = JSON.parse(rawBody);
    if (parsedBody && typeof parsedBody === "object" && "voice_id" in parsedBody) {
      const requestedVoiceId = parsedBody.voice_id;
      if (typeof requestedVoiceId === "string" && ELEVENLABS_VOICE_ID_PATTERN.test(requestedVoiceId)) {
        voiceId = requestedVoiceId;
      }
      // Never forwarded upstream — voice selection is a path parameter there.
      delete parsedBody.voice_id;
      body = JSON.stringify(parsedBody);
    }
  } catch {
    // Not JSON we can read. Forward it untouched and use the configured voice,
    // which is exactly the pre-existing behavior.
  }

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
