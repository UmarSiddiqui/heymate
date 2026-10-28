// ReferenceRenderer's H1 note tools, copied verbatim from the recovered 1.1.1 harness (mate-harness.bundle.js, formatted
// lines 21094-21431: la, $n, pt, jn, wf, Ne, It, yI, Tr, _f, Ef, Wn, wI note_add, _I note_replace, EI, Tf note_remove,
// TI note_tick, mu, SI note_answer) and its tool descriptions and note instructions (lines 21860-21997). Kept as
// emitted, to be rewritten later. HeyMate's own part is at the end: which note a chat writes and where it lives.
function la(e) {
  let t = (e || "")
    .replace(
      /\r\n/g,
      `
`,
    )
    .replace(
      /\n{3,}/g,
      `

`,
    );
  if (
    ((t = t.replace(/^\n+/, "")),
    t &&
      !t.endsWith(`
`))
  )
    t += `
`;
  return t;
}
var $n = (e) => {
    let t = la(e).split(`
`);
    if (t[t.length - 1] === "") t.pop();
    return t;
  },
  pt = (e) =>
    la(
      e
        .join(
          `
`,
        )
        .replace(
          /\n{3,}/g,
          `

`,
        ),
    );
function jn(e) {
  return (e || "")
    .trim()
    .replace(/\s*\{[^{}]*\}\s*$/, "")
    .replace(/\s*\{[^{}]*\}\s*$/, "")
    .replace(/^(#+|>|[-*\u2022+]\s+\[[ xX]\]|[-*\u2022+]|\d+[.)])\s*/, "")
    .replace(/^::+\w+\[?/, "")
    .replace(/\]$/, "")
    .replace(/\*\*|__|`|~~/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}
var wf = (e) =>
  new Set(
    jn(e)
      .split(/[^\p{L}\p{N}$\u20AC\u00A3%.]+/u)
      .filter((t) => t.length > 1),
  );
function Ne(e) {
  let t = (e || "").trim();
  if (!t) return "blank";
  if (/^#{1,6} /.test(t)) return "heading";
  if (t.startsWith("|")) return "table";
  if (t.startsWith("```")) return "fence";
  if (t === ":::") return "close";
  if (t.startsWith(":::")) return "open";
  if (t.startsWith("::")) return "object";
  if (t.startsWith(">")) return "quote";
  if (/^([-*\u2022+]|\d+[.)])\s/.test(t))
    return /^\s/.test(e) ? "detail" : "list";
  if (/^\s/.test(e)) return "detail";
  return "text";
}
var It = (e) => {
  let t = /^(#{1,6}) /.exec((e || "").trim());
  return t ? t[1].length : 0;
};
function yI(e) {
  let t = [],
    n = !1,
    r = !1;
  for (let s of e) {
    let i = Ne(s);
    if ((t.push(n || r), i === "fence")) r = !r;
    else if (!r && i === "open") n = !0;
    else if (!r && i === "close") n = !1;
  }
  return t;
}
function Tr(e, t, { only: n } = {}) {
  let r =
    (t || "")
      .split(
        `
`,
      )
      .map((p) => p.trim())
      .find(Boolean) || "";
  if (!r) return -1;
  let s = e
      .map((p, m) => ({ line: p, index: m }))
      .filter(({ line: p, index: m }) => p.trim() && (!n || n(p, m))),
    i = s.find(({ line: p }) => p.trim() === r);
  if (i) return i.index;
  let o = jn(r);
  if (o) {
    let p = s.find(({ line: h }) => jn(h) === o);
    if (p) return p.index;
    let m = s.find(({ line: h }) => It(h) && jn(h) === o);
    if (m) return m.index;
  }
  let a = s.find(({ line: p }) => p.includes(r));
  if (a) return a.index;
  if (o.length >= 4) {
    let p = s.find(({ line: m }) => jn(m).includes(o));
    if (p) return p.index;
  }
  let c = wf(r);
  if (c.size === 0) return -1;
  let l = -1,
    u = 0;
  for (let { line: p, index: m } of s) {
    let h = wf(p),
      g = 0;
    for (let b of c) if (h.has(b)) g++;
    let x = g / Math.max(c.size, Math.min(h.size, c.size * 2));
    if (x > u) ((u = x), (l = m));
  }
  return u >= 0.5 ? l : -1;
}
function _f(e, t, n) {
  let r = e[t],
    s = Ne(r),
    i = It(r),
    o = t + 1;
  if (i) {
    let a = i === 1 ? 2 : i;
    while (o < e.length && !(It(e[o]) && It(e[o]) <= a)) o++;
    while (o > t + 1 && !e[o - 1].trim()) o--;
    return o;
  }
  if (s === "open") {
    while (o < e.length && Ne(e[o]) !== "close") o++;
    return Math.min(o + 1, e.length);
  }
  if (s === "fence") {
    while (o < e.length && Ne(e[o]) !== "fence") o++;
    return Math.min(o + 1, e.length);
  }
  if (s === "list") {
    while (o < e.length && Ne(e[o]) === "detail") o++;
    return o;
  }
  if (s === "table" && n !== "table")
    while (o < e.length && Ne(e[o]) === "table") o++;
  return o;
}
var Ef = (e, t) =>
  (e === t && ["table", "list", "quote", "detail"].includes(e)) ||
  (e === "list" && t === "detail") ||
  (e === "detail" && t === "list") ||
  (e === "detail" && t === "detail");
function Wn(e, t, n) {
  let r = [...n];
  while (r.length && !r[0].trim()) r.shift();
  while (r.length && !r[r.length - 1].trim()) r.pop();
  if (!r.length) return e;
  let s = yI(e),
    i = t > 0 && t < e.length + 1 && (s[t] ?? !1) && Ne(e[t - 1]) !== "close",
    o = e.slice(0, t),
    a = e.slice(t),
    c = o[o.length - 1],
    l = a[0],
    u = Ne(c),
    p = Ne(r[0]),
    m = Ne(r[r.length - 1]),
    h = Ne(l),
    g = [...o];
  if (o.length && u !== "blank" && !i && !Ef(u, p)) g.push("");
  if ((g.push(...r), a.length && h !== "blank" && !i && !Ef(m, h))) g.push("");
  return (g.push(...a), g);
}
function wI(e, { after: t = "", md: n = "" }) {
  let r = String(t).indexOf('<parameter name="md">');
  if (r >= 0) {
    if (!n) n = String(t).slice(r + 21);
    t = String(t).slice(0, r).trim();
  }
  if (
    !n &&
    String(t).includes(`
`)
  )
    ((n = t), (t = ""));
  let s = $n(e),
    i = (n || "").replace(
      /\r\n/g,
      `
`,
    ).split(`
`),
    o = Ne(i.find((u) => u.trim()) || "");
  if (!String(t).trim()) return { md: pt(Wn(s, s.length, i)) };
  let a = /^#{1,6}\s/.test(String(t).trim()),
    c = Tr(s, t, a ? { only: (u) => It(u) > 0 } : {});
  if (c < 0) {
    let u = String(t)
      .replace(/^#+\s*/, "")
      .trim();
    if (
      /^#{2}\s/.test(String(t).trim()) ||
      (u && u.split(" ").length <= 5 && !/[|:>]/.test(u))
    ) {
      let p = Wn(s, s.length, [`## ${u}`]);
      return { md: pt(Wn(p, p.length, i)), note: `made a new page "${u}"` };
    }
    return {
      md: e,
      error: `Couldn't find "${String(t).slice(0, 80)}" in the note. Its headings: ${s.filter(It).join(" \xB7 ") || "(none)"}`,
    };
  }
  let l =
    i.filter((u) => u.trim()).every((u) => Ne(u) === "table") &&
    !i.some((u) => /^\s*\|[\s:|-]+\|\s*$/.test(u) && u.includes("-"));
  if (It(s[c]) && l) {
    let u = _f(s, c, o),
      p = -1;
    for (let m = c + 1; m < u; m++) if (Ne(s[m]) === "table") p = m;
    if (p >= 0)
      return {
        md: pt([
          ...s.slice(0, p + 1),
          ...i.filter((m) => m.trim()),
          ...s.slice(p + 1),
        ]),
      };
  }
  return { md: pt(Wn(s, _f(s, c, o), i)) };
}
function _I(e, { find: t = "", md: n = "" }) {
  if (!t) return { md: e, error: "find is empty" };
  let r = la(e);
  if (r.includes(t)) return { md: la(r.replace(t, n)) };
  let s = $n(e),
    i = Tr(s, t);
  if (i < 0)
    return {
      md: e,
      error: `Couldn't find "${String(t).slice(0, 80)}" in the note.`,
    };
  let o = (n || "").split(`
`),
    a = [...s.slice(0, i), ...(n ? o : []), ...s.slice(i + 1)];
  return { md: pt(a) };
}
function EI(e, t) {
  let n = e.replace(/\s*\{(pick|out|new|needs|done|now|gone)\}\s*$/i, "");
  if (Ne(e) === "table")
    return (
      (n = n.replace(/\s*\|\s*$/, "")),
      `${n.replace(/\s*\{(pick|out|new|needs|done|now|gone)\}\s*$/i, "")} {${t}} |`
    );
  return `${n} {${t}}`;
}
function Tf(e, { find: t = "", why: n = "" }) {
  let r = $n(e),
    s = Tr(r, t);
  if (s < 0)
    return {
      md: e,
      error: `Couldn't find "${String(t).slice(0, 80)}" in the note.`,
    };
  let i = Ne(r[s]),
    o = /^\s*[-*]\s+\[[ xX]\]/.test(r[s]);
  if (n && (i === "list" || i === "table") && !o) {
    let c = [...r];
    if (((c[s] = EI(r[s], "out")), i === "list")) {
      let l = s + 1;
      while (l < c.length && Ne(c[l]) === "detail") l++;
      c.splice(s + 1, l - s - 1, `  ${n}`);
    }
    return { md: pt(c) };
  }
  let a = s + 1;
  if (i === "list") while (a < r.length && Ne(r[a]) === "detail") a++;
  if (i === "open") {
    while (a < r.length && Ne(r[a]) !== "close") a++;
    a = Math.min(a + 1, r.length);
  }
  return { md: pt([...r.slice(0, s), ...r.slice(a)]) };
}
function TI(e, { item: t = "", next: n = "" }) {
  let r = $n(e),
    s = (c) => /^\s*[-*]\s+\[ \]/.test(c),
    i = (c) => /^\s*[-*]\s+\[[ xX]\]/.test(c),
    o = Tr(r, t, { only: s });
  if (o < 0) o = Tr(r, t, { only: i });
  if (o < 0)
    return {
      md: e,
      error: `No plan box like "${String(t).slice(0, 60)}". Boxes: ${r.filter(i).map(jn).join(" \xB7 ") || "(none)"}`,
    };
  let a = r.map((c) => (i(c) ? c.replace(/\s*\{now\}\s*$/i, "") : c));
  if (((a[o] = a[o].replace(/\[ \]/, "[x]")), n)) {
    let c = Tr(a, n, { only: s });
    if (c >= 0) a[c] = `${a[c]} {now}`;
  }
  return { md: pt(a) };
}
var mu = (e) =>
  String(e ?? "")
    .replace(/"/g, "'")
    .replace(/[{}]/g, "")
    .trim();
function SI(e, { line: t = "", big: n = "", aside: r = "" }) {
  if (!t) return { md: e, error: "line is empty" };
  let s = [n && `big="${mu(n)}"`, r && `note="${mu(r)}"`].filter(Boolean),
    i = `> ${String(t).replace(/\n/g, " ").trim()}${s.length ? ` {${s.join(" ")}}` : ""}`,
    o = $n(e),
    a = o.findIndex((u) => It(u) === 2);
  if (a < 0) {
    let u = o.findIndex((p) => It(p) === 1);
    ((o = Wn(o, u + 1, ["## In short"])),
      (a = o.findIndex((p) => It(p) === 2)));
  }
  let c = a + 1;
  while (c < o.length && It(o[c]) !== 2 && It(o[c]) !== 1) c++;
  let l = o.slice(a + 1, c).findIndex((u) => Ne(u) === "quote");
  if (l >= 0) {
    let u = [...o];
    return ((u[a + 1 + l] = i), { md: pt(u) });
  }
  return { md: pt(Wn(o, a + 1, [i])) };
}


var ns = (e, t) => ({
    type: "object",
    properties: e,
    required: t,
    additionalProperties: !1,
  }),
  Pt = (e) => ({ type: "string", description: e }),
  Us = {
    name: "note",
    description:
      "Write the whole note.md at once (it replaces the last version): for a page that isn't started yet, or when the job turned to something else. A page with your work on it changes through the small edits, which keep the lines the user watched being written.",
    parameters: ns(
      { md: Pt("the whole note: markdown with Mate paper objects") },
      ["md"],
    ),
  },
  pa = [
    {
      name: "note_add",
      description:
        'Add markdown to the note: after a page heading (= at the end of that page; a missing page is made), after an exact line (a table row \u2192 a new row under it), or after "" (= the end of the note).',
      parameters: ns(
        {
          after: Pt(
            'a page heading like "## Compare", an exact line of the note, or "" for the end',
          ),
          md: Pt("the markdown to add (lines of the note language)"),
        },
        ["after", "md"],
      ),
    },
    {
      name: "note_replace",
      description:
        "Replace an exact piece of the note (a line, a cell, a number) with new text.",
      parameters: ns(
        { find: Pt("exact text now in the note"), md: Pt("what replaces it") },
        ["find", "md"],
      ),
    },
    {
      name: "note_remove",
      description:
        "Remove a line. With why: an option ruled out, crossed through with the reason under it. Without why: the line goes (the page crosses it out).",
      parameters: ns(
        {
          find: Pt("the line (or part of it) to remove"),
          why: Pt("the reason it is ruled out (optional)"),
        },
        ["find"],
      ),
    },
    {
      name: "note_tick",
      description: "Tick a plan box; optionally mark the box you are on now.",
      parameters: ns(
        {
          item: Pt("the plan box (its words)"),
          next: Pt("the box you are working on now (optional)"),
        },
        ["item"],
      ),
    },
    {
      name: "note_answer",
      description:
        "Set the answer line on top of the first page: > line {big note}.",
      parameters: ns(
        {
          line: Pt("the answer in one short line"),
          big: Pt(
            "the one number or name that matters, under 12 characters (optional)",
          ),
          aside: Pt("a short aside in Mate's blue (optional)"),
        },
        ["line"],
      ),
    },
  ];
var $f = `- note_add(after, md): add markdown after a page heading (after="## Compare" = at the end of that page; a page that doesn't exist yet is made at the end of the note), or after an exact line (after a table row = a new row under it; after a list item = the next item). after="" = the end of the note.
- note_replace(find, md): replace an exact piece of the note (a whole line, a cell, a number) with new text.
- note_remove(find, why): an option you ruled out: with why, it is crossed through with the reason under it. Without why the line simply goes (the page crosses it out).
- note_tick(item, next): tick a plan box; next = the box you're on now.
- note_answer(line, big, aside): the answer line on top of the first page (big = the one number or name, aside = Mate's blue note).`,
  OI = `WHERE THINGS GO
- The plan boxes are only the plan: findings never go under them. Each finding goes on the page where it will live in the finished note (## Compare, ## The plan, ## Budget, ## Draft, ## Sources\u2026), as the object it is.
- One table per comparison: write it once with its header row, then add rows under it (after = its page heading or its last row). A page that already has a table gets rows, not a second table.`,
  Cf =
    "The note tools never need a reply: call one and keep going in the same breath (your next search, your next tool). Never write note.md with write, edit, bash or apply_patch.",
  vf =
    "When the note is done, end the turn with your final message as the job's instructions describe: the answer itself, then its blocks.";

// ---------------------------------------------------------------- HeyMate's own part
// The tools as Pi tools, applied to the chat's note (markdown in HeyMate's Notes folder, which the app watches).
export const noteEdits = { note: (md0, { md = '' }) => (md ? { md: pt($n(md)) } : { md: md0, error: 'md is empty' }), note_add: wI, note_replace: _I, note_remove: Tf, note_tick: TI, note_answer: SI };
export const noteToolDefinitions = [...pa, Us];
export const noteInstructions = [$f, OI, Cf].join('\n');
