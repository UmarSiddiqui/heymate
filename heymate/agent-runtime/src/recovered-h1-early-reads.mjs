// Recovered H1 early-read closure. Only enclosing bindings/declaration adapter added.
export function recoveredEarlyReads({ cn, cu, tt, wt, p = {} }) {
  const me = new Map(),
      ee = (I, P) => {
        if (me.has(P.c.call_id) || !["box", "web", "mcpRead"].includes(P.cls))
          return;
        let Q = Date.now();
        me.set(
          P.c.call_id,
          (async () => {
            let F = { early: !0 },
              z,
              G = !0;
            try {
              if (P.cls === "box") {
                let le = await cn(I, P);
                if (le) ((z = le.content), (G = !le.isError), (F.no_box = !0));
                else {
                  let se = await I.boxTool({
                    callId: P.c.call_id,
                    name: P.c.name,
                    args: P.args,
                  });
                  ((z = se.content),
                    (G = !se.isError),
                    Object.assign(F, {
                      box_wait_ms: se.boxWaitMs ?? null,
                      hands_ms: se.handsMs ?? null,
                      exec_ms: se.ms ?? null,
                    }));
                }
              } else if (P.cls === "web")
                z = (await cu(P.args, { tunnel: p.tunnel })).content;
              else {
                let le = await tt(I, P, null);
                if (((z = le.content), (G = le.ok), le.offline)) F.offline = !0;
                Object.assign(F, le.timing || {});
              }
            } catch (le) {
              ((z = [{ type: "text", text: wt(le) }]), (G = !1));
            }
            return { content: z, ok: G, extra: F, t: Q };
          })(),
        );
      };
  return { start: ee, results: me };
}
