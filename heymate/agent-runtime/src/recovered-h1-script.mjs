// Recovered ReferenceRenderer 1.1.1 (66); formatter derivative. Exact source below.
var xI = new Set(["mac_step"]);
var uu = {
    type: "function",
    name: "run_script",
    strict: !1,
    description:
      'Run a short JavaScript program that calls your other tools itself, so one step can read many things, loop over items, filter big results and act. Use it when the same call repeats over items (open 16 emails, read 10 pages, fill a row per person) or when a result is big and you only need a few facts from it; for one or two calls, call the tools directly. `code` is the body of an async function. Every app and browser tool you have is `await tools.NAME(args)`, with exactly the arguments you would give it directly (for example `await tools.COMPOSIO_MULTI_EXECUTE_TOOL({tools: [...]})`, `await tools.browser({operation: "extract", tabId})`), and returns its result (parsed when it is JSON, else text); a call that fails throws. Run independent calls together with Promise.all. Only what you print with text(...), or return, comes back to you (at most 20,000 characters), so print just what you need. progress("Read 12 of 30") shows the user a short line while it runs. A program gets 3 minutes. It has no files or network of its own: use bash for files and fetch_url for pages.',
    parameters: {
      type: "object",
      required: ["code"],
      properties: {
        code: {
          type: "string",
          description:
            "The body of an async function, using tools.NAME(args) and text(...).",
        },
      },
    },
  },
  ff = (e) =>
    typeof e === "string"
      ? e
      : (() => {
          try {
            return JSON.stringify(e, null, 1);
          } catch {
            return String(e);
          }
        })();
async function hf(e, { callTool: t, hasTool: n, onProgress: r = () => {} }) {
  let s = [],
    i = 0,
    o = (..._) => {
      let T = _.map(ff).join(" ");
      if (i < 20000) s.push(T);
      i += T.length + 1;
    },
    a = 0,
    c = 0,
    l = 0,
    u = 0,
    p = new Proxy(
      {},
      {
        get: (_, T) => {
          if (typeof T !== "string" || T === "then") return;
          if (T === "toString" || T === "valueOf" || T === "toLocaleString")
            return () => "[tools: call await tools.NAME(args)]";
          if (
            T in Object.prototype ||
            T === "toJSON" ||
            T === "inspect" ||
            T === "constructor"
          )
            return;
          return (S = {}) => {
            let R = (async () => {
              if (!n(T)) throw Error(`There is no tool named ${T}.`);
              a++;
              let A = xI.has(T);
              if (A && c++ === 0) u = Date.now();
              let C;
              try {
                C = await t(T, S);
              } finally {
                if (A && --c === 0) l += Date.now() - u;
              }
              if (!C.ok)
                throw Error(`${T} failed: ${String(C.text).slice(0, 2000)}`);
              try {
                return JSON.parse(C.text);
              } catch {
                return C.text;
              }
            })();
            return (R.catch(() => {}), R);
          };
        },
      },
    ),
    m = (async () => {}).constructor,
    h = Date.now(),
    g,
    x = null;
  try {
    let _ = new m(
        "tools",
        "text",
        "progress",
        "console",
        "process",
        "require",
        "Bun",
        "globalThis",
        `'use strict';
${e}`,
      ),
      T = { log: o, info: o, warn: o, error: o },
      S = 0,
      R = (C) => {
        let v = String(C ?? "")
          .replace(/\s+/g, " ")
          .trim()
          .slice(0, 160);
        if (v && S++ < 20)
          try {
            r(v);
          } catch {}
      },
      A;
    g = await Promise.race([
      _(p, o, R, T, void 0, void 0, void 0, void 0),
      new Promise((C, v) => {
        let j = 0,
          W = 1000;
        A = setInterval(() => {
          if (c > 0) return;
          if (((j += W), j >= 180000))
            v(Error("The program ran past 180 s and was stopped."));
        }, W);
      }),
    ]).finally(() => clearInterval(A));
  } catch (_) {
    x = _?.message || String(_);
  }
  let b = s.join(`
`);
  if (g !== void 0 && !x)
    b += `${
      b
        ? `
`
        : ""
    }${ff(g)}`;
  if (i > 20000 || b.length > 20000)
    b = `${b.slice(0, 20000)}
\u2026 (cut at ${"20000"} characters: print less)`;
  if (x)
    b = `${
      b
        ? `${b}
`
        : ""
    }Error: ${x}`;
  if (c > 0) l += Date.now() - u;
  return {
    output: b || "(the program printed nothing)",
    ok: !x,
    calls: a,
    ms: Date.now() - h,
    userWaitMs: l,
  };
}
function gf(e) {
  let t = e.map((n) => {
    let r = Object.entries(n.parameters?.properties || {})
      .map(
        ([s, i]) =>
          `${s}${(n.parameters?.required || []).includes(s) ? "" : "?"}: ${i.type || "any"}`,
      )
      .join(", ");
    return `- tools.${n.name}({${r}}): ${n.description || ""}`;
  }).join(`
`);
  return {
    ...uu,
    name: "exec",
    description: `Run JavaScript, the body of an async function. Your app and browser tools are called only from here: \`await tools.NAME(args)\` returns the tool's result (parsed when it is JSON, else text) and throws if the call fails. Put independent calls in one exec with Promise.all or Promise.allSettled, and keep actions whose order matters in sequence. Only what you print with text(...), or return, comes back to you (20,000 characters at most), so print what you need to decide the next step. progress("Read 12 of 30") shows the user a short line while it runs. Use another exec when you need to look at results before deciding what to do next. 3 minutes per call; no files or network of its own (use bash and fetch_url for those).
The tools:
${t}`,
  };
}
export { hf, uu, gf };
