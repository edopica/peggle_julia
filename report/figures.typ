// figures.typ: all charts and diagrams of report/report.typ, drawn with cetz.
// Units: 1 canvas unit = 1 cm. Maximum width 16.4 cm (A4 text width 16.6 cm).
// Every chart reads its numbers from the profile file, so the charts and the
// profiler output cannot drift apart. Compile with --root at the repository.

#import "@preview/cetz:0.4.2"
#import "theme.typ": *

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------
#let prof = json("/results/analysis/level_evaluation_profiles.json")
#let pillar-keys = (
  "Pillar1_Agency_Controllability",
  "Pillar2_Dynamical_Skill_Horizon",
  "Pillar3_Tactical_Landscape",
  "Pillar4_1v1_Competitive_Drama",
  "Pillar5_Structural_Elegance",
)
// Pillar weights from scripts/profile_level.jl (HAND-SET, Section 3.8).
#let pillar-weights = (0.22, 0.23, 0.20, 0.23, 0.12)
#let pillars(name) = pillar-keys.map(k => prof.at(name).composite_scores.at(k))
#let lqi(name) = prof.at(name).composite_scores.Overall_LQI
#let arith-mean(name) = pillars(name).zip(pillar-weights).map(((q, w)) => q * w).sum()
#let geom-mean(name) = pillars(name).zip(pillar-weights).map(((q, w)) => calc.pow(calc.max(0.01, q), w)).product()
#let st(name) = prof.at(name).single_turn
#let geo(name) = prof.at(name).static_geometry
#let match(name) = prof.at(name).campaign_1v1

// ---------------------------------------------------------------------------
// Text and number helpers
// ---------------------------------------------------------------------------
#let fsz = 7.6pt
#let T(body, size: fsz, fill: ink, weight: "regular", style: "normal") = text(
  font: f-sans, size: size, fill: fill, weight: weight, style: style, body,
)
#let B(body, size: fsz, fill: ink) = T(body, size: size, fill: fill, weight: "bold")
#let M(body, size: 7.2pt, fill: ink, weight: "regular") = text(
  font: f-mono, size: size, fill: fill, weight: weight, features: (calt: 0), body,
)

// Fixed number of decimals.
#let fx(v, d) = {
  let s = str(calc.round(v, digits: d))
  if d == 0 { return s }
  if not s.contains(".") { s += "." }
  let dec = s.split(".").at(1).len()
  s + "0" * (d - dec)
}

#let grid-col = rgb("#e2e8f0")
#let hatch(color) = tiling(size: (4pt, 4pt))[
  #place(line(start: (0pt, 4pt), end: (4pt, 0pt), stroke: 0.8pt + color))
]

// ---------------------------------------------------------------------------
// Drawing primitives
// ---------------------------------------------------------------------------
#let bx(a, b, body, bg: white, st: 0.6pt + ink, r: 0.08, pad: 0.1, al: center + horizon) = {
  import cetz.draw: *
  rect(a, b, fill: bg, stroke: st, radius: r)
  let (ax, ay) = a
  let (bx_, by) = b
  content((calc.min(ax, bx_) + pad, calc.min(ay, by) + pad), (calc.max(ax, bx_) - pad, calc.max(ay, by) - pad), align(al, {
    set text(font: f-sans, size: fsz, fill: ink)
    set par(leading: 0.42em, justify: false, spacing: 0.45em)
    body
  }))
}

#let arr(..pts, color: ink, w: 0.8pt, dash: none) = {
  import cetz.draw: *
  line(..pts.pos(), stroke: (paint: color, thickness: w, dash: dash), mark: (end: "stealth", fill: color, scale: 0.7))
}

// Marker shapes: one per level (theme.typ).
#let marker(p, kind, col, s: 0.085, ring: white) = {
  import cetz.draw: *
  let (x, y) = p
  let st = 0.6pt + ring
  if kind == "circle" { circle(p, radius: s, fill: col, stroke: st) }
  else if kind == "square" { rect((x - s * 0.9, y - s * 0.9), (x + s * 0.9, y + s * 0.9), fill: col, stroke: st) }
  else if kind == "triangle" { line((x, y + s * 1.25), (x - s * 1.15, y - s * 0.8), (x + s * 1.15, y - s * 0.8), close: true, fill: col, stroke: st) }
  else if kind == "diamond" { line((x, y + s * 1.3), (x + s * 1.1, y), (x, y - s * 1.3), (x - s * 1.1, y), close: true, fill: col, stroke: st) }
  else { line((x, y - s * 1.25), (x - s * 1.15, y + s * 0.8), (x + s * 1.15, y + s * 0.8), close: true, fill: col, stroke: st) }
}
#let lmark(p, name, s: 0.085) = marker(p, level-markers.at(name), lc(name), s: s)

// Level legend in one row, from x0 to x0 + w, at height y.
#let level-legend(x0, y, w, names: level-order, chips: false) = {
  import cetz.draw: *
  let widths = names.map(n => 0.62 + n.len() * 0.155)
  let gap = (w - widths.sum()) / (names.len() - 1)
  let x = x0
  for (i, n) in names.enumerate() {
    if chips {
      rect((x + 0.1, y - 0.12), (x + 0.42, y + 0.12), fill: lc(n), stroke: none, radius: 0.03)
    } else {
      line((x, y), (x + 0.5, y), stroke: 1.3pt + lc(n))
      lmark((x + 0.25, y), n)
    }
    content((x + 0.58, y), anchor: "west", M(n))
    x += widths.at(i) + gap
  }
}

// Axes, grid, ticks and axis titles. xpos / ypos map data to canvas units.
#let frame(w, h, xt, yt, xlabel, ylabel, xpos: v => v, ypos: v => v, xfmt: v => str(v), yfmt: v => str(v), ylabel-dx: 0.95) = {
  import cetz.draw: *
  for v in yt {
    line((0, ypos(v)), (w, ypos(v)), stroke: 0.35pt + grid-col)
    content((-0.12, ypos(v)), anchor: "east", T(size: 7pt, fill: muted, yfmt(v)))
  }
  for v in xt {
    line((xpos(v), 0), (xpos(v), -0.08), stroke: 0.5pt + muted)
    content((xpos(v), -0.16), anchor: "north", T(size: 7pt, fill: muted, xfmt(v)))
  }
  line((0, 0), (w, 0), stroke: 0.7pt + ink)
  line((0, 0), (0, h), stroke: 0.5pt + muted)
  content((w / 2, -0.62), anchor: "north", T(size: 7.6pt, xlabel))
  content((-ylabel-dx, h / 2), angle: 90deg, T(size: 7.6pt, ylabel))
}

// A line series with markers.
#let series(pts, name, w: 1.3pt) = {
  import cetz.draw: *
  line(..pts, stroke: (paint: lc(name), thickness: w, join: "round"))
  for p in pts { lmark(p, name) }
}

// Schematic tag for figures that show no data.
#let schematic-tag(p, anc: "north-east") = {
  import cetz.draw: *
  content(p, anchor: anc, box(fill: rgb("#fff7ed"), stroke: 0.7pt + rgb("#c2410c"), radius: 2pt, inset: (x: 5pt, y: 3pt),
    text(font: f-sans, size: 7pt, weight: "bold", fill: rgb("#c2410c"), tracking: 0.6pt)[SCHEMATIC · NOT DATA]))
}

// ---------------------------------------------------------------------------
// Level thumbnails, drawn from the level files.
// ---------------------------------------------------------------------------
#let slide-col = rgb("#fbbf24")
#let loose-col = rgb("#7fb2ff")
#let level-file(name) = json("/" + prof.at(name).level_path)

// Draws a level with its bottom-left corner at origin and the given height.
// Returns nothing; the width is height * virtual_width / virtual_height.
#let level-width(name, height) = {
  let lv = level-file(name)
  height * lv.virtual_width / lv.virtual_height
}
#let draw-level(name, origin, height, launcher: true) = {
  import cetz.draw: *
  let lv = level-file(name)
  let W = lv.virtual_width
  let H = lv.virtual_height
  let s = height / H
  let (ox, oy) = origin
  rect((ox, oy), (ox + W * s, oy + height), fill: rgb("#1a1a26"), stroke: none, radius: 0.05)
  let P(x, y) = (ox + x * s, oy + height - y * s)
  for p in lv.pegs {
    let ln = p.at("line", default: none)
    let col = if ln != none and ln.gap == 0 { slide-col } else { loose-col }
    if p.shape == "circle" {
      circle(P(p.x, p.y), radius: calc.max(p.radius * s, 0.012), fill: col, stroke: none)
    } else if p.shape == "rectangle" {
      let c = calc.cos(p.angle)
      let sn = calc.sin(p.angle)
      let hw = p.width / 2
      line(P(p.x - hw * c, p.y - hw * sn), P(p.x + hw * c, p.y + hw * sn), stroke: (paint: col, thickness: p.height * s * 1cm, cap: "butt"))
    } else if p.shape == "annular" {
      let r = (p.r_in + p.r_out) / 2
      let n = 5
      let pts = range(n + 1).map(i => {
        let t = p.theta_start + (p.theta_end_abs - p.theta_start) * i / n
        P(p.x + r * calc.cos(t), p.y + r * calc.sin(t))
      })
      line(..pts, stroke: (paint: col, thickness: calc.max((p.r_out - p.r_in) * s, 0.025) * 1cm, cap: "butt"))
    }
  }
  if launcher {
    let (lx, ly) = P(W / 2, 0)
    line((lx - 0.09, ly), (lx + 0.09, ly), (lx, ly - 0.13), close: true, fill: white, stroke: none)
  }
}

#let fig-thumbnails() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let h = 2.55
  let gap = 0.3
  let x = 0
  for n in level-order {
    let w = level-width(n, h)
    let slot = calc.max(w, 2.75)
    draw-level(n, (x + (slot - w) / 2, 0), h)
    let g = geo(n)
    let cx = x + slot / 2
    content((cx, -0.12), anchor: "north", {
      set par(leading: 0.35em)
      align(center)[
        #box(baseline: -0.1em, std.circle(radius: 2.6pt, fill: lc(n), stroke: none)) #M(weight: "bold", n) \
        #T(size: 7pt, fill: muted)[#g.total_pegs pegs] \
        #T(size: 7pt, fill: muted)[slide fraction #fx(g.slide_fraction, 2)]
      ]
    })
    x += slot + gap
  }
  // legend
  let y = -1.45
  circle((0.15, y), radius: 0.09, fill: loose-col, stroke: none)
  content((0.32, y), anchor: "west", T[loose peg (not on a slide)])
  line((3.6, y), (4.1, y), stroke: (paint: slide-col, thickness: 2.4pt))
  content((4.22, y), anchor: "west", T[slide peg (on a line with no gap)])
  line((8.3, y + 0.07), (8.48, y + 0.07), (8.39, y - 0.07), close: true, fill: ink, stroke: none)
  content((8.6, y), anchor: "west", T[launcher])
})

// ---------------------------------------------------------------------------
// Section 2.3: the noisy aim channel
// ---------------------------------------------------------------------------
#let fig-channel() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let y0 = 2.6
  let hb = 0.55
  bx((0, y0 - hb), (3.0, y0 + hb), [#B(size: 8.4pt)[intended aim] $a$ \ #T(fill: muted)[what the player wants]], bg: rgb("#eef2fb"), st: 0.8pt + navy)
  bx((7.0, y0 - hb), (10.0, y0 + hb), [#B(size: 8.4pt)[fired aim] $tilde(a)$ \ #T(fill: muted)[what the game fires]], bg: rgb("#eef2fb"), st: 0.8pt + navy)
  bx((13.4, y0 - hb), (16.4, y0 + hb), [#B(size: 8.4pt)[outcome] $O$ \ #T(fill: muted)[which pegs, which route]], bg: rgb("#eef2fb"), st: 0.8pt + navy)
  arr((3.05, y0), (6.95, y0), color: rgb("#b91c1c"), w: 1.1pt)
  content((5.0, y0 + 0.15), anchor: "south", B(fill: rgb("#b91c1c"))[hand / mouse noise, ±σ steps])
  content((5.0, y0 - 0.15), anchor: "north", T(fill: muted)[random])
  arr((10.05, y0), (13.35, y0), color: ink, w: 1.1pt)
  content((11.7, y0 + 0.15), anchor: "south", B[deterministic physics])
  content((11.7, y0 - 0.15), anchor: "north", T(fill: muted)[no randomness])

  // bar chart of the noise distribution under the first arrow
  let bw = 0.5
  let sp = 0.78
  let x0 = 3.3
  let ybase = 0.0
  let hmax = 1.2 // height of probability 1/5 bars
  line((x0 - 0.15, ybase), (x0 + 5 * sp, ybase), stroke: 0.7pt + ink)
  line((x0 - 0.15, ybase), (x0 - 0.15, ybase + hmax + 0.25), stroke: 0.5pt + muted)
  line((x0 - 0.2, ybase + hmax), (x0 - 0.15, ybase + hmax), stroke: 0.5pt + muted)
  content((x0 - 0.25, ybase + hmax), anchor: "east", T(size: 7pt, fill: muted)[1/5])
  content((x0 - 0.25, ybase), anchor: "east", T(size: 7pt, fill: muted)[0])
  let labels = ([$a-2$], [$a-1$], [$a$], [$a+1$], [$a+2$])
  for i in range(5) {
    let cx = x0 + 0.25 + i * sp
    rect((cx - bw / 2, ybase), (cx + bw / 2, ybase + hmax), fill: rgb("#fca5a5"), stroke: 0.6pt + rgb("#b91c1c"))
    content((cx, ybase - 0.1), anchor: "north", text(size: 7.4pt, labels.at(i)))
  }
  content((x0 + 5 * sp + 0.15, ybase + hmax / 2 + 0.2), anchor: "west", B(fill: rgb("#b91c1c"))[σ = 2])
  content((x0 + 5 * sp + 0.15, ybase + hmax / 2 - 0.2), anchor: "west", T(fill: muted)[5 equal chances])
  content((x0 + 2.0, ybase - 0.55), anchor: "north", T(fill: muted)[probability of each fired aim])
  line((5.0, y0 - 0.6), (5.0, ybase + hmax + 0.15), stroke: (paint: muted, thickness: 0.5pt, dash: "dotted"))
})

// ---------------------------------------------------------------------------
// Section 2.6: round peg spreads, slide focuses (schematic)
// ---------------------------------------------------------------------------
// Reflection of a ray (point p, unit direction d) on a circle (c, r).
#let reflect-circle(p, d, c, r) = {
  let (px, py) = p
  let (dx, dy) = d
  let (cx, cy) = c
  let fx_ = px - cx
  let fy = py - cy
  let b = fx_ * dx + fy * dy
  let cc = fx_ * fx_ + fy * fy - r * r
  let disc = b * b - cc
  let t = -b - calc.sqrt(disc)
  let hx = px + t * dx
  let hy = py + t * dy
  let nx = (hx - cx) / r
  let ny = (hy - cy) / r
  let dn = dx * nx + dy * ny
  ((hx, hy), (dx - 2 * dn * nx, dy - 2 * dn * ny))
}

#let fig-paths() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let path-cols = (rgb("#1d4ed8"), rgb("#0f766e"), rgb("#b91c1c"))
  // ---- left panel: round peg spreads
  rect((0, 0), (7.6, 4.9), fill: paper-tint, stroke: 0.5pt + hair, radius: 0.1)
  content((0.25, 4.6), anchor: "west", B(size: 8.6pt, fill: navy)[Round peg spreads])
  content((7.35, 4.6), anchor: "east", T(size: 8.4pt, fill: rgb("#b91c1c"), weight: "bold")[λ > 0])
  let c = (3.1, 1.7)
  let r = 0.8
  circle(c, radius: r, fill: loose-col.darken(10%), stroke: 0.8pt + navy)
  let d = (0.0, -1.0)
  let perp = (1.0, 0.0)
  for (i, off) in (0.2, 0.45, 0.7).enumerate() {
    let base = (c.at(0) + off * r, 4.2)
    let (hit, out) = reflect-circle(base, d, c, r)
    line(base, hit, stroke: 1pt + path-cols.at(i))
    // stop the outgoing ray at the panel border
    let (hx, hy) = hit
    let (ox, oy) = out
    let L = 3.2
    if ox > 0.001 { L = calc.min(L, (7.4 - hx) / ox) }
    if ox < -0.001 { L = calc.min(L, (0.2 - hx) / ox) }
    if oy > 0.001 { L = calc.min(L, (4.25 - hy) / oy) }
    if oy < -0.001 { L = calc.min(L, (0.75 - hy) / oy) }
    arr(hit, (hx + L * ox, hy + L * oy), color: path-cols.at(i), w: 1pt)
  }
  content((1.4, 0.35), anchor: "west", T(fill: muted)[three nearly parallel paths in, a wide fan out])

  // ---- right panel: slide focuses
  let X = 8.8
  rect((X, 0), (X + 7.6, 4.9), fill: paper-tint, stroke: 0.5pt + hair, radius: 0.1)
  content((X + 0.25, 4.6), anchor: "west", B(size: 8.6pt, fill: navy)[Slide focuses])
  content((X + 7.35, 4.6), anchor: "east", T(size: 8.4pt, fill: rgb("#15803d"), weight: "bold")[λ < 0])
  // curved slide: y = f(x) on [X+0.8, X+5.6]
  let f(x) = { let u = (x - X - 0.8) / 4.8; 3.3 - 2.0 * u - 0.35 * calc.sin(u * 3.14159) }
  let npeg = 15
  for k in range(npeg) {
    let x = X + 0.8 + 4.8 * k / (npeg - 1)
    circle((x, f(x) - 0.13), radius: 0.13, fill: slide-col, stroke: 0.5pt + rgb("#a16207"))
  }
  // three paths land at different points, roll and leave together
  let lands = (X + 1.3, X + 2.2, X + 3.1)
  let offs = (0.13, 0.08, 0.03)
  for (i, lx) in lands.enumerate() {
    line((lx, 4.25), (lx, f(lx) + 0.06), stroke: 1pt + path-cols.at(i))
    let pts = range(13).map(j => {
      let x = lx + (X + 5.6 - lx) * j / 12
      let o = 0.06 + offs.at(i) * (1 - j / 12) * 0.0
      (x, f(x) + 0.05 + 0.05 * i * (1 - j / 12))
    })
    line(..pts, stroke: 1pt + path-cols.at(i))
    let (ex, ey) = pts.last()
    arr((ex, ey), (ex + 1.6, ey - 0.95 - 0.02 * i), color: path-cols.at(i), w: 1pt)
  }
  content((X + 0.3, 0.35), anchor: "west", T(fill: muted)[three landing points, one almost identical exit])
})

// ---------------------------------------------------------------------------
// Section 2.8: belief curves (schematic, not data)
// ---------------------------------------------------------------------------
#let fig-belief() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 11.5
  let h = 4.2
  let X(t) = t / 10 * w
  let Y(p) = p * h
  frame(w, h, range(0, 11), (0, 0.25, 0.5, 0.75, 1), [turn $t$], [belief $p_t$ that Player 1 wins],
    xpos: X, ypos: Y, yfmt: v => fx(v, 2), ylabel-dx: 0.9)
  line((0, Y(0.5)), (w, Y(0.5)), stroke: (paint: muted, thickness: 0.8pt, dash: "dashed"))
  let A = (0.5, 0.42, 0.58, 0.66, 0.40, 0.33, 0.47, 0.61, 0.74, 0.86, 1.0)
  let Bc = range(11).map(t => 0.5 + 0.05 * t)
  let colA = navy
  let colB = rgb("#94a3b8")
  line(..Bc.enumerate().map(((t, p)) => (X(t), Y(p))), stroke: (paint: colB, thickness: 1.3pt, dash: (3pt, 2pt)))
  line(..A.enumerate().map(((t, p)) => (X(t), Y(p))), stroke: 1.4pt + colA)
  for (t, p) in A.enumerate() { circle((X(t), Y(p)), radius: 0.07, fill: colA, stroke: 0.6pt + white) }
  // jump arrows on curve A
  for t in range(1, 11) {
    let x = X(t) - 0.22
    arr((x, Y(A.at(t - 1))), (x, Y(A.at(t))), color: rgb("#b91c1c"), w: 0.7pt)
  }
  content((X(5), Y(0.22)), anchor: "north", T(fill: colA, weight: "bold")[A: dramatic])
  content((X(6.5), Y(0.86) + 0.05), anchor: "south-east", T(fill: colB.darken(30%), weight: "bold")[B: one-sided])
  // side legend
  let lx = w + 0.5
  content((lx, h - 0.5), anchor: "north-west", box(width: 4.1cm, {
    set par(leading: 0.42em, justify: false)
    T[#text(fill: rgb("#b91c1c"), weight: "bold")[↕ red arrows:] the jumps $|p_t - p_(t-1)|$ of curve A.]
    v(4pt)
    T[#text(weight: "bold")[surprise = average arrow length]]
    v(4pt)
    T(fill: muted)[A crosses 0.5 three times and ends at 1. B rises steadily from 0.5 to 1.]
  }))
  schematic-tag((w + 0.5, h + 0.2), anc: "north-west")
})

// ---------------------------------------------------------------------------
// Section 2.11: MAP-Elites grid with the five measured levels
// ---------------------------------------------------------------------------
#let fig-mapelites() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let cw = 2.95
  let ch = 1.7
  let ncol = 5
  let nrow = 4
  let rows = ("0 – 4", "4 – 8", "8 – 12", "12 – 15+")
  // cell index of a level
  let kh(n) = {
    let k = st(n).skill_horizon.k_half_scored
    if k >= 15 { 15 } else { k }
  }
  let col-of(n) = calc.min(int(geo(n).slide_fraction * 5), 4)
  let row-of(n) = calc.min(int(kh(n) / 4), 3)
  for c in range(ncol) {
    for r in range(nrow) {
      rect((c * cw, r * ch), ((c + 1) * cw, (r + 1) * ch), fill: white, stroke: 0.5pt + hair)
    }
  }
  for c in range(ncol + 1) {
    content((c * cw, -0.1), anchor: "north", T(size: 7pt, fill: muted, fx(c * 0.2, 1)))
  }
  for r in range(nrow) {
    content((-0.12, (r + 0.5) * ch), anchor: "east", T(size: 7pt, fill: muted, rows.at(r)))
  }
  content((ncol * cw / 2, -0.55), anchor: "north", T(size: 7.6pt)[slide fraction $f_"slide"$])
  content((-1.45, nrow * ch / 2), angle: 90deg, T(size: 7.6pt)[skill horizon $k_(1\/2)$ (hits)])
  // group levels by cell; keep the best (elite) per cell
  let cells = (:)
  for n in level-order {
    let key = str(col-of(n)) + "-" + str(row-of(n))
    cells.insert(key, cells.at(key, default: ()) + (n,))
  }
  for (key, ns) in cells {
    let (c, r) = key.split("-").map(int)
    let sorted = ns.sorted(key: n => -lqi(n))
    let elite = sorted.first()
    let x0 = c * cw
    let y0 = r * ch
    rect((x0 + 0.03, y0 + 0.03), (x0 + cw - 0.03, y0 + ch - 0.03), fill: lc(elite).lighten(85%), stroke: 1pt + lc(elite))
    let th = 1.05
    let tw = level-width(elite, th)
    let tw2 = calc.min(tw, 0.95)
    let thh = th * tw2 / tw
    draw-level(elite, (x0 + 0.12, y0 + (ch - thh) / 2), thh, launcher: false)
    let tx = x0 + 0.12 + tw2 + 0.1
    content((tx, y0 + ch - 0.22), anchor: "north-west", {
      set par(leading: 0.35em)
      M(size: 5.9pt, weight: "bold", elite)
      linebreak()
      T(size: 7pt)[LQI #fx(lqi(elite), 3)]
      for other in sorted.slice(1) {
        linebreak()
        T(size: 6pt, fill: muted)[#strike[#M(size: 5.6pt, fill: muted, other) #fx(lqi(other), 3)]]
      }
    })
  }
  // note
  content((0, nrow * ch + 0.12), anchor: "south-west",
    T(size: 7pt, fill: muted)[Coloured cell: the elite, the level with the best LQI in that cell. Struck out: a level that lost its cell to a better one. Empty cell: a search would try to fill it.])
})

// ---------------------------------------------------------------------------
// Section 3.1: tiers -> pillars -> LQI
// ---------------------------------------------------------------------------
#let fig-pipeline() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let tier-bg = rgb("#e0f2fe")
  let tier-st = 0.8pt + rgb("#0369a1")
  let pil-bg = rgb("#eef2fb")
  let pil-st = 0.8pt + navy
  // level
  bx((5.4, 7.15), (10.6, 7.85), [#B(size: 8.6pt)[Level] #T(fill: muted)[(pegs, shapes, lines)]], bg: rgb("#1a1a26").lighten(92%), st: 0.8pt + ink)
  // tiers: x ranges
  let t1 = (0.4, 7.4)
  let t2 = (8.0, 12.2)
  let t0 = (12.8, 16.0)
  let ty = (5.35, 6.35)
  bx((t1.at(0), ty.at(0)), (t1.at(1), ty.at(1)), [#B[Tier 1: 1801-aim sweep] \ #T(fill: muted)[about 0.5 to 5 s]], bg: tier-bg, st: tier-st)
  bx((t2.at(0), ty.at(0)), (t2.at(1), ty.at(1)), [#B[Tier 2: 1v1 bot matches] \ #T(fill: muted)[about 15 to 120 s]], bg: tier-bg, st: tier-st)
  bx((t0.at(0), ty.at(0)), (t0.at(1), ty.at(1)), [#B[Tier 0: geometry only] \ #T(fill: muted)[< 1 ms]], bg: tier-bg, st: tier-st)
  for t in (t1, t2, t0) {
    let cx = (t.at(0) + t.at(1)) / 2
    arr((8.0, 7.15), (cx, ty.at(1) + 0.03), color: muted, w: 0.8pt)
  }
  // pillars
  let names = ("Agency and control", "Skill horizon", "Tactical landscape", "1v1 drama and skill", "Structural elegance")
  let roman = ("I", "II", "III", "IV", "V")
  let pw = 3.0
  let pg = 0.25
  let px(i) = 0.1 + i * (pw + pg)
  let py = (2.7, 3.95)
  for i in range(5) {
    bx((px(i), py.at(0)), (px(i) + pw, py.at(1)), [#B(fill: navy)[Pillar #roman.at(i)] \ #T[#names.at(i)] \ #T(fill: muted, size: 7pt)[weight #fx(pillar-weights.at(i), 2)]], bg: pil-bg, st: pil-st)
  }
  let pc(i) = px(i) + pw / 2
  // tier -> pillar arrows
  for i in range(3) {
    arr((1.6 + i * 2.6, ty.at(0)), (pc(i), py.at(1) + 0.03), color: rgb("#0369a1"), w: 0.9pt)
  }
  arr(((t2.at(0) + t2.at(1)) / 2 + 0.2, ty.at(0)), (pc(3), py.at(1) + 0.03), color: rgb("#0369a1"), w: 0.9pt)
  arr(((t0.at(0) + t0.at(1)) / 2, ty.at(0)), (pc(4), py.at(1) + 0.03), color: rgb("#0369a1"), w: 0.9pt)
  // Tier 1 also feeds Pillar V (AUC_MI in MDL efficiency)
  line((6.9, ty.at(0)), (6.9, 4.65), (pc(4) - 0.5, 4.65), stroke: (paint: rgb("#0369a1"), thickness: 0.8pt, dash: "dashed"))
  arr((pc(4) - 0.5, 4.65), (pc(4) - 0.5, py.at(1) + 0.03), color: rgb("#0369a1"), w: 0.8pt, dash: "dashed")
  content((12.35, 4.71), anchor: "south", box(fill: white, inset: 1.5pt, T(size: 6.8pt, fill: rgb("#0369a1"))[also Pillar V]))
  // pillars -> LQI
  let ly = (0.4, 1.5)
  for i in range(5) {
    arr((pc(i), py.at(0)), (4.6 + i * 1.7, ly.at(1) + 0.03), color: navy, w: 0.8pt)
  }
  bx((3.6, ly.at(0)), (12.4, ly.at(1)), [#B(size: 9pt, fill: white)[LQI = ½ arithmetic mean + ½ geometric mean] \ #T(fill: white.darken(15%))[one rating from 0 to 1]], bg: navy, st: none)
  // row labels
  content((-0.05, 6.75), anchor: "west", T(size: 6.8pt, fill: muted, weight: "bold")[LAYER 1 · DATA TIERS])
  content((-0.05, 4.3), anchor: "west", T(size: 6.8pt, fill: muted, weight: "bold")[LAYER 2 · PILLARS])
  content((-0.05, 1.95), anchor: "west", T(size: 6.8pt, fill: muted, weight: "bold")[LAYER 3 · ONE FORMULA])
})

// ---------------------------------------------------------------------------
// Section 3.7: the balance hill with the five levels
// ---------------------------------------------------------------------------
#let fig-hill() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 10.5
  let h = 4.6
  let X(f) = f * w
  let Y(b) = b * h
  frame(w, h, (0, 0.2, 0.4, 0.6, 0.8, 1), (0, 0.25, 0.5, 0.75, 1),
    [slide fraction $f_"slide"$], [balance $B_"wg"$], xpos: X, ypos: Y,
    xfmt: v => fx(v, 1), yfmt: v => fx(v, 2), ylabel-dx: 0.9)
  let pts = range(101).map(i => { let f = i / 100; (X(f), Y(4 * f * (1 - f))) })
  line(..pts, stroke: 1.4pt + ink)
  content((X(0.47), Y(1) + 0.08), anchor: "south-east", T(fill: muted)[peak 1 at an even mix])
  // level points and labels (offsets chosen to avoid overlaps)
  let lab = (
    ribbon_waves: (dx: 0.3, dy: 0.25, anchor: "south-west"),
    mustache: (dx: 0.3, dy: 0.1, anchor: "west"),
    circle_level: (dx: 0.25, dy: 0.32, anchor: "south-west"),
    squiggly_circle: (dx: -0.45, dy: 1.15, anchor: "south-east"),
    slide: (dx: -0.6, dy: 0.5, anchor: "south-east"),
  )
  for n in level-order {
    let f = geo(n).slide_fraction
    let b = geo(n).waveguide_scatterer_balance
    let p = (X(f), Y(b))
    let o = lab.at(n)
    let q = (p.at(0) + o.dx, p.at(1) + o.dy)
    line(p, q, stroke: 0.4pt + muted)
    content(q, anchor: o.anchor, box(fill: white, inset: 1pt, [#M(n) #T(fill: muted)[(#fx(f, 2), #fx(b, 2))]]))
  }
  for n in level-order {
    lmark((X(geo(n).slide_fraction), Y(geo(n).waveguide_scatterer_balance)), n, s: 0.12)
  }
})

// ---------------------------------------------------------------------------
// Section 3.8: arithmetic vs geometric mean
// ---------------------------------------------------------------------------
#let fig-means() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 13.0
  let h = 4.4
  let Y(v) = v * h
  let gw = w / 5
  frame(w, h, (), (0, 0.2, 0.4, 0.6, 0.8, 1), [], [rating (0 to 1)], ypos: Y, yfmt: v => fx(v, 1), ylabel-dx: 0.85)
  let bw = 0.62
  for (i, n) in level-order.enumerate() {
    let cx = (i + 0.5) * gw
    let a = arith-mean(n)
    let g = geom-mean(n)
    let l = lqi(n)
    rect((cx - bw - 0.03, 0), (cx - 0.03, Y(a)), fill: lc(n), stroke: none)
    rect((cx + 0.03, 0), (cx + bw + 0.03, Y(g)), fill: hatch(lc(n)), stroke: 0.9pt + lc(n))
    // LQI marker on the gap between the bars
    line((cx - bw - 0.15, Y(l)), (cx + bw + 0.15, Y(l)), stroke: (paint: ink, thickness: 0.8pt, dash: (2pt, 1.5pt)))
    circle((cx, Y(l)), radius: 0.1, fill: ink, stroke: 1pt + white)
    content((cx, -0.15), anchor: "north", M(n))
    content((cx, -0.48), anchor: "north", T(size: 7pt, fill: muted)[LQI #fx(l, 3)])
  }
  // legend
  let lx = w + 0.4
  rect((lx, Y(0.92)), (lx + 0.4, Y(0.92) + 0.25), fill: rgb("#64748b"), stroke: none)
  content((lx + 0.5, Y(0.92) + 0.125), anchor: "west", T[arithmetic mean])
  rect((lx, Y(0.8)), (lx + 0.4, Y(0.8) + 0.25), fill: hatch(rgb("#64748b")), stroke: 0.9pt + rgb("#64748b"))
  content((lx + 0.5, Y(0.8) + 0.125), anchor: "west", T[geometric mean])
  circle((lx + 0.2, Y(0.68) + 0.125), radius: 0.1, fill: ink, stroke: 1pt + white)
  content((lx + 0.5, Y(0.68) + 0.125), anchor: "west", T[LQI (half of each)])
  content((lx, Y(0.52)), anchor: "north-west", box(width: 2.6cm, {
    set par(leading: 0.4em, justify: false)
    T(size: 7pt, fill: muted)[Bar colour = level. The gap between the two bars grows when one pillar is weak.]
  }))
})

// ---------------------------------------------------------------------------
// Section 4.2: LQI per level
// ---------------------------------------------------------------------------
#let fig-lqi() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 12.0
  let rh = 0.55
  let names = level-order.sorted(key: n => -lqi(n))
  let h = names.len() * rh + 0.1
  let X(v) = v * w
  for v in (0, 0.2, 0.4, 0.6, 0.8, 1) {
    line((X(v), 0), (X(v), h), stroke: 0.35pt + grid-col)
    content((X(v), -0.12), anchor: "north", T(size: 7pt, fill: muted, fx(v, 1)))
  }
  for (i, n) in names.enumerate() {
    let yc = h - (i + 0.5) * rh - 0.05
    rect((0, yc - 0.17), (X(lqi(n)), yc + 0.17), fill: lc(n), stroke: none, radius: (east: 2pt))
    content((-0.15, yc), anchor: "east", M(n))
    content((X(lqi(n)) + 0.1, yc), anchor: "west", T(weight: "bold", fx(lqi(n), 3)))
  }
  line((0, 0), (0, h), stroke: 0.7pt + ink)
  content((w / 2, -0.55), anchor: "north", T(size: 7.6pt)[Level Quality Index, LQI (0 to 1)])
})

// ---------------------------------------------------------------------------
// Section 4.3: the five pillars
// ---------------------------------------------------------------------------
#let fig-pillars() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 15.4
  let h = 4.6
  let Y(v) = v * h
  let gw = w / 5
  frame(w, h, (), (0, 0.2, 0.4, 0.6, 0.8, 1), [], [pillar rating (0 to 1)], ypos: Y, yfmt: v => fx(v, 1), ylabel-dx: 0.85)
  let bw = 0.42
  let gap = 0.05
  for p in range(5) {
    let cx = (p + 0.5) * gw
    let x0 = cx - (5 * bw + 4 * gap) / 2
    for (i, n) in level-order.enumerate() {
      let v = pillars(n).at(p)
      let x = x0 + i * (bw + gap)
      rect((x, 0), (x + bw, calc.max(Y(v), 0.02)), fill: lc(n), stroke: none)
      if v < 0.1 {
        content((x + bw / 2, Y(v) + 0.05), anchor: "south", T(size: 6.4pt, fx(v, 3)))
      }
    }
    content((cx, -0.15), anchor: "north", B(size: 7.6pt, fill: navy, pillar-names.at(p)))
  }
  level-legend(0.3, h + 0.4, w - 0.3, chips: true)
})

// ---------------------------------------------------------------------------
// Section 4.6: information versus hit number, and cascade survival
// ---------------------------------------------------------------------------
#let fig-mi-k() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 14.2
  let h = 5.0
  let X(k) = (k - 1) / 14 * w
  let Y(v) = v / 5 * h
  // shaded AUC of ribbon_waves
  let rw = st("ribbon_waves").skill_horizon.scored_horizon_mi
  let area = ((X(1), 0),) + rw.enumerate().map(((i, v)) => (X(i + 1), Y(v))) + ((X(15), 0),)
  line(..area, close: true, fill: lc("ribbon_waves").lighten(85%), stroke: none)
  frame(w, h, range(1, 16), range(0, 6), [hit number $k$ (the $k$-th scored peg)], [mutual information $I_2 (A; Y_k)$ (bits)],
    xpos: X, ypos: Y, ylabel-dx: 0.7)
  content((X(11), Y(2.45)), box(fill: white.transparentize(20%), inset: 2pt, T(fill: lc("ribbon_waves").darken(25%), weight: "bold")[#M(weight: "bold", fill: lc("ribbon_waves").darken(25%), "ribbon_waves"): AUC = #fx(st("ribbon_waves").skill_horizon.auc_scored_mi_bits, 2) bits]))
  for n in level-order {
    let v = st(n).skill_horizon.scored_horizon_mi
    series(v.enumerate().map(((i, y)) => (X(i + 1), Y(y))), n)
  }
  level-legend(0.2, h + 0.45, w - 0.2)
})

#let fig-alpha() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 14.2
  let h = 4.2
  let X(k) = (k - 1) / 14 * w
  let Y(v) = v * h
  frame(w, h, range(1, 16), (0, 0.2, 0.4, 0.6, 0.8, 1), [hit number $k$], [fraction of shots with $>= k$ scored pegs],
    xpos: X, ypos: Y, yfmt: v => fx(v, 1), ylabel-dx: 0.85)
  for n in level-order {
    let v = st(n).skill_horizon.scored_active_frac
    series(v.enumerate().map(((i, y)) => (X(i + 1), Y(y))), n)
  }
  level-legend(0.2, h + 0.45, w - 0.2)
})

// ---------------------------------------------------------------------------
// Section 4.7: route mutual information against aim noise
// ---------------------------------------------------------------------------
#let fig-mi-sigma() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 11.0
  let h = 4.6
  let sig = (1, 2, 5, 10, 20)
  let X(s) = calc.ln(s) / calc.ln(20) * w
  let Y(v) = v / 6 * h
  frame(w, h, sig, range(0, 7), [aim noise $sigma$ (steps of 0.1°, log scale)], [route mutual information (bits)],
    xpos: X, ypos: Y, ylabel-dx: 0.7)
  // highlight the sigma used by the LQI
  line((X(2), 0), (X(2), h), stroke: (paint: navy, thickness: 0.8pt, dash: "dashed"))
  content((X(2) + 0.08, h - 0.05), anchor: "north-west", T(size: 7pt, fill: navy)[σ = 2 (used by the LQI)])
  for n in level-order {
    let v = sig.map(s => st(n).info_by_sigma.at(str(s)).route.MI)
    series(sig.zip(v).map(((s, y)) => (X(s), Y(y))), n)
  }
  // direct labels at sigma = 20, spread to avoid overlaps
  let ends = level-order.map(n => (n, st(n).info_by_sigma.at("20").route.MI)).sorted(key: e => e.at(1))
  let prev = -1
  for (n, v) in ends {
    let y = calc.max(Y(v), prev + 0.3)
    prev = y
    content((w + 0.25, y), anchor: "west", M(fill: ink)[#n #T(size: 7pt, fill: muted, fx(v, 2))])
    line((w + 0.05, Y(v)), (w + 0.22, y), stroke: 0.4pt + muted)
  }
})

// ---------------------------------------------------------------------------
// Section 4.8: mean match length
// ---------------------------------------------------------------------------
#let fig-match-length() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let w = 11.5
  let rh = 0.58
  let n-l = level-order.len()
  let h = n-l * rh + 0.1
  let X(t) = t / 20 * w
  rect((X(9), 0), (X(13), h + 0.05), fill: rgb("#dcfce7"), stroke: none)
  content((X(11), h + 0.08), anchor: "south", T(size: 7pt, fill: rgb("#15803d"), weight: "bold")[pacing sweet spot (peak 10.5)])
  for v in range(0, 21, step: 2) {
    line((X(v), 0), (X(v), h), stroke: 0.35pt + grid-col)
    content((X(v), -0.12), anchor: "north", T(size: 7pt, fill: muted, str(v)))
  }
  line((X(10.5), 0), (X(10.5), h + 0.05), stroke: (paint: rgb("#15803d"), thickness: 0.9pt, dash: "dashed"))
  for (i, n) in level-order.enumerate() {
    let yc = h - (i + 0.5) * rh - 0.05
    let t = match(n).mean_turns
    let pace = if t < 2 { 0 } else { calc.clamp(1 - calc.abs(t - 10.5) / 9.5, 0, 1) }
    rect((0, yc - 0.18), (X(t), yc + 0.18), fill: lc(n), stroke: none, radius: (east: 2pt))
    content((-0.15, yc), anchor: "east", M(n))
    content((X(t) + 0.1, yc), anchor: "west", box(fill: white.transparentize(15%), inset: 1pt, T[#text(weight: "bold", fx(t, 1)) turns #text(fill: muted)[· pacing #fx(pace, 2)]]))
  }
  line((0, 0), (0, h), stroke: 0.7pt + ink)
  content((w / 2, -0.55), anchor: "north", T(size: 7.6pt)[mean match length (turns)])
})
