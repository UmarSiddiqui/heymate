/**
 * HeyMate proxy worker (Cloudflare).
 *
 * Holds the ElevenLabs key as a Cloudflare secret so the app never ships
 * one. Every route that reaches a provider demands the shared client token
 * as `Authorization: Bearer <token>`.
 *
 *   POST /v1/tts/stream         ElevenLabs text to speech (streamed audio)
 *   POST /v1/stt/session-token  single-use token for the Scribe realtime socket
 *   GET  /v1/me                 placeholder account
 *   GET  /v1/usage              placeholder usage counters
 *   any other /v1 route         501, a planned name that isn't built yet
 *   POST /tts                   older app builds; same as /v1/tts/stream
 */

interface Env {
  ELEVENLABS_API_KEY: string;
  /** Used when the request names no voice, or an invalid one. */
  ELEVENLABS_VOICE_ID: string;
  /**
   * A shared client token, not a provider secret: leaking it exposes no
   * provider key. It damps drive-by abuse until real accounts exist, and
   * every provider route fails closed while it is unset.
   */
  HEYMATE_CLIENT_TOKEN?: string;
}

type Handler = (request: Request, env: Env, path: string) => Promise<Response> | Response;

const ELEVENLABS = "https://api.elevenlabs.io/v1";

/**
 * A voice id goes into the upstream URL path, so anything beyond plain
 * alphanumerics (a slash, a dot, a query) could steer the call at another
 * ElevenLabs endpoint. Such ids are ignored in favour of the configured one.
 */
const VOICE_ID = /^[A-Za-z0-9]{1,64}$/;

const CORS_PREFLIGHT_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "Authorization, Content-Type",
  "access-control-max-age": "86400",
};

/** Routes under /v1, keyed by "METHOD /path". All of them need the token. */
const VERSIONED_ROUTES: Record<string, Handler> = {
  "POST /v1/tts/stream": textToSpeech,
  "POST /v1/stt/session-token": (_request, env, path) => scribeSessionToken(env, path),
  "GET /v1/me": () => json({ id: "local", plan: "unmanaged", features: { agents: false, integrations: false } }),
  "GET /v1/usage": () => json({ talkMessages: null, dictationCharacters: null, agentRuns: null }),
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Only the path routes; a query string never changes where a request goes.
    const path = new URL(request.url).pathname;
    try {
      if (path === "/v1" || path.startsWith("/v1/")) {
        return await routeVersioned(request, env, path);
      }
      return await routeLegacy(request, env, path);
    } catch (error) {
      console.error(`[${path}] Unhandled error:`, error);
      return json({ error: "internal_error" }, 500);
    }
  },
};

async function routeVersioned(request: Request, env: Env, path: string): Promise<Response> {
  // Browsers send preflights without credentials, so they are answered
  // before the token check or no browser client could ever get through.
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_PREFLIGHT_HEADERS });
  }
  if (!hasClientToken(request, env)) {
    return json({ error: "unauthorized" }, 401);
  }
  const endpoint = `${request.method} ${path}`;
  const handler = VERSIONED_ROUTES[endpoint];
  if (handler) {
    return await handler(request, env, path);
  }
  // 501 rather than 404: /v1 is a planned contract, so an unknown endpoint
  // there is a capability that may arrive, and clients can feature-detect
  // it. 404 stays for addresses that are simply wrong.
  return json({ error: "not_implemented", endpoint }, 501);
}

/** The unversioned surface older app builds use. Its responses keep their old shapes. */
async function routeLegacy(request: Request, env: Env, path: string): Promise<Response> {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (path !== "/tts") {
    return new Response("Not found", { status: 404 });
  }
  if (!hasClientToken(request, env)) {
    return json({ error: "unauthorized" }, 401);
  }
  return await textToSpeech(request, env, path);
}

/**
 * Plain string comparison is deliberate: the token only damps casual abuse
 * and guards no provider key, so timing attacks are outside its job.
 */
function hasClientToken(request: Request, env: Env): boolean {
  const token = env.HEYMATE_CLIENT_TOKEN;
  return Boolean(token) && request.headers.get("authorization") === `Bearer ${token}`;
}

async function textToSpeech(request: Request, env: Env, path: string): Promise<Response> {
  const { voiceId, body } = takeVoiceId(await request.text(), env.ELEVENLABS_VOICE_ID);
  const upstream = await fetch(`${ELEVENLABS}/text-to-speech/${voiceId}`, {
    method: "POST",
    headers: {
      "xi-api-key": env.ELEVENLABS_API_KEY,
      "content-type": "application/json",
      accept: "audio/mpeg",
    },
    body,
  });
  if (!upstream.ok) {
    return await relayProviderFailure(upstream, path);
  }
  // Streamed through as it arrives, so playback starts on the first bytes.
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") || "audio/mpeg" },
  });
}

/**
 * Splits an optional `voice_id` out of a text-to-speech body. ElevenLabs
 * takes the voice in the URL, so the field is never forwarded. A body that
 * isn't a JSON object passes through untouched with the default voice, as
 * older app builds expect.
 */
function takeVoiceId(rawBody: string, defaultVoiceId: string): { voiceId: string; body: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return { voiceId: defaultVoiceId, body: rawBody };
  }
  if (!parsed || typeof parsed !== "object" || !("voice_id" in parsed)) {
    return { voiceId: defaultVoiceId, body: rawBody };
  }
  const { voice_id: requested, ...rest } = parsed as Record<string, unknown>;
  const voiceId = typeof requested === "string" && VOICE_ID.test(requested) ? requested : defaultVoiceId;
  return { voiceId, body: JSON.stringify(rest) };
}

/**
 * The app opens the Scribe realtime socket itself, so it needs a credential
 * it can put in the URL. ElevenLabs mints one that works once and expires
 * after 15 minutes, which keeps the real key here.
 */
async function scribeSessionToken(env: Env, path: string): Promise<Response> {
  const upstream = await fetch(`${ELEVENLABS}/single-use-token/realtime_scribe`, {
    method: "POST",
    headers: { "xi-api-key": env.ELEVENLABS_API_KEY },
  });
  if (!upstream.ok) {
    return await relayProviderFailure(upstream, path);
  }
  return new Response(await upstream.text(), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Hands the provider's error to the app, which shows it, but logs only the
 * status and size: provider error bodies can echo request text.
 */
async function relayProviderFailure(upstream: Response, path: string): Promise<Response> {
  const body = await upstream.text();
  const bytes = new TextEncoder().encode(body).byteLength;
  console.error(`[${path}] Provider error status=${upstream.status} response_bytes=${bytes}`);
  return new Response(body, {
    status: upstream.status,
    headers: { "content-type": "application/json" },
  });
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
