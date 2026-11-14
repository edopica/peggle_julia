// theme.typ: fonts, palette, status badges, callouts, tables, code style and
// glossary helpers for report/report.typ.

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------
#let f-serif = "Libertinus Serif"
#let f-sans = "Noto Sans"
#let f-mono = "JetBrainsMono NF"

// ---------------------------------------------------------------------------
// Palette (one source for text and figures)
// ---------------------------------------------------------------------------
#let ink = rgb("#1e293b")
#let muted = rgb("#64748b")
#let hair = rgb("#cbd5e1")
#let paper-tint = rgb("#f8fafc")
#let navy = rgb("#1e3a8a")

// Level colours: Okabe-Ito, colour-blind safe. One fixed colour per level in
// every chart and table. Each level also has a fixed marker shape.
#let level-order = ("ribbon_waves", "mustache", "circle_level", "squiggly_circle", "slide")
#let level-colors = (
  ribbon_waves: rgb("#0072b2"),
  mustache: rgb("#d55e00"),
  circle_level: rgb("#009e73"),
  squiggly_circle: rgb("#cc79a7"),
  slide: rgb("#e69f00"),
)
#let level-markers = (
  ribbon_waves: "circle",
  mustache: "square",
  circle_level: "triangle",
  squiggly_circle: "diamond",
  slide: "down",
)
#let lc(name) = level-colors.at(name)

// Pillar colours (sequential navy steps; used only where pillars are the series).
#let pillar-names = ("I: Agency", "II: Skill horizon", "III: Tactics", "IV: 1v1", "V: Elegance")

// ---------------------------------------------------------------------------
// Status badges (Section 0.4)
// ---------------------------------------------------------------------------
#let c-meas = rgb("#15803d")
#let c-meas-bg = rgb("#dcfce7")
#let c-code = rgb("#0369a1")
#let c-code-bg = rgb("#e0f2fe")
#let c-hand = rgb("#b45309")
#let c-hand-bg = rgb("#fef3c7")
#let c-theo = rgb("#6d28d9")
#let c-theo-bg = rgb("#ede9fe")
#let c-prop = rgb("#be123c")
#let c-prop-bg = rgb("#ffe4e6")

// The vertical padding is an outset, so a badge never changes the line height.
#let badge(label, fg, bg) = box(
  fill: bg,
  stroke: 0.5pt + fg.lighten(30%),
  radius: 2pt,
  inset: (x: 3pt, y: 0pt),
  outset: (y: 1.8pt),
  text(font: f-sans, size: 6.8pt, weight: "bold", fill: fg, tracking: 0.3pt, top-edge: "cap-height", bottom-edge: "baseline", label),
)
#let tag(kind) = {
  if kind == "MEASURED" { badge("MEASURED", c-meas, c-meas-bg) }
  else if kind == "CODE" { badge("CODE", c-code, c-code-bg) }
  else if kind == "HAND-SET" { badge("HAND-SET", c-hand, c-hand-bg) }
  else if kind == "THEORY" { badge("THEORY", c-theo, c-theo-bg) }
  else if kind == "PROPOSED" { badge("PROPOSED", c-prop, c-prop-bg) }
  else { badge(kind, muted, paper-tint) }
}

// ---------------------------------------------------------------------------
// Callouts: one colour, icon and label per kind.
// Icons are Font Awesome glyphs from the Nerd Font.
// ---------------------------------------------------------------------------
#let callout(kind, icon, color, bg, body) = block(
  breakable: false,
  above: 0.95em,
  below: 0.95em,
  width: 100%,
  fill: bg,
  stroke: (left: 3.2pt + color),
  radius: (right: 3pt),
  inset: (left: 10pt, right: 10pt, y: 7pt),
  {
    set par(justify: false, leading: 0.55em)
    grid(
      columns: (auto, 1fr),
      column-gutter: 8pt,
      align: (center + top, left + top),
      box(width: 1.1em, inset: (top: 1pt), text(font: f-mono, size: 10.5pt, fill: color, icon)),
      {
        block(below: 0.45em, text(font: f-sans, size: 7.2pt, weight: "bold", fill: color, tracking: 0.7pt, upper(kind)))
        set text(size: 9.8pt, fill: ink)
        body
      },
    )
  },
)
#let intuition(body) = callout("Intuition", "\u{F0EB}", rgb("#0f766e"), rgb("#effaf8"), body)
#let example(body) = callout("Example", "\u{F0C3}", rgb("#1d4ed8"), rgb("#eff4ff"), body)
#let watchout(body) = callout("Watch out", "\u{F071}", rgb("#b91c1c"), rgb("#fef4f4"), body)
#let keyidea(body) = callout("Key idea", "\u{F084}", rgb("#a16207"), rgb("#fffaeb"), body)

// ---------------------------------------------------------------------------
// Paths, file names and level names
// ---------------------------------------------------------------------------
// Allow line breaks after "/" "." "_" "-" in long monospace strings.
#let breakable(s) = s.replace("/", "/\u{200B}").replace("_", "_\u{200B}").replace(".", ".\u{200B}").replace("-", "-\u{200B}")

// A level name with its chart colour, for tables.
#let lv(name) = box({
  box(baseline: -0.15em, circle(radius: 2.6pt, fill: lc(name), stroke: none))
  h(3pt)
  text(font: f-mono, size: 0.84em, fill: ink, features: (calt: 0), name)
})

// ---------------------------------------------------------------------------
// Tables: styled header row, light zebra stripes, numbers right-aligned.
// ---------------------------------------------------------------------------
#let tbl(columns: auto, align: auto, size: 9pt, breakable: false, ..cells) = {
  let cs = cells.pos()
  let ncol = if type(columns) == array { columns.len() } else { columns }
  let al = if align == auto { (left,) * ncol } else { align }
  block(width: 100%, above: 0.9em, below: 1.1em, breakable: breakable, {
    set text(size: size, number-width: "tabular")
    set par(justify: false, leading: 0.5em)
    table(
      columns: columns,
      align: (x, y) => if y == 0 { al.at(x) + bottom } else { al.at(x) + horizon },
      inset: (x: 5pt, y: 4pt),
      stroke: (x, y) => (
        top: if y == 0 { 0.9pt + navy } else if y == 1 { 0.6pt + navy } else { 0.4pt + hair },
        bottom: 0.9pt + navy,
      ),
      fill: (x, y) => if y == 0 { rgb("#e8eef9") } else if calc.even(y) { rgb("#f6f8fc") } else { white },
      table.header(..cs.slice(0, ncol).map(c => text(font: f-sans, size: size - 1.4pt, weight: "bold", fill: navy, c))),
      ..cs.slice(ncol),
    )
  })
}

// ---------------------------------------------------------------------------
// Code style: inline paths and file names in monospace.
// ---------------------------------------------------------------------------
#let code-style(body) = {
  show raw.where(block: false): it => {
    let s = it.text
    let shown = if s.len() > 14 { breakable(s) } else { s }
    highlight(
      fill: rgb("#eef1f6"),
      top-edge: "ascender",
      bottom-edge: "descender",
      extent: 0.8pt,
      radius: 1pt,
      text(font: f-mono, size: 0.82em, fill: rgb("#0b2e59"), features: (calt: 0), shown),
    )
  }
  body
}

// ---------------------------------------------------------------------------
// Glossary: entries carry a label; the first use of a term in the body links
// to the entry, and the entry shows the page of the first use.
// ---------------------------------------------------------------------------
// First use of a glossary term in the body.
#let gl(key, body) = [#link(label("gl-" + key), text(fill: navy, body))#label("use-" + key)]

#let gl-entry(key, term, body) = (
  [#block(above: 0pt, below: 0pt, text(font: f-sans, size: 8.6pt, weight: "bold", fill: navy, term))#label("gl-" + key)],
  {
    body
    context {
      let uses = query(label("use-" + key))
      if uses.len() > 0 {
        let loc = uses.first().location()
        h(4pt)
        box(link(loc, text(font: f-sans, size: 7pt, fill: muted)[→ p.~#counter(page).at(loc).first()]))
      }
    }
  },
)

#let glossary(..entries) = {
  set par(justify: false, leading: 0.5em)
  set text(size: 9.4pt)
  grid(
    columns: (4.4cm, 1fr),
    column-gutter: 12pt,
    row-gutter: 0pt,
    inset: (x: 0pt, y: 5pt),
    stroke: (x, y) => (bottom: 0.4pt + hair),
    ..entries.pos().flatten(),
  )
}

// ---------------------------------------------------------------------------
// Visual key (contents page): how the PDF marks labels, callouts, levels
// and glossary links.
// ---------------------------------------------------------------------------
#let visual-key() = block(width: 100%, fill: paper-tint, stroke: 0.6pt + hair, radius: 4pt, inset: 9pt, breakable: false, {
  set par(justify: false, leading: 0.45em)
  set text(size: 8.6pt)
  let hd(t) = block(above: 0.9em, below: 0.45em, text(font: f-sans, size: 7.2pt, weight: "bold", fill: navy, tracking: 0.7pt, t))
  text(font: f-sans, size: 10pt, weight: "bold", fill: navy)[Visual key]
  hd[LABELS (SECTION 0.4)]
  grid(columns: (auto, 1fr), column-gutter: 7pt, row-gutter: 5pt, align: (right + horizon, left + horizon),
    tag("MEASURED"), [the profiler computed it],
    tag("CODE"), [the code does this],
    tag("HAND-SET"), [a person chose this number],
    tag("THEORY"), [from a paper or from physics],
    tag("PROPOSED"), [in the notes, not in the code],
  )
  hd[CALLOUTS]
  let sw(c, icon, name) = box(text(font: f-mono, size: 8.6pt, fill: c, icon) + h(5pt) + text(font: f-sans, size: 7.6pt, weight: "bold", fill: c, name))
  grid(columns: (1fr, 1fr), row-gutter: 5pt,
    sw(rgb("#0f766e"), "\u{F0EB}", "Intuition"), sw(rgb("#1d4ed8"), "\u{F0C3}", "Example"),
    sw(rgb("#b91c1c"), "\u{F071}", "Watch out"), sw(rgb("#a16207"), "\u{F084}", "Key idea"),
  )
  hd[ONE COLOUR PER LEVEL IN EVERY CHART]
  grid(columns: (1fr, 1fr), row-gutter: 5pt, ..level-order.map(n => lv(n)))
  hd[GLOSSARY LINKS]
  [A term in #text(fill: navy, weight: "bold")[blue bold] links to its entry in Section 6. Each entry links back to the page of first use.]
})
