// Recovered ReferenceRenderer 1.1.1 (66) telemetry. Bodies below are verbatim from the
// formatted mate-harness.bundle.js; only imports/exports are HeyMate adapters.
import * as bt from 'node:fs';
import * as Kn from 'node:path';

function ra(e) {
  let t = e?.usage || {};
  return {
    input: t.input_tokens || 0,
    cached: t.input_tokens_details?.cached_tokens || 0,
    cache_write: 0,
    output: t.output_tokens || 0,
    reasoning: t.output_tokens_details?.reasoning_tokens || 0,
  };
}

function Y2() {
  return {
    rounds: 0,
    modelMs: 0,
    inputTokens: 0,
    cachedTokens: 0,
    outputTokens: 0,
    reasoningTokens: 0,
    toolCalls: 0,
    toolErrors: 0,
    earlyStarts: 0,
    compactions: 0,
  };
}
function X2(e, t) {
  if (t.kind === "model_request" && t.purpose !== "compaction")
    ((e.rounds += 1),
      (e.modelMs += Math.max(0, (t.t_end ?? 0) - (t.t_send ?? 0))),
      (e.inputTokens += t.usage?.input || 0),
      (e.cachedTokens += t.usage?.cached || 0),
      (e.outputTokens += t.usage?.output || 0),
      (e.reasoningTokens += t.usage?.reasoning || 0));
  else if (t.kind === "tool_call") {
    if (((e.toolCalls += 1), t.ok === !1)) e.toolErrors += 1;
    if (t.early) e.earlyStarts += 1;
  } else if (t.kind === "compaction") e.compactions += 1;
}
function J2(e, t) {
  let n = null;
  if (t.kind === "model_request") {
    let r = (t.t_end ?? Date.now()) - (t.t_send ?? Date.now()),
      s = t.t_first_output && t.t_send ? t.t_first_output - t.t_send : null,
      i = t.usage || {};
    ((n = {
      kind: "round",
      t: t.t_send,
      ms: r,
      firstOutputMs: s,
      model: t.model,
      effort: t.effort,
      input: i.input,
      cached: i.cached,
      output: i.output,
      reasoning: i.reasoning,
      calls: t.function_calls || [],
      requestBytes: t.request_bytes,
      error: t.error || null,
    }),
      e.log(
        `H1 round: ${(r / 1000).toFixed(1)} s${s != null ? ` (first output ${(s / 1000).toFixed(1)} s)` : ""} \xB7 ${i.input ?? "?"} in (${i.cached ?? 0} cached) \xB7 ${i.output ?? "?"} out \xB7 ${(t.function_calls || []).join(", ") || "no calls"}${t.error ? ` \xB7 ${t.error}` : ""}`,
      ));
  } else if (t.kind === "tool_call") {
    let r = t.t_end && t.t ? t.t_end - t.t : null;
    n = {
      kind: "tool",
      t: t.t,
      ms: r,
      name: t.name,
      server: t.server,
      ok: t.ok,
      resultChars: t.result_chars,
      error: t.error || null,
      ...(t.name === "COMPOSIO_MULTI_EXECUTE_TOOL"
        ? {
            slugs: (t.args?.tools || [])
              .map((s) => s?.tool_slug)
              .filter(Boolean),
          }
        : {}),
    };
  }
  if (!n) return;
  try {
    bt.appendFileSync(
      Kn.join(e.state, "h1-rounds.jsonl"),
      `${JSON.stringify(n)}
`,
    );
  } catch {}
}

export { ra as responseUsage, Y2 as newRoundStats, X2 as addRoundEvent, J2 as writeRoundEvent };
