// ============================================================================
// How Good Is a Peggle Level? A Guided Tour of the Level Evaluation Model
// Typst version of report/report.md (2026-11-10).
// Compile from the repository root (the figures read the profile JSON and
// the level files, so the root must be the repository):
//   typst compile --root . report/report.typ report/report.pdf
// Helpers: report/theme.typ, report/figures.typ
// ============================================================================

#import "theme.typ": *
#import "figures.typ": *

#let doc-title = "How Good Is a Peggle Level?"
#let doc-sub = "A Guided Tour of the Level Evaluation Model"

#set document(
  title: doc-title + " " + doc-sub,
  author: "Peggle Evolved, Julia port",
  date: datetime(year: 2026, month: 11, day: 10),
)

// ---------------------------------------------------------------------------
// Page, text, headings
// ---------------------------------------------------------------------------
#set page(
  paper: "a4",
  margin: (left: 2.2cm, right: 2.2cm, top: 2.4cm, bottom: 2.2cm),
  header: context {
    let p = here().page()
    if p > 1 {
      let top-start = query(heading.where(level: 1)).filter(h => h.location().page() == p and h.location().position().y < 6cm)
      let before = query(heading.where(level: 1).before(here()))
      let cur = if top-start.len() > 0 { top-start.first() } else if before.len() > 0 { before.last() } else { none }
      set text(font: f-sans, size: 7.6pt, fill: muted)
      grid(
        columns: (1fr, auto),
        [How Good Is a Peggle Level?],
        if cur != none and cur.numbering != none {
          [#numbering(cur.numbering, ..counter(heading).at(cur.location())) #h(4pt) #cur.body]
        } else if cur != none { cur.body },
      )
      v(-5pt)
      line(length: 100%, stroke: 0.4pt + hair)
    }
  },
  footer: context {
    let p = here().page()
    if p > 1 {
      set text(font: f-sans, size: 7.6pt, fill: muted)
      grid(
        columns: (1fr, auto),
        [2026-11-10 · Level evaluation model · Peggle Evolved],
        [#p / #counter(page).final().first()],
      )
    }
  },
)

#set text(font: f-serif, size: 10.6pt, fill: ink, lang: "en")
#set par(justify: true, leading: 0.6em, spacing: 0.95em)
#set list(indent: 0.4em, body-indent: 0.5em, marker: text(fill: navy)[•])
#set enum(indent: 0.4em, body-indent: 0.5em, numbering: n => text(font: f-sans, size: 8.6pt, weight: "bold", fill: navy)[#n.])
#show: code-style
#show link: set text(fill: navy)
#show math.equation.where(block: true): set block(above: 0.9em, below: 0.9em)
#show math.equation.where(block: true): it => block(width: 100%, fill: paper-tint, inset: (y: 6pt), radius: 2pt, it)

// "Section 4.3" in the text links to the heading.
#show regex("Sections? \d+(\.\d+)?"): it => {
  let num = it.text.split(" ").last()
  let lbl = std.label("sec-" + num.replace(".", "-"))
  link(lbl, it)
}

// Heading numbers follow the Markdown: sections start at 0.
#let main-num(..n) = {
  let a = n.pos()
  let first = str(a.at(0) - 1)
  if a.len() == 1 { first } else { first + "." + a.slice(1).map(str).join(".") }
}
#set heading(numbering: main-num)

#show heading.where(level: 1): it => {
  let new-page = it.has("label") and (it.label in (<sec-0>, <sec-6>))
  if new-page { pagebreak(weak: true); v(0.1cm) } else { v(1.6em, weak: true) }
  block(below: 1.1em, width: 100%, sticky: true, {
    set text(font: f-sans, fill: navy)
    if it.numbering != none {
      text(size: 9pt, weight: "bold", fill: muted, tracking: 1pt)[SECTION]
      linebreak()
      text(size: 18pt, weight: "bold")[#counter(heading).display(it.numbering) #h(0.35em) #it.body]
    } else {
      text(size: 18pt, weight: "bold", it.body)
    }
    v(-0.45em)
    line(length: 100%, stroke: 1.2pt + navy)
  })
}
#show heading.where(level: 2): it => block(above: 1.5em, below: 0.75em, sticky: true, {
  set text(font: f-sans, size: 11.6pt, weight: "bold", fill: navy)
  if it.numbering != none {
    box(width: 2.6em, counter(heading).display(it.numbering))
  }
  it.body
})

// Reference groups in Section 7.
#let refgroup(body) = block(above: 1.1em, below: 0.6em, sticky: true, text(font: f-sans, size: 9.4pt, weight: "bold", fill: navy, body))

// Figures
#set figure(gap: 0.8em)
#show figure: set block(breakable: false, above: 1.2em, below: 1.4em)
#show figure: set par(justify: false)
#show figure: set text(hyphenate: false)
#show figure.caption: it => {
  set text(font: f-sans, size: 8.4pt, fill: ink)
  set par(justify: false, leading: 0.5em)
  block(width: 92%, align(left, [#text(weight: "bold", fill: navy)[#it.supplement #context it.counter.display(it.numbering).] #it.body]))
}

// ---------------------------------------------------------------------------
// Title page
// ---------------------------------------------------------------------------
#page(margin: (left: 2.2cm, right: 2.2cm, top: 2.2cm, bottom: 2cm))[
  #set par(justify: false)
  #block(width: 100%, inset: (bottom: 0.4cm), stroke: (bottom: 2pt + navy))[
    #text(font: f-sans, size: 9pt, weight: "bold", fill: muted, tracking: 1.2pt)[PEGGLE EVOLVED · LEVEL EVALUATION MODEL]
    #v(0.35cm)
    #text(font: f-sans, size: 26pt, weight: "bold", fill: navy)[#doc-title]
    #v(0.1cm)
    #text(font: f-sans, size: 15pt, fill: ink)[#doc-sub]
  ]
  #v(0.3cm)
  #grid(
    columns: (auto, 1fr),
    column-gutter: 10pt,
    row-gutter: 6pt,
    text(font: f-sans, size: 8.5pt, weight: "bold", fill: muted)[DATE],
    text(size: 10.5pt)[2026-11-10],
    text(font: f-sans, size: 8.5pt, weight: "bold", fill: muted)[SCOPE],
    text(size: 10.5pt)[The five-pillar level evaluation model for Peggle Evolved, its profiler `scripts/profile_level.jl`, and the measured profiles of five levels.],
    text(font: f-sans, size: 8.5pt, weight: "bold", fill: muted)[DATA],
    text(size: 10.5pt)[`results/analysis/level_evaluation_profiles.json`. Every chart in this PDF reads its numbers from this file.],
    text(font: f-sans, size: 8.5pt, weight: "bold", fill: muted)[SOURCE],
    text(size: 10.5pt)[`report/report.md`],
  )
  #v(0.5cm)
  #block(width: 100%, fill: paper-tint, stroke: (left: 3pt + navy), inset: (x: 12pt, y: 10pt), radius: (right: 3pt))[
    #text(font: f-sans, size: 8pt, weight: "bold", fill: navy, tracking: 0.8pt)[THE QUESTION]
    #v(-0.3em)
    #set text(size: 10.6pt)
    The model answers one question: *how good is a level, and why?* It gives a level one number between 0 and 1, the Level Quality Index (LQI), and splits "good" into five separate parts, the five pillars.
  ]
  #v(0.5cm)
  #text(font: f-sans, size: 10.5pt, weight: "bold", fill: navy)[The five measured levels]
  #v(0.1cm)
  #align(center, fig-thumbnails())
  #v(0.5cm)
  #text(font: f-sans, size: 10.5pt, weight: "bold", fill: navy)[Their LQI]
  #v(0.1cm)
  #align(center, fig-lqi())
  #v(1fr)
  #text(font: f-sans, size: 7.8pt, fill: muted)[Julia port of Peggle Evolved · profiler `scripts/profile_level.jl` · figures drawn from the profile file and the level files]
]

// ---------------------------------------------------------------------------
// Contents
// ---------------------------------------------------------------------------
#block(below: 1.2em, width: 100%, {
  text(font: f-sans, size: 18pt, weight: "bold", fill: navy)[Contents]
  v(-0.45em)
  line(length: 100%, stroke: 1.2pt + navy)
})
#[
  #show outline.entry.where(level: 1): it => {
    v(0.6em)
    text(font: f-sans, weight: "bold", fill: navy, it)
  }
  #set outline.entry(fill: repeat(text(fill: hair)[.], gap: 2pt))
  #set text(size: 9.6pt)
  #columns(2, gutter: 1.1cm, {
    outline(title: none, depth: 2, indent: 1.4em)
    v(1.4em)
    visual-key()
  })
]

= About this report <sec-0>

== What this report is <sec-0-1>

An earlier work session built a mathematical model that gives a Peggle level a number between 0 and 1. The number is the #gl("level-quality-index-lqi")[#strong[Level Quality Index (LQI)]]. A Julia script computes it from thousands of simulated shots and a few simulated 1v1 matches.

The model borrows ideas from six fields: information theory, chaos theory, the study of skill and luck, game theory, compression, and search-based level generation. The original notes are correct but dense. They assume that you know all six fields already.

This report explains the same model from the start. It adds no new results. Every number comes from `results/analysis/level_evaluation_profiles.json` or from the code in `scripts/profile_level.jl`.

== The question <sec-0-2>

The model answers one question: #strong[how good is a level, and why?]

The "why" part matters more than the number. The model splits "good" into five separate parts, #gl("pillar")[the five pillars]. If a level scores badly, the pillars tell you where the problem is. For example, a level can give the player good control of the ball but give the ball nothing interesting to do.

== How to read this report <sec-0-3>

Read Section 1 if you do not know how Peggle Evolved plays. Read Section 2 next. It introduces each mathematical tool with a picture in your head first, then a Peggle example, then the formula. You can skip a formula and still follow the rest. Sections 3 and 4 use the tools from Section 2. Section 6 is a glossary. If a word confuses you, look there.

#tbl(columns: (58.0fr, 9.0fr,), align: (left, left,),
  [If you want to know], [Read],
  [How a shot and a 1v1 match work], [Section 1],
  [What entropy, mutual information and the other tools mean], [Section 2],
  [How the model turns simulations into one number], [Section 3],
  [What the model says about the five real levels], [Section 4],
  [What the model does not see, and which numbers are guesses], [Section 5],
  [A short meaning for each special term], [Section 6],
  [The papers behind the ideas], [Section 7],
)

== Labels in this report <sec-0-4>

Some claims come from measurement. Others come from a choice that a person made. The report marks the difference with these labels:

- #strong[#tag("MEASURED")]: the profiler computed this number from simulations.
- #strong[#tag("CODE")]: the code does this. The label points to how, not to a measured result.
- #strong[#tag("HAND-SET")]: a person chose this number, for example a weight or a target. No measurement fixed it.
- #strong[#tag("THEORY")]: the idea comes from a paper or from physics. The profiler does not measure it directly.
- #strong[#tag("PROPOSED")]: the notes describe this, but the code does not use it yet.

== Words in this report <sec-0-5>

The report uses each word with one meaning:

- #strong[level]: the design. The list of pegs, shapes and lines, as an artist made it.
- #strong[board]: the pegs that are still on screen at one moment of a match. The board changes as players clear pegs.
- #strong[shot]: one launch of the ball, until every ball has left the screen.
- #gl("aim-index")[#strong[aim index]]: a whole number from 0 to 1800 that selects the launch angle. One step is 0.1°.
- #strong[points]: the in-game score that a player earns.
- #strong[rating]: a number from 0 to 1 that the model gives. Pillar ratings and the LQI are ratings.
- #strong[metric]: one measured quantity, for example "mean pegs hit per shot".
- #gl("outcome-label")[#strong[outcome]]: a short label that describes what a shot did. Section 2 explains the different outcome labels.
- #gl("bot")[#strong[bot]]: a computer player. Its #strong[policy] is the rule that it uses to select a shot.

= The game in five minutes <sec-1>

== One shot <sec-1-1>

A launcher sits at the top center of the screen. The player selects an angle and fires one ball. Gravity pulls the ball down. The ball bounces off pegs and walls. Each peg that the ball touches lights up and gives points. When the ball leaves the bottom of the screen, the shot ends. The game then removes the lit pegs.

The game has 1801 possible angles. They cover 180°, so neighbouring angles differ by 0.1°. The model calls each angle an #strong[aim index], from 0 to 1800.

#intuition[0.1° is very small. On a 1200-pixel-wide screen, it moves the ball about 1 to 2 pixels after its first 1000 pixels of flight. A human cannot aim this precisely. This fact is the reason that the model adds "aim noise" in Section 2.3.]

== Pegs and slides <sec-1-2>

Pegs have colors:

- #strong[Red] pegs are the targets. They are worth 100 points each. When all red pegs are gone, the match ends.
- #strong[Blue] pegs are worth 10 points.
- #strong[Green] pegs spawn extra balls.
- #strong[Purple] pegs are worth 500 points.

Pegs also have shapes: circles, rectangles and #gl("annular-peg")[#strong[annular]] pegs. An annular peg is a short piece of a curved band.

Pegs can belong to a #strong[line]. If the line has no gap between its pegs, the ball can roll along it. The game calls this a #gl("slide")[#strong[slide]]. In the model, a slide is also called a #strong[waveguide], a word from physics for a channel that guides a wave. Section 2.6 explains why that word fits.

== Points <sec-1-3>

The points for one shot grow faster than the number of pegs. The game adds the value of each peg, multiplies by a red-peg multiplier, and then multiplies by the number of pegs hit. So a shot that hits twice as many pegs gives about four times the points.

The #gl("multiplier")[#strong[multiplier]] rises as the players clear more red pegs. When all red pegs are gone, the multiplier is ×100. This is called #gl("fever")[#strong[fever]].

The game also gives #gl("style-shot")[#strong[style]] bonuses. Examples are a long slide along a line, a "long shot" across the screen, or an "off the wall" bounce. The model tracks six styles: `slide`, `long_shot`, `super_long_shot`, `double_long_shot`, `off_the_wall` and `lucky_bounce`.

A #gl("bucket")[#strong[bucket]] moves left and right at the bottom. If the ball falls into it, the player gets bonus points.

== The 1v1 match <sec-1-4>

The model studies the 1v1 mode. Two players share one board and take turns. Each player starts with 10 balls. Two rules make this mode tactical:

+ #gl("red-peg-penalty")[#strong[The red-peg penalty.]] If a shot hits no red peg, the shot earns nothing. Also, the player loses 25% of the points in the bank.
+ #strong[The shared bucket.] Each bucket catch is worth more than the last one: 2,500 points, then 5,000, then 7,500, and so on.

The match ends when all red pegs are gone, or when both players have no balls left.

== The five levels <sec-1-5>

The profiler measured five levels. They are very different, which makes them a good test set.

#tbl(columns: (auto, 70.0fr, auto, auto, auto,), align: (left, left, right, right, right,),
  [Level], [Short description], [Pegs], [Red pegs], [Slide fraction],
  [#lv("ribbon_waves")], [5 curved slide ribbons plus 53 circle pegs. The team considers it an enjoyable reference level.], [133], [25], [0.60],
  [#lv("mustache")], [3 identical, mirror-symmetric "mustache" shapes, stacked vertically.], [99], [16], [0.73],
  [#lv("circle_level")], [25 circle pegs and no slides. A small grid.], [25], [10], [0.00],
  [#lv("squiggly_circle")], [192 annular pegs in one closed, wavy ring.], [192], [10], [1.00],
  [#lv("slide")], [3 slides. A test level for style shots. It has no red pegs.], [73], [0], [0.99],
)

#figure(fig-thumbnails(), caption: [The five levels, drawn from their level files. Each panel shows the full play field at the same height. Yellow pegs sit on a slide, blue pegs do not. The level files of four of these levels do not fix which pegs are red, so the panels do not show peg colours.]) <fig-thumbnails>

= The toolbox <sec-2>

This section introduces each tool before the model uses it. Each part has the same order: the intuition, a Peggle example, and then the formula. Every symbol in a formula has a plain explanation under it.

== Probability and bits <sec-2-1>

A #strong[probability] is a number from 0 to 1 that says how often something happens. If 450 of the 1801 aim indices hit a red peg, the probability that a random aim hits red is $450 \/ 1801 approx 0.25$.

A #gl("bit")[#strong[bit]] is a unit of information. One bit is the answer to one fair yes-or-no question. If you must guess a number from 1 to 8, you need three yes-or-no questions. So the answer holds 3 bits. In general, a choice among $n$ equal options holds $log_2 n$ bits.

#example[Selecting one aim index out of 1801 holds $log_2 1801 approx 10.8$ bits. This is the most information that one shot can carry.]

== Entropy: how many different things can happen? <sec-2-2>

#strong[Intuition.] #gl("entropy")[Entropy] measures surprise, or variety. A coin that always lands on heads has zero entropy. You learn nothing from a throw. A fair coin has 1 bit. A fair six-sided die has about 2.6 bits.

#strong[Peggle example.] Fire a shot at every one of the 1801 aim indices. Write down which set of pegs each shot hits. On `ribbon_waves`, 1797 of the 1801 shots hit a different set of pegs. The entropy of the hit set is 10.81 bits. This is almost the maximum of 10.81 bits from Section 2.1. Nearly every angle gives its own result. #tag("MEASURED")

#strong[Formula.] The Shannon entropy of an outcome $O$ is

$ H(O) = -sum_o P(o) thin log_2 P(o) $

- $O$ is the outcome of a shot. It is a label, for example "hit pegs 4, 7 and 12".
- $o$ is one possible value of that label.
- $P(o)$ is the fraction of shots that give the value $o$.
- The sum goes over all values that occur. The minus sign makes the result positive.
- The unit is bits, because the logarithm has base 2.

#watchout[High entropy alone is not good. A pinball machine with random results also has high entropy. Variety is only half of the story. The other half is control, in Section 2.3.]

The paper behind this tool is Shannon (1948), #emph[A Mathematical Theory of Communication].

== Noisy aim and mutual information: how much does the player control? <sec-2-3>

#strong[The problem.] The simulator is exactly deterministic. The same aim index always gives the same shot, to the last bit. If the player could select the aim index perfectly, the aim would decide everything. Then every level would look "fully controllable", even a chaotic one. That answer is useless.

#strong[The fix.] Real players are not perfect. The model adds #gl("aim-noise")[#strong[aim noise]]. The player intends aim index $a$. The game fires a slightly different index $tilde(a)$, picked at random from the $2 sigma + 1$ neighbours around $a$. For example, with $sigma = 2$, the intended index 900 can become 898, 899, 900, 901 or 902, each with the same chance. One step is 0.1°, so $sigma = 2$ means $plus.minus 0.2 degree$.

#figure(fig-channel(), caption: [The noisy aim channel. The player intends aim $a$. The noise picks the fired aim $tilde(a)$ evenly from the $2 sigma + 1$ neighbours. The physics then decides the outcome with no randomness.]) <fig-channel>

Now we can ask a fair question. If I know what the player intended, how much do I know about the outcome?

#strong[Intuition.] Picture the five neighbours of an intended aim. If all five give the same outcome, the noise does not matter. The player is in control. If all five give different outcomes, the player cannot tell which one will happen. The result is luck.

#gl("mutual-information")[#strong[Mutual information]] measures this. It is the variety of outcomes, minus the confusion that the noise adds.

$ I_sigma (A;O) = H(O) - H_sigma (O mid(|) A) $

- $A$ is the intended aim index.
- $O$ is the outcome label.
- $H(O)$ is the entropy of the outcome over all shots, as in Section 2.2.
- $H_sigma (O mid(|) A)$ is the #gl("conditional-entropy")[#strong[conditional entropy]], also called #strong[equivocation]. It is the uncertainty that remains after you know the intended aim. The model computes it for each intended aim from its $2 sigma + 1$ neighbours, then takes the average.
- $sigma$ is the noise width in aim steps.
- $I_sigma (A;O)$ is in bits. It is the amount of outcome variety that the player really controls.

#example[With $sigma = 2$, an aim has 5 neighbours. If they give 5 different outcomes, the confusion for that aim is $log_2 5 approx 2.3$ bits. If they all give one outcome, the confusion is 0 bits.]

From mutual information, the model gets one more ratio, the #gl("controllability")[#strong[controllability]]:

$ cal(C)_sigma = frac(I_sigma (A;O), H(O)) $

It is a number from 0 to 1. It says what fraction of the variety is under the player's control. 1 means pure skill. 0 means pure luck.

The profiler computes these values for five noise widths: $sigma = 1, 2, 5, 10, 20$. The LQI uses $sigma = 2$. #tag("CODE")

== The outcome label: how detailed must it be? <sec-2-4>

Mutual information depends on what you call "the outcome". The model uses four labels. #tag("CODE")

- #strong[Hit set]: the exact set of pegs hit. This label is very fine. Two shots that share 14 of 15 pegs still count as different.
- #strong[Score tier]: the points of the shot, sorted into 16 brackets.
- #strong[Tactical label]: did the shot hit red, did it reach the bucket, which styles it earned, and roughly how many pegs it hit.
- #gl("route-label")[#strong[Route label]]: a coarse summary in five parts. Where on the screen the hit pegs are on average (a 4 × 4 grid). How many pegs, on a log scale from 0 to 5. Which quarter of the screen width the ball left from, or "bucket". Whether the shot earned any style. Whether it hit red.

The route label is the main one. It answers "where did the shot go, how much did it do, and was it useful", but it ignores single-peg details.

#strong[Why a coarse label?] This idea comes from the #gl("information-bottleneck")[#strong[information bottleneck]] of Tishby, Pereira and Bialek (2000). Their point is that a good summary keeps the information that matters and throws away the rest. For a player, "the ball went down the left ribbon and cleared a lot" matters. "It touched peg 87 and not peg 88" usually does not.

#keyidea[A fine label makes every level look chaotic. A coarse label makes every level look controllable. The route label sits between the two.]

== Empowerment: control for a smart player <sec-2-5>

#strong[Intuition.] Mutual information in Section 2.3 assumes that the player picks every aim index equally often. Real players do not. A good player avoids angles that do nothing and uses the angles that work. #gl("empowerment")[#strong[Empowerment]] is the control that the best possible choice of angles can reach.

#strong[Peggle example.] On `squiggly_circle`, 35% of aim indices hit no peg at all. A random player wastes many shots there. A smart player never aims there. Empowerment measures the control of that smart player.

#strong[Formula.]

$ frak(E)_sigma = max_(p(a)) I_sigma (A;O) $

- $p(a)$ is how often the player selects aim $a$. It is a probability distribution over the 1801 aim indices.
- $max_(p(a))$ means: try every possible way to distribute the aims, and keep the highest mutual information.
- $frak(E)_sigma$ is in bits.

In information theory, this maximum is the #gl("channel-capacity")[#strong[channel capacity]]. The profiler finds it with the #gl("blahut-arimoto-algorithm")[#strong[Blahut–Arimoto algorithm]]. The algorithm starts with equal weights on all aims. Then it repeats one step: it gives more weight to aims whose outcomes stand out from the average. The profiler does this step 25 times. #tag("CODE")

#watchout[25 rounds give a good estimate, not an exact answer. The code also takes the larger of this estimate and the plain mutual information, so empowerment is never lower than $I_sigma$.]

The papers are Salge, Glackin and Polani (2014), #emph[Empowerment — An Introduction], and two newer works: #emph[The Geometry of Empowerment] (2026) and #emph[Information-Theoretic Policy Pre-Training with Empowerment] (2025).

== Chaos and billiards: why some shots stay controllable longer <sec-2-6>

#strong[Intuition.] Push two balls on a pool table at almost the same angle. After one cushion, they are still close. On a table full of round posts, each post bends the two paths apart a bit more. After a few posts, the paths have nothing in common. This growth of small differences is #gl("chaos")[#strong[chaos]], or #strong[sensitivity to initial conditions].

#strong[The Lyapunov exponent.] Physicists measure this growth with the #gl("lyapunov-exponent")[#strong[Lyapunov exponent]] $lambda$. If two paths start a tiny distance $delta_0$ apart, after $k$ bounces they are about

$ delta_k approx delta_0 thin e^(lambda k) $

apart.

- $delta_0$ is the starting difference, for example 0.1° of aim.
- $k$ is the number of bounces.
- $lambda$ is the average growth rate per bounce. If $lambda > 0$, small errors grow fast. If $lambda < 0$, nearby paths come together.

#strong[Round pegs spread paths apart.] A round peg acts like a convex mirror. It makes a narrow beam of paths wider. The earlier notes estimate, from billiard theory, that one bounce off an isolated round peg makes an aim error about 14 times bigger. After three such bounces, a 0.1° error grows past 180°. The aim is forgotten. A grid of round pegs is called a #gl("galton-board")[#strong[Galton board]], after the classic toy where balls fall through pins. #tag("THEORY")

#strong[Slides bring paths together.] A slide is different. When the ball lands on a slide, it loses most of its bounce and rolls along the line. Two balls that land on the same slide at slightly different points leave at almost the same place and speed. The slide "forgets" the small error, but it keeps the big decision: which slide the player hit. This is why the model calls slides waveguides. #tag("THEORY")

#figure(fig-paths(), caption: [Round pegs: $lambda > 0$. Slides: $lambda < 0$. A schematic, not simulated paths.]) <fig-paths>

#keyidea[A good level mixes both. Round pegs create branching and excitement. Slides carry the ball far without losing the player's intent.]

#strong[How the profiler sees this.] The profiler does not compute a Lyapunov exponent. Instead, it asks the information question at each step of the shot. It takes the first peg hit, the second, up to the fifteenth. For each position $k$, it computes the mutual information between the intended aim and the #box[$k$-th] peg. This gives a curve: #strong[information versus hit number]. Section 3.4 uses it.

The papers are #emph[Estimating Lyapunov Exponents in Billiards] (2019), #emph[Dynamics of the No-Slip Galton Board] (2022), and van Beijeren, Dorfman, Posch and Dellago (2004) on the Lorentz gas, which is a model of a particle among fixed round scatterers.

== Skill versus luck <sec-2-7>

#strong[Intuition.] In chess, the better player almost always wins. In a coin toss, skill does not matter. Most games sit between the two. One way to place a game on this line is simple: let a stronger player meet a weaker one many times. Count how often the stronger one wins.

#strong[Peggle example.] The profiler uses three bots:

- A #gl("sector")[#strong[sector bot]] with fine aim ($plus.minus 1$ step). It splits the 1801 aims into blocks of 100, finds the best shot in each block, and picks among the better half of the blocks.
- A #strong[sloppy] sector bot with $plus.minus 10$ steps of aim noise ($plus.minus 1 degree$). Same rule, worse hands.
- A #strong[random] bot. It fires at a random angle.

Fine aim against sloppy aim tests #strong[motor skill]. The sector bot against the random bot tests #strong[decision skill]. If the better bot wins almost every time, the level rewards skill. #tag("CODE")

A fourth bot, the #strong[tactical bot], uses the expected value of Section 2.8. The profiler records its win rate against the sector bot, but the LQI does not use this number. #tag("CODE")

The papers are Jerdee and Newman (2023), #emph[Luck, skill, and depth of competition in games and social hierarchies], and #emph[Quantifying Skill and Chance: A Unified Framework for the Geometry of Games] (2025).

== Game theory ideas used in 1v1 <sec-2-8>

The model uses only a few game theory ideas. Each one is simple.

#strong[Expected value with a penalty.] Each aim is like a lottery ticket. It hits red with some probability, and then it gives some points. If it misses red, the player loses 25% of the bank. The tactical bot computes, for each aim $a$:

$ U(a mid(|) B) = "average over the neighbours " tilde(a) " of " cases(S(tilde(a)) & "if " tilde(a) " hits red", -floor(0.25 thin B) & "if not") $

- $B$ is the player's banked points before the shot.
- $S(tilde(a))$ is the points of the fired aim.
- $floor(dot.op)$ means "round down".
- The neighbours are the $2 epsilon + 1$ aims that the noise can produce, where $epsilon$ is the bot's noise width.

#example[Two shots. The safe shot hits red 95% of the time and gives 5,000 points. The risky shot hits red 60% of the time and gives 15,000 points. With an empty bank, the safe shot is worth $0.95 times 5000 = 4750$ and the risky one $0.60 times 15000 = 9000$. Go risky. With 100,000 points in the bank, a miss costs 25,000. Now the safe shot is worth $4750 - 0.05 times 25000 = 3500$, and the risky shot $9000 - 0.40 times 25000 = -1000$. Go safe.]

So the best shot depends on the score. A good 1v1 level offers both kinds of shot, in many parts of the screen.

#strong[Win-probability belief.] During a match, you can ask "what is the chance that Player 1 wins now?" Call this $p_t$ after turn $t$. The model estimates it from the score gap with an S-shaped curve, the #gl("logistic-function")[#strong[logistic function]]:

$ p_t = frac(1, 1 + e^(-(B_(1,t) - B_(2,t)) \/ S_"scale")) $

- $B_(1,t)$ and $B_(2,t)$ are the banked points of Player 1 and Player 2 after turn $t$.
- $S_"scale"$ is a "large swing" size: one quarter of the median total points of a match, and at least 2,500. #tag("HAND-SET")
- At the start, $p_0 = 0.5$. At the end, $p_T$ is 1 if Player 1 won, 0 if Player 2 won, 0.5 for a tie.

#example[A gap of zero gives $p = 0.5$. A gap of one $S_"scale"$ gives $p approx 0.73$. A gap of two gives $p approx 0.88$.]

#strong[Suspense and surprise.] Ely, Frankel and Kamenica (2015) define two kinds of entertainment from this belief curve. #gl("surprise")[#strong[Surprise]] is how much the belief jumps after each turn. #gl("suspense")[#strong[Suspense]] is how much it is expected to jump before each turn. A match where $p_t$ stays near 0.5 and moves a lot is exciting. A match where one player leads from the start is not.

The profiler computes surprise as the average size of the jumps, and suspense as the root-mean-square size of the jumps. Root-mean-square counts big jumps more than small jumps.

$ "surprise" = frac(1, T) sum_(t=1)^T abs(p_t - p_(t-1)), wide "suspense" = sqrt(frac(1, T) sum_(t=1)^T (p_t - p_(t-1))^2) $

- $T$ is the number of turns in the match.
- The profiler averages each value over all simulated matches.

#watchout[In the original paper, suspense looks forward: it is the expected size of the next jump, before the shot. The profiler uses the jumps that really happened. This is a practical stand-in, not the exact definition. Also, $p_t$ is a rule of thumb. Nobody fitted it to real match results. #tag("CODE")]

#figure(fig-belief(), caption: [Schematic, not data. Two belief curves $p_t$ over 10 turns. The arrows on curve A are the turn-to-turn jumps.]) <fig-belief>

#strong[Drama and fairness.] Browne and Maire (2010) proposed ways to score board games automatically. The model takes three ideas from them:

- #strong[Lead changes]: how often the leader switches during a match.
- #gl("comeback-win-rate")[#strong[Comebacks]]: how often the winner was behind at some point by more than 5% of the leader's points.
- #gl("first-player-balance")[#strong[First-player balance]]: does Player 1 win too often? The model computes

$ cal(B) = 1 - 2 thin abs(W_(P 1) - 0.5) $

where $W_(P 1)$ is the fraction of matches that Player 1 wins (a tie counts as half). If Player 1 wins half the time, $cal(B) = 1$. If Player 1 always wins, $cal(B) = 0$.

== Compression and MDL: elegant levels are short to describe <sec-2-9>

#strong[Intuition.] Compare two descriptions. "Put a peg at (100, 200), a peg at (110, 205), a peg at (120, 212) …" for 80 pegs. Or: "draw a sine wave from here to there and put 80 pegs on it". Both make the same level. The second one is much shorter. The #gl("minimum-description-length-mdl")[#strong[Minimum Description Length (MDL)]] principle says that the shortest description captures the real structure.

#strong[Peggle example.] The model counts a rough number of "free numbers" that you need to describe a level. A line or curve costs about 6 numbers. A loose peg costs 2 numbers, its x and y. #tag("HAND-SET")

$ K_"geom" = 6 dot.op L_"lines" + 2 dot.op N_"free" $

- $L_"lines"$ is the number of distinct lines in the level.
- $N_"free"$ is the number of pegs that are not part of a slide.
- $K_"geom"$ is the description length, counted in numbers.

#example[`ribbon_waves` has 5 lines and 53 loose pegs. So $K_"geom" = 6 times 5 + 2 times 53 = 136$. `squiggly_circle` is one ring of 192 pegs, so $K_"geom" = 6$.]

The model then asks: how much controlled behavior does the level give per unit of description? A level that does a lot with a simple shape is "elegant". Section 3.7 gives the formula.

The source is the information-theory notes of the project. The MDL idea itself is standard in information theory.

== Three small statistics tools <sec-2-10>

The model uses three more tools. They are short.

#gl("gini-coefficient")[#strong[Gini coefficient: are the pegs used equally?]] The Gini coefficient measures inequality. It comes from economics, where it measures how unequally a country shares its income. A value of 0 means every peg is hit equally often. A value near 1 means a few pegs get almost all hits and the rest are never touched.

$ G = frac(sum_i sum_j abs(pi_i - pi_j), 2 N sum_i pi_i) $

- $pi_i$ is the fraction of the 1801 shots that hit peg $i$.
- $N$ is the number of pegs.
- The top sums all differences between pairs of pegs.

#strong[Perplexity: how many good options are there, really?] Suppose a screen has 19 regions, and each region has a best shot. If all best shots are equally good, a player has 19 real options. If one region is far better than the rest, the player has about 1 real option. #gl("perplexity")[#strong[Perplexity]] turns this into one number: $2^H$, where $H$ is the entropy of the shares. It is the "effective number" of options.

#gl("jaccard-distance")[#strong[Jaccard distance: how different are two shots?]] Take the sets of pegs that two shots hit. The Jaccard distance is

$ d_J = 1 - frac("number of pegs in both sets", "number of pegs in either set") $

0 means the same pegs. 1 means no pegs in common.

== Search-based level generation and MAP-Elites <sec-2-11>

#strong[Intuition.] The long-term plan is to let the computer design levels. A simple way is to generate many levels, score each one, and keep the best. Togelius, Yannakakis, Stanley and Browne (2011) call this #strong[search-based procedural content generation]. The score function is the key part. The LQI is meant to be that score.

#strong[The problem with one score.] If you only keep the single highest score, the search finds one kind of level and copies it forever. You get 1000 versions of `ribbon_waves`.

#gl("map-elites")[#strong[MAP-Elites]] fixes this. Mouret and Clune (2015) proposed it. You pick a few #strong[behaviour descriptors], for example "fraction of slide pegs" and "skill horizon". These form a grid, like a map. Each cell of the map holds the best level found so far with those features. The search fills the whole map. You get the best slide-heavy level, the best open-grid level, and so on. This family of methods is called #gl("quality-diversity")[#strong[quality-diversity]]. Gravina and co-authors (2019) apply it to level generation.

#figure(fig-mapelites(), caption: [MAP-Elites keeps the best level in each cell, not only the single best level. Illustration with the five measured levels, placed by slide fraction and skill horizon $k_(1\/2)$, with their LQI as the rating. The row edges are a choice for this picture. No code uses MAP-Elites yet.]) <fig-mapelites>

The model proposes a descriptor vector $bold(b)(L)$ for this: slide fraction, skill horizon, red-hit safety and a style profile. #tag("PROPOSED") No code uses MAP-Elites yet.

= The model <sec-3>

== The big picture <sec-3-1>

The model has three layers.

+ #strong[Three data tiers] collect raw facts. They differ in cost.
+ #strong[Five pillars] turn the facts into five ratings from 0 to 1.
+ #strong[One formula] combines the five ratings into the LQI.

#figure(fig-pipeline(), caption: [The three layers of the model: data tiers, pillars and the LQI. The tier times are estimates from the original notes.]) <fig-pipeline>

== The three data tiers <sec-3-2>

#strong[Tier 0: geometry only.] The profiler reads the level file. It runs no physics. It counts pegs by color and shape. It counts slide pegs and lines. It measures how spread out the pegs are, and how mirror-symmetric the level is. This takes less than a millisecond.

#strong[Tier 1: the full sweep.] The profiler fires one shot at every aim index, 1801 shots, from the starting board. For each shot it records:

- the order in which the ball scored pegs,
- the order of all bounces, on pegs, walls and the bucket,
- the points, the red pegs hit, the styles earned, and whether the bucket caught the ball,
- where the ball left the screen.

The original notes estimate 0.5 to 5 seconds per level for this tier. Pillars I, II and III come from this tier.

#strong[Tier 2: 1v1 matches.] The profiler plays full matches between bots. It plays 8 matches of sector bot against sector bot, both with fine aim. Then it plays a #strong[skill ladder]: 8 matches each for fine against sloppy, sector against random, and tactical against sector. In the ladder, the bots swap seats, so that each bot plays as Player 1 half of the time. Pillar IV comes from this tier. #tag("CODE")

== Pillar I: agency and control <sec-3-3>

#strong[The question.] When the player aims, does the aim matter?

#strong[Why it matters for fun.] Players enjoy a game when their choices change what happens. If the result is the same wherever you aim, or random wherever you aim, the aim is not a real choice.

#strong[What it combines.] The first three inputs use the route label at noise $sigma = 2$. #tag("CODE")

#tbl(columns: (3.2fr, 4fr, auto, auto,), align: (left, left, left, right,),
  [Input], [What it means], [Divide by #tag("HAND-SET")], [Weight #tag("HAND-SET")],
  [Mutual information $I_2 (A; O_"route")$], [Bits of control over the route], [4.2 bits], [0.35],
  [Controllability $cal(C)_2$], [Fraction of route variety under control], [0.80], [0.25],
  [Empowerment $frak(E)_2$], [Control for a smart player], [5.2 bits], [0.20],
  [#gl("active-aim-space")[Active aim space] $1 - f_"dead"$], [Fraction of aims that hit at least one peg], [1], [0.20],
)

"Divide by" means: the profiler divides the raw value by this target, then cuts the result to the range 0 to 1. A value at or above the target gets a full 1.

== Pillar II: skill horizon and dynamics <sec-3-4>

#strong[The question.] How far into a shot does the player's aim still matter?

#strong[Why it matters for fun.] In a good shot, the player plans a path: "hit the left ribbon, roll down, bounce into the middle". If the aim stops mattering after two pegs, the rest of the shot is a lottery. The player watches, but does not own the result.

#strong[The information curve.] For each hit number $k = 1, dots, 15$, the profiler computes $I_2 (A; Y_k)$. Here $Y_k$ is the #box[$k$-th] peg that the ball scored, or "none" if the shot scored fewer than $k$ pegs. #tag("CODE")

From this curve, the model takes:

- #gl("integrated-trajectory-agency")[#strong[Integrated trajectory agency]] ($"AUC"_"MI"$): the sum of the curve over $k = 1$ to 15. It is large only if shots are long #strong[and] the aim still decides the later pegs. The unit is bits.
- #gl("skill-horizon")[#strong[Skill horizon]] ($k_(1\/2)$): the hit number where the curve falls to half of its value at $k = 1$. It is like a half-life. If the curve never falls to half within 15 hits, the profiler reports 15.
- #gl("cascade-survival")[#strong[Deep cascade survival]] $alpha(10)$: the fraction of shots that score at least 10 pegs.

The model also looks at #strong[shot basins]. Walk along the aim indices from 0 to 1800. Compare each shot with its neighbour using the Jaccard distance on their first five pegs. If the distance is 0.40 or less, the two shots belong to the same basin. A basin of three or more aims is #gl("aimable-basin")[#strong[aimable]]: a player with $plus.minus 1$ step of noise stays inside it. A shorter basin is a #gl("knife-edge")[#strong[knife edge]].

#tbl(columns: (32.0fr, 20.0fr, auto,), align: (left, left, right,),
  [Input], [Divide by #tag("HAND-SET")], [Weight #tag("HAND-SET")],
  [$"AUC"_"MI"$ (scored pegs)], [60 bits], [0.40],
  [Deep cascade survival $alpha(10)$], [0.85], [0.25],
  [Skill horizon $k_(1\/2)$ (scored pegs)], [15 hits], [0.20],
  [Aimable basin fraction], [0.50], [0.15],
)

#intuition[Picture a flashlight beam. On a board of round pegs, the beam widens at every peg and soon lights everything. The aim is lost. On a board with slides, the beam is re-focused at each slide and stays narrow. The information curve measures the width of the beam, hit by hit.]

== Pillar III: the tactical landscape of one turn <sec-3-5>

#strong[The question.] When the player looks at the board, how many good options are there, and how varied are they?

#strong[Why it matters for fun.] A level with one obvious best shot is solved. A level with many good shots in different directions gives the player a real decision every turn.

#tbl(columns: (29.0fr, 70.0fr, auto, auto,), align: (left, left, right, right,),
  [Input], [What it means], [Divide by #tag("HAND-SET")], [Weight #tag("HAND-SET")],
  [Effective competitive sectors], [Perplexity of the best expected points per block of 100 aims. Section 2.10.], [18], [0.30],
  [Distinct first-hit pegs $N_"first"$], [How many different pegs a shot can hit first], [40], [0.25],
  [Style-shot rate $r_"style"$], [Fraction of aims that earn at least one style], [0.35], [0.25],
  [Peg equity $(1 - G_"peg") times min(1, N \/ 80)$], [Are pegs used equally? Small levels get less credit.], [1], [0.20],
)

"Expected points" here means the average over the three neighbour aims of a $plus.minus 1$-step bot, where a shot that misses red counts as zero. #tag("CODE")

A low $N_"first"$ points to #gl("shielding")[#strong[shielding]]: an outer layer of pegs blocks the launcher's view of everything behind it.

== Pillar IV: 1v1 drama, balance and skill <sec-3-6>

#strong[The question.] When two players play a full match on this level, is the match good?

#strong[Why it matters for fun.] A level can be beautiful for one shot and still give bad matches. Matches can be too short, too long, one-sided, or unfair to the second player.

#tbl(columns: (1.5fr, 2.2fr, 6fr, auto,), align: (left, left, left, right,),
  [Input], [What it means], [Formula or target #tag("HAND-SET")], [Weight #tag("HAND-SET")],
  [Pacing], [Mean match length in turns], [Peak at 10.5 turns. Falls linearly to 0 at 1 and at 20 turns. 0 if under 2 turns.], [0.25],
  [Completion], [Fraction of matches that end because all red pegs are gone], [Used as is], [0.15],
  [First-player balance $cal(B)$], [Section 2.8], [Used as is], [0.20],
  [Drama], [Lead changes, comebacks and suspense], [$display(0.4 dot.op frac("lead changes", 1.5) + 0.3 dot.op frac("comeback rate", 0.60) + 0.3 dot.op frac("suspense", 0.18))$, cut to 1], [0.20],
  [#gl("skill-gradient")[Skill gradient]], [Section 2.7], [$display(0.5 dot.op frac(W_"fine vs sloppy" - 0.5, 0.40) + 0.5 dot.op frac(W_"sector vs random" - 0.5, 0.50))$, cut to 1], [0.20],
)

A level with zero red pegs gets its Pillar IV rating multiplied by 0.05. Without red pegs, 1v1 does not work. #tag("CODE")

The skill gradient maps a 50% win rate (no skill effect) to 0. It maps 90% for fine aim, and 100% against the random bot, to the full 1.

== Pillar V: structural elegance <sec-3-7>

#strong[The question.] Is the level built from a good mix of parts, spread well over the screen, and simple for what it does?

#strong[Why it matters for fun.] This pillar is the least direct. It rewards designs that the billiard theory of Section 2.6 predicts to play well. It also rewards levels that are easy to read: a few clear shapes, not a cloud of random dots.

#gl("waveguide-scatterer-balance")[#strong[Waveguide–scatterer balance.]] Let $f_"slide"$ be the fraction of pegs that sit on a slide. Then

$ B_"wg" = 4 thin f_"slide" thin (1 - f_"slide") $

- If there are no slides ($f_"slide" = 0$), $B_"wg" = 0$.
- If everything is slides ($f_"slide" = 1$), $B_"wg" = 0$.
- At an even mix ($f_"slide" = 0.5$), $B_"wg" = 1$.

#figure(fig-hill(), caption: [The waveguide–scatterer balance $B_"wg" = 4 f (1 - f)$ and the five levels on the curve.]) <fig-hill>

#strong[Spatial entropy.] Split the screen into an 8 × 8 grid. Count the share of pegs in each cell. The entropy of these shares, divided by its maximum of 6 bits, gives a number from 0 to 1. A high value means the pegs cover the screen well.

#block(sticky: true, below: 0pt)[#gl("mdl-efficiency")[#strong[MDL efficiency.]]]

$ eta_"MDL" = frac("AUC"_"MI", log_2(1 + K_"geom")) $

- The top is the integrated trajectory agency from Pillar II, in bits.
- The bottom is the description length from Section 2.9, also turned into bits.
- The ratio is "bits of controlled behaviour per bit of design".

#tbl(columns: (32.0fr, auto, auto,), align: (left, right, right,),
  [Input], [Divide by #tag("HAND-SET")], [Weight #tag("HAND-SET")],
  [Waveguide–scatterer balance $B_"wg"$], [1], [0.45],
  [Spatial entropy], [1], [0.25],
  [MDL efficiency $eta_"MDL"$], [8.5], [0.30],
)

== Putting the pillars together: the LQI <sec-3-8>

The model has five pillar ratings $Q_1, dots, Q_5$, each from 0 to 1. It combines them with weights $w = (0.22, 0.23, 0.20, 0.23, 0.12)$. #tag("HAND-SET") The weights add up to 1. Pillar V has the smallest weight, because it is the least direct link to fun.

$ "LQI" = frac(1, 2) underbrace(sum_(p=1)^5 w_p thin Q_p, "arithmetic mean") + frac(1, 2) underbrace(product_(p=1)^5 max(0.01, Q_p)^(w_p), "geometric mean") $

- $Q_p$ is the rating of pillar $p$.
- $w_p$ is its weight.
- $sum$ means "add up". $product$ means "multiply together".
- $max(0.01, Q_p)$ replaces a zero rating with 0.01, so that the product is never exactly zero.

#strong[Why two kinds of mean?] The two means behave differently when one pillar is weak.

- The #gl("arithmetic-mean")[#strong[arithmetic mean]] adds. A strong pillar can make up for a weak one. If four pillars are 1.0 and one is 0.0, the arithmetic mean is still about 0.8.
- The #gl("geometric-mean")[#strong[geometric mean]] multiplies. One weak pillar pulls the whole result down. If one pillar is near 0, the product is near 0, whatever the other pillars do.

#intuition[Think of a chair with five legs. The arithmetic mean asks "how long are the legs on average?". The geometric mean asks "can you sit on it?". One missing leg barely changes the average length, but you fall over.]

The model takes half of each. A level with one broken pillar loses a lot, but not everything. A level with balanced pillars gets almost the same value from both means.

#example[On `ribbon_waves`, the pillars are all high and close together. The arithmetic mean is 0.932 and the geometric mean is 0.932. On `slide`, Pillar IV is 0.017 because the level has no red pegs. The arithmetic mean is 0.402, but the geometric mean is only 0.219. The LQI lands between them, at 0.310. #tag("MEASURED")]

#figure(fig-means(), caption: [Arithmetic mean, geometric mean and LQI per level. Data from the table in Section 4.2.]) <fig-means>

= Results on the five levels <sec-4>

All numbers in this section are #tag("MEASURED"). They come from `results/analysis/level_evaluation_profiles.json`. The profiler ran all levels with `campaigns/ribbon/config.v1.json`, except `mustache`, which used `fixtures/mustache/config.dev.v1.json`. Section 5 explains why this matters.

== The level at a glance (Tier 0) <sec-4-1>

#tbl(columns: (auto, 1fr, 1fr, 1fr, 1fr, 1fr, 1fr, 1fr, 1fr, 1fr,), align: (left, right, right, right, right, right, right, right, right, right,),
  [Level], [Pegs], [Red], [Slide pegs], [Lines], [Slide fraction], [$B_"wg"$], [Mirror symmetry], [Spatial entropy], [$K_"geom"$],
  [#lv("ribbon_waves")], [133], [25], [80], [5], [0.602], [0.959], [0.419], [0.849], [136],
  [#lv("mustache")], [99], [16], [72], [9], [0.727], [0.793], [1.000], [0.670], [108],
  [#lv("circle_level")], [25], [10], [0], [0], [0.000], [0.000], [0.245], [0.721], [50],
  [#lv("squiggly_circle")], [192], [10], [192], [1], [1.000], [0.000], [0.180], [0.828], [6],
  [#lv("slide")], [73], [0], [72], [3], [0.986], [0.054], [0.142], [0.476], [20],
)

== The overall rating <sec-4-2>

#tbl(columns: (auto, 1fr, 1fr, 1fr,), align: (left, right, right, right,),
  [Level], [LQI], [Arithmetic mean], [Geometric mean],
  [#lv("ribbon_waves")], [0.932], [0.932], [0.932],
  [#lv("mustache")], [0.775], [0.778], [0.772],
  [#lv("circle_level")], [0.515], [0.555], [0.475],
  [#lv("squiggly_circle")], [0.500], [0.533], [0.466],
  [#lv("slide")], [0.310], [0.402], [0.219],
)

#figure(fig-lqi(), caption: [LQI per level, from high to low.]) <fig-lqi>

== The five pillars <sec-4-3>

#tbl(columns: (auto, 1fr, 1fr, 1fr, 1fr, 1fr,), align: (left, right, right, right, right, right,),
  [Level], [I: Agency], [II: Skill horizon], [III: Tactics], [IV: 1v1], [V: Elegance],
  [#lv("ribbon_waves")], [0.954], [0.870], [0.958], [0.947], [0.944],
  [#lv("mustache")], [0.926], [0.808], [0.715], [0.653], [0.790],
  [#lv("circle_level")], [0.954], [0.222], [0.437], [0.759], [0.266],
  [#lv("squiggly_circle")], [0.929], [0.195], [0.525], [0.582], [0.375],
  [#lv("slide")], [0.919], [0.393], [0.310], [0.017], [0.364],
)

#figure(fig-pillars(), caption: [The five pillar ratings of each level. Data from the table above.]) <fig-pillars>

The table shows the main story at once:

- Pillar I is almost the same for all levels, from 0.92 to 0.95. It does not separate good levels from bad ones. Section 4.10 explains why.
- Pillar II separates the levels most clearly. The two slide-and-peg levels score 0.81 and 0.87. The others score 0.20 to 0.39.
- Pillar IV catches the two game-rule problems: `slide` has no red pegs, and `mustache` is unfair to Player 2.

== Inside the pillars <sec-4-4>

Each pillar is a weighted mix of inputs. This table shows each input after the profiler divides it by its target and cuts it to 0 to 1.

#tbl(columns: (6.0fr, 27.0fr, auto, auto, auto, auto, auto,), align: (left, left, right, right, right, right, right,), breakable: true,
  [Pillar], [Input (weight)], [#lv("ribbon_waves")], [#lv("mustache")], [#lv("circle_level")], [#lv("squiggly_circle")], [#lv("slide")],
  [I], [Mutual information (0.35)], [1.00], [0.94], [1.00], [1.00], [0.95],
  [I], [Controllability (0.25)], [0.82], [0.81], [0.91], [1.00], [0.99],
  [I], [Empowerment (0.20)], [0.99], [0.98], [1.00], [1.00], [0.98],
  [I], [Active aim space (0.20)], [1.00], [1.00], [0.88], [0.65], [0.72],
  [II], [$"AUC"_"MI"$ (0.40)], [1.00], [0.85], [0.23], [0.22], [0.46],
  [II], [Deep cascade $alpha(10)$ (0.25)], [1.00], [0.99], [0.02], [0.01], [0.30],
  [II], [Skill horizon (0.20)], [1.00], [1.00], [0.30], [0.17], [0.29],
  [II], [Aimable basins (0.15)], [0.13], [0.14], [0.44], [0.47], [0.52],
  [III], [Competitive sectors (0.30)], [1.00], [0.99], [0.96], [0.53], [0.00],
  [III], [First-hit breadth (0.25)], [1.00], [0.38], [0.33], [1.00], [0.83],
  [III], [Style rate (0.25)], [1.00], [0.67], [0.09], [0.08], [0.06],
  [III], [Peg equity (0.20)], [0.79], [0.78], [0.22], [0.48], [0.44],
  [IV], [Pacing (0.25)], [0.93], [0.57], [0.43], [0.01], [0.00],
  [IV], [Completion (0.15)], [0.88], [1.00], [0.38], [0.25], [1.00],
  [IV], [First-player balance (0.20)], [1.00], [0.25], [1.00], [1.00], [1.00],
  [IV], [Drama (0.20)], [0.94], [0.87], [1.00], [0.90], [0.00],
  [IV], [Skill gradient (0.20)], [0.97], [0.69], [0.97], [0.81], [0.00],
  [V], [Waveguide balance (0.45)], [0.96], [0.79], [0.00], [0.00], [0.05],
  [V], [Spatial entropy (0.25)], [0.85], [0.67], [0.72], [0.83], [0.48],
  [V], [MDL efficiency (0.30)], [1.00], [0.89], [0.29], [0.56], [0.74],
)

#watchout[For `slide`, Pillar IV completion and balance are 1.00, but the match ends on turn 1. The level has no red pegs, so "all red pegs cleared" is true at once. The 0.05 red-peg gate then pulls Pillar IV down to 0.017.]

== Key single-shot metrics (Tier 1) <sec-4-5>

#tbl(columns: (40.0fr, auto, auto, auto, auto, auto,), align: (left, right, right, right, right, right,),
  [Metric], [#lv("ribbon_waves")], [#lv("mustache")], [#lv("circle_level")], [#lv("squiggly_circle")], [#lv("slide")],
  [Mean pegs hit per shot], [20.5], [27.4], [3.4], [1.8], [5.1],
  [Dead aims (hit no peg)], [0.0%], [0.0%], [12.2%], [35.3%], [27.6%],
  [Shots that hit red], [96.7%], [90.8%], [63.9%], [12.0%], [0.0%],
  [Aims safe for red at ±1 step (≥ 80% red)], [90.5%], [78.1%], [46.7%], [5.7%], [0.0%],
  [Shots with any style], [41.1%], [23.4%], [3.3%], [2.9%], [2.1%],
  [Distinct first-hit pegs], [42], [15], [13], [116], [33],
  [Peg-hit Gini], [0.211], [0.217], [0.303], [0.523], [0.516],
  [Effective competitive sectors], [18.01], [17.84], [17.32], [9.53], [0.00],
  [Aimable basin fraction], [6.5%], [6.8%], [22.2%], [23.3%], [25.8%],
  [Knife-edge fraction], [93.5%], [93.2%], [65.6%], [41.5%], [46.6%],
)

== The skill-horizon curves <sec-4-6>

These two tables are the heart of Pillar II. The first one gives the mutual information between the intended aim and the #box[$k$-th] scored peg, at $sigma = 2$. The second gives the fraction of shots that score at least $k$ pegs.

#strong[Mutual information $I_2 (A; Y_k)$, in bits:]

#tbl(columns: (18.0fr, auto, auto, auto, auto, auto,), align: (left, right, right, right, right, right,), breakable: true,
  [$k$], [#lv("ribbon_waves")], [#lv("mustache")], [#lv("circle_level")], [#lv("squiggly_circle")], [#lv("slide")],
  [1], [4.66], [3.18], [2.97], [4.95], [4.32],
  [2], [4.56], [4.08], [3.50], [3.19], [3.65],
  [3], [3.99], [3.37], [2.20], [2.00], [2.82],
  [4], [4.01], [3.32], [1.67], [1.33], [2.28],
  [5], [4.06], [3.31], [1.25], [0.90], [1.97],
  [6], [4.19], [3.25], [0.88], [0.45], [1.75],
  [7], [4.21], [3.26], [0.57], [0.19], [1.60],
  [8], [4.22], [3.30], [0.36], [0.11], [1.48],
  [9], [4.19], [3.35], [0.23], [0.06], [1.39],
  [10], [4.15], [3.36], [0.10], [0.04], [1.31],
  [11], [4.06], [3.41], [0.03], [0.04], [1.22],
  [12], [3.98], [3.46], [0.02], [0.03], [1.12],
  [13], [3.89], [3.48], [0.00], [0.03], [0.98],
  [14], [3.78], [3.43], [0.00], [0.03], [0.83],
  [15], [3.62], [3.38], [0.00], [0.03], [0.71],
  [#strong[Sum ($"AUC"_"MI"$)]], [#strong[61.57]], [#strong[50.95]], [#strong[13.79]], [#strong[13.39]], [#strong[27.44]],
  [#strong[Skill horizon $k_(1\/2)$]], [#strong[15+]], [#strong[15+]], [#strong[4.44]], [#strong[2.60]], [#strong[4.39]],
)

#figure(fig-mi-k(), caption: [The skill-horizon curves: mutual information between the intended aim and the #box[$k$-th] scored peg, at $sigma = 2$. The shaded area is $"AUC"_"MI"$ of `ribbon_waves`.]) <fig-mi-k>

#strong[Fraction of shots with at least $k$ scored pegs, $alpha(k)$:]

#tbl(columns: (1fr, 1fr, 1fr, 1fr, 1fr, 1fr,), align: (right, right, right, right, right, right,),
  [$k$], [#lv("ribbon_waves")], [#lv("mustache")], [#lv("circle_level")], [#lv("squiggly_circle")], [#lv("slide")],
  [1], [1.00], [1.00], [0.88], [0.65], [0.72],
  [3], [1.00], [0.99], [0.60], [0.28], [0.45],
  [5], [0.98], [0.91], [0.30], [0.12], [0.34],
  [10], [0.88], [0.84], [0.01], [0.00], [0.25],
  [15], [0.72], [0.81], [0.00], [0.00], [0.13],
)

#figure(fig-alpha(), caption: [Cascade survival $alpha(k)$, the fraction of shots that score at least $k$ pegs. The chart shows all 15 values of each level from the profile file. The table above shows five of them.]) <fig-alpha>

#strong[How to read the curves.] On `ribbon_waves`, the curve starts at 4.66 bits and is still at 3.62 bits at the fifteenth peg. Also, 88% of shots reach ten pegs. The aim decides a long cascade. On `squiggly_circle`, the curve starts higher, at 4.95 bits, but falls below half by hit 2.6. Most shots end after one or two pegs. On `circle_level`, the curve falls to almost zero by hit 10. Only 1% of shots get that far.

#watchout[On `mustache`, the curve rises from hit 1 (3.18 bits) to hit 2 (4.08 bits). This looks odd, because information about the aim cannot grow along a chain. The explanation: the second peg is not computed from the first peg alone. It depends on the full position and speed of the ball. Also, the label "no second peg" carries information of its own. So the curve does not have to fall at every step.]

== Control under more and more aim noise <sec-4-7>

This table shows the route mutual information $I_sigma (A; O_"route")$ for five noise widths. The LQI uses only the $sigma = 2$ column.

#tbl(columns: (auto, 6.0fr, auto, auto, auto, auto, auto,), align: (right, left, right, right, right, right, right,),
  [Noise $sigma$ (steps)], [Angle], [#lv("ribbon_waves")], [#lv("mustache")], [#lv("circle_level")], [#lv("squiggly_circle")], [#lv("slide")],
  [1], [±0.1°], [4.98], [4.58], [5.37], [5.38], [4.30],
  [2], [±0.2°], [4.28], [3.93], [4.81], [5.06], [3.98],
  [5], [±0.5°], [3.26], [2.99], [3.96], [4.53], [3.52],
  [10], [±1.0°], [2.51], [2.31], [3.32], [4.05], [3.18],
  [20], [±2.0°], [1.83], [1.70], [2.70], [3.52], [2.85],
)

#figure(fig-mi-sigma(), caption: [Route mutual information $I_sigma (A; O_"route")$ against the aim noise $sigma$, on a log scale. The LQI uses only $sigma = 2$.]) <fig-mi-sigma>

This table holds a surprise. The two simple levels, `circle_level` and `squiggly_circle`, give #strong[more] control over the route than `ribbon_waves`. And they lose control more slowly as the noise grows.

The reason is that their shots are short. A shot that hits one or two pegs and falls out is easy to predict. The player controls it well, but there is little to control. Section 4.10 comes back to this.

== 1v1 match results (Tier 2) <sec-4-8>

Each value comes from 8 matches. A win rate can only be 0%, 12.5%, 25%, and so on, in steps of 12.5%.

#tbl(columns: (42.0fr, auto, auto, auto, auto, auto,), align: (left, right, right, right, right, right,), breakable: true,
  [Metric], [#lv("ribbon_waves")], [#lv("mustache")], [#lv("circle_level")], [#lv("squiggly_circle")], [#lv("slide")],
  [Mean match length (turns)], [9.9], [6.4], [15.9], [19.9], [1.0],
  [Ended with all red cleared], [87.5%], [100%], [37.5%], [25.0%], [(no red)],
  [Ended with balls exhausted], [12.5%], [0%], [62.5%], [75.0%], [0%],
  [Penalties per match], [2.0], [1.5], [11.1], [11.5], [0.0],
  [Player 1 win rate], [50%], [87.5%], [50%], [50%], [50%],
  [First-player balance $cal(B)$], [1.00], [0.25], [1.00], [1.00], [1.00],
  [Lead changes per match], [1.25], [0.88], [1.50], [1.25], [0.00],
  [Comeback win rate], [62.5%], [50.0%], [100%], [62.5%], [0%],
  [Mean deficit overcome], [0.51], [0.38], [0.82], [0.47], [0.00],
  [Suspense], [0.178], [0.234], [0.276], [0.150], [0.000],
  [Surprise], [0.119], [0.169], [0.189], [0.070], [0.000],
  [Fine aim beats sloppy aim], [87.5%], [75.0%], [87.5%], [75.0%], [50%],
  [Sector bot beats random bot], [100%], [87.5%], [100%], [100%], [50%],
  [Tactical bot beats sector bot (not in LQI)], [50%], [100%], [62.5%], [50%], [50%],
)

#figure(fig-match-length(), caption: [Mean match length per level, from 8 matches each. The band marks the pacing sweet spot of 9 to 13 turns from the profiler code. The pacing rating peaks at 10.5 turns. The label at each bar is its pacing rating.]) <fig-match-length>

== Level by level <sec-4-9>

#strong[`ribbon_waves`: LQI 0.932, the best.] This level does almost everything well. Every aim hits at least one peg. The average shot scores 20 pegs, and 88% of shots reach ten. The aim still carries 3.6 bits of information at the fifteenth peg. Shots can start from 42 different first pegs, and 41% of aims earn a style bonus, mostly slides. In 1v1, matches last about 10 turns, both seats win equally often, and the better bot wins clearly. The mix of 60% slide pegs and 40% round pegs sits near the top of the balance curve in Section 3.7.

#strong[`mustache`: LQI 0.775, second.] The slides work well here too. Shots are long (27 pegs on average) and the skill horizon reaches 15. Two problems lower the rating. First, only 15 different pegs can be the first hit. The top mustache shields the two below it from the launcher. Second, a shot clears so much of the board that matches last only 6.4 turns. Player 1 won 7 of the 8 matches. The earlier notes suggest that Player 1 profits from the first big clear. That is a hypothesis. With 8 matches, it is also possible that part of this result is chance.

#strong[`circle_level`: LQI 0.515, third.] A small grid of 25 round pegs and no slides. The aim controls the first two pegs well. After that, the round pegs scatter the ball and the shot ends. The average shot hits only 3.4 pegs, and 1% of shots reach ten. Style shots are rare, at 3.3%. In 1v1, red pegs are hard to hit reliably, so players take about 11 penalties per match, and most matches end because the balls run out. The level is fair and dramatic (every winner came from behind), but each shot is shallow.

#strong[`squiggly_circle`: LQI 0.500, fourth.] All 192 pegs form one closed ring. Most shots hit the outside of the ring and fall away. 35% of aims hit nothing. The average shot hits 1.8 pegs. Only 12% of shots hit red, and only 5.7% of aims are safe for red with ±1 step of aim noise. Matches drag to almost 20 turns, and 75% of them end with no balls left.

#strong[`slide`: LQI 0.310, last.] This is a test level for style shots, not a real 1v1 level. It has no red pegs, so the 1v1 pillar collapses. It still gets a fair Pillar II rating (0.39), because a quarter of shots ride a slide for ten pegs or more.

== Three lessons from the numbers <sec-4-10>

#strong[Lesson 1: control is not enough.] Pillar I is nearly flat across the five levels. The simple levels even score higher on route control (Section 4.7). Their shots are short, so they are easy to predict. Control over nothing interesting is not fun. Pillar II fixes this: it asks for control over a long, rich cascade. That is why the model weights Pillar II heavily and why $"AUC"_"MI"$ is its main input.

#strong[Lesson 2: slides carry intent.] The two levels with a real mix of slides and round pegs have the longest skill horizons and the highest LQI. This agrees with the billiard picture of Section 2.6. The pure round-peg level and the pure slide ring both do badly, for opposite reasons.

#strong[Lesson 3: a good shot level is not always a good 1v1 level.] `mustache` has excellent single shots, but its matches are short and one-sided. Only the match simulations of Tier 2 show this.

#watchout[The basin metric points the other way. On `ribbon_waves`, 93.5% of aims are knife edges: the first five pegs change between neighbour aims. By this metric, `squiggly_circle` looks more aimable. The reason is that long cascades change their first five pegs often, even when the route stays the same. The aimable-basin input has a small weight (0.15) and does not change the ranking. But it shows that "aimable" depends on how you define "the same shot".]

= Limits and open questions <sec-5>

The model is a useful first tool. It is not a proof that a level is fun. This section lists what it does not see and which numbers are guesses.

== Numbers that a person chose <sec-5-1>

- #strong[Pillar weights.] The five weights (0.22, 0.23, 0.20, 0.23, 0.12) and the weights inside each pillar are choices. No data fixed them. #tag("HAND-SET")
- #strong[Targets.] Each input is divided by a target, for example 60 bits or 0.85. Many of these targets sit at or just under the `ribbon_waves` value: 4.2 bits of mutual information (`ribbon_waves`: 4.28), 5.2 bits of empowerment (5.15), 60 bits of $"AUC"_"MI"$ (61.57), 0.85 deep cascade (0.88), 40 first-hit pegs (42), suspense 0.18 (0.178), MDL efficiency 8.5 (8.67). So the LQI partly measures "how close is this level to `ribbon_waves`". That is a fair start, because the team likes that level. But it explains why `ribbon_waves` gets 1.00 on many inputs. It also means that the LQI cannot yet show a level that is better than `ribbon_waves`.
- #strong[The 50/50 mix of means.] Other mixes are possible. Nobody tested which one matches human opinion best.
- #strong[Other constants.] The pacing peak of 10.5 turns, the 0.40 Jaccard threshold, the 5% comeback threshold, the 0.05 red-peg gate, the 6-and-2 rule for $K_"geom"$, and the logistic scale $S_"scale"$ are all choices.

== Small samples <sec-5-2>

Tier 2 plays 8 matches per test. A win rate of 87.5% means 7 wins out of 8. With 8 matches, a fair coin gives 7 or more heads about 3.5% of the time. So the `mustache` first-player problem is likely real, but not certain. Lead changes, comebacks and suspense from 8 matches also have wide error ranges. More matches per level would make Pillar IV more trustworthy. The simulator is fast enough for this.

== Bots are not people <sec-5-3>

All match results come from simple bots. The sector bot picks the best gross points in each block of aims and ignores the red-peg penalty. Human players think ahead, take risks on purpose, and get bored. The model has no data from real players. Nobody has yet checked that a higher LQI means that people enjoy a level more.

== Only the first shot is studied in detail <sec-5-4>

Tier 1 fires all 1801 shots from the starting board only. Later in a match, the board has fewer pegs and can behave very differently. Pillars I, II and III do not see this. Pillar IV sees it only through the bots.

== Theory that is not measured <sec-5-5>

The model uses chaos theory as its main explanation for Pillar II. But the profiler computes no Lyapunov exponent. The estimate "one round peg makes an aim error 14 times bigger" comes from a textbook formula, not from the simulator. The information curve is the real measurement. The theory explains why the curves look the way they do.

== Different physics for one level <sec-5-6>

`mustache` ran with its own configuration file. That file has stronger gravity (1000 against 700), a faster launch (800 against 600), and different wall and ball-ball bounce values. So the comparison between `mustache` and the other four levels is not exact.

== What the model does not capture <sec-5-7>

- #strong[Looks.] Color, theme and visual beauty play no part.
- #strong[Readability for a human.] The model measures how predictable a shot is for a perfect calculator with noisy hands. A human must also #emph[see] the likely path. Mirror symmetry and spatial entropy are only rough stand-ins.
- #strong[Learning curve and difficulty over time.] The model does not ask whether a player gets better with practice on this level.
- #strong[Moving pegs.] The single-shot sweep runs in a static-geometry mode. This report does not examine how the model handles levels whose pegs move.
- #strong[Solo mode.] Pillar IV is only about 1v1.

== Open questions <sec-5-8>

+ Do human players rank the five levels in the same order as the LQI? A small play test can answer this.
+ Which targets and weights best match human rankings? With enough rated levels, you can fit them to data instead of choosing them.
+ Does Pillar I need a new design, given that it barely separates the levels? One option is to replace it with control over the hit set, or with control at a larger noise width.
+ How does the LQI change if the sweep starts from mid-match boards, not only the starting board?
+ Which behaviour descriptors make the best MAP-Elites map for level generation?
+ With more matches, does the `mustache` first-player advantage stay near 87.5%?

== Where the notes and the code disagree <sec-5-9>

The report follows the code. These are the differences found:

+ #strong[Number of aim sectors.] The notes say 18 sectors of 100 aims. The code makes 19: eighteen of 100 aims, plus one sector that holds only aim index 1800. That is why `ribbon_waves` shows 18.01 "effective sectors", which is more than 18.
+ #strong[Inputs to the LQI.] The notes describe four outcome labels, surprise, deficit overcome, and the tactical bot. The LQI uses only the route label at $sigma = 2$. It does not use surprise, deficit overcome or the tactical-bot result. Pillar I also includes the dead-aim fraction, and Pillar II includes the aimable-basin fraction. The model note does not list these two.
+ #strong[Peg equity.] The code multiplies $1 - G_"peg"$ by $min(1, N \/ 80)$. The notes do not mention this factor.
+ #strong[Pacing.] The code also sets pacing to 0 when a match lasts under 2 turns.
+ #strong[Empowerment.] The notes call it "exact". The code runs 25 rounds of Blahut–Arimoto and is an estimate.
+ #strong[Suspense.] The notes cite the paper's forward-looking definition. The code uses realized jumps. The code comment calls the belief model "calibrated", but no fit happens.
+ #strong[Route label.] The literature notes describe a route label with the first peg and an 8 × 8 grid. The code uses a 4 × 4 grid, a pegs-hit tier, the exit quarter, a style flag and a red flag. The main model note agrees with the code.
+ #strong[MDL efficiency.] The literature notes put route mutual information on top of the fraction. The model note and the code use $"AUC"_"MI"$.
+ #strong[Aim step.] One literature note says one step is 0.09°. The configuration gives a 90° limit on each side and 1800 steps, so one step is 0.1°.
+ #strong[Pillar headers in the code.] The comment at the top of the profiler lists a finite-time Lyapunov exponent and a Pareto frontier. The code computes neither.

= Glossary <sec-6>

#glossary(
  gl-entry("active-aim-space", [Active aim space], [The fraction of aim indices whose shot hits at least one peg. The other aims are dead aims.]),
  gl-entry("aim-index", [Aim index], [A whole number from 0 to 1800 that selects the launch angle. Neighbouring indices differ by 0.1°.]),
  gl-entry("aim-noise", [Aim noise], [A random shift between the aim that the player intends and the aim that the game fires. The model draws it evenly from $plus.minus sigma$ steps.]),
  gl-entry("aimable-basin", [Aimable basin], [A run of three or more neighbouring aims whose first five scored pegs are almost the same. A player with ±1 step of noise stays inside it.]),
  gl-entry("annular-peg", [Annular peg], [A peg shaped like a short piece of a curved band. Annular pegs often form curved slides.]),
  gl-entry("arithmetic-mean", [Arithmetic mean], [The usual average: add the values, then divide. With weights, multiply each value by its weight before you add.]),
  gl-entry("bit", [Bit], [A unit of information. One bit is the answer to one fair yes-or-no question.]),
  gl-entry("blahut-arimoto-algorithm", [Blahut–Arimoto algorithm], [A step-by-step method that finds the channel capacity. It moves weight toward inputs whose outputs stand out.]),
  gl-entry("bot", [Bot], [A computer player. The model uses sector, sloppy, random and tactical bots.]),
  gl-entry("bucket", [Bucket], [The moving catcher at the bottom of the screen. A catch gives bonus points.]),
  gl-entry("cascade-survival", [Cascade survival, $alpha(k)$], [The fraction of shots that score at least $k$ pegs.]),
  gl-entry("channel", [Channel], [In information theory, anything that takes an input and gives a possibly noisy output. Here, the input is the intended aim and the output is the shot outcome.]),
  gl-entry("channel-capacity", [Channel capacity], [The highest mutual information that a channel can reach, when you pick the best way to use its inputs.]),
  gl-entry("chaos", [Chaos], [Behaviour where tiny differences at the start grow into large differences later.]),
  gl-entry("comeback-win-rate", [Comeback win rate], [The fraction of decided matches where the winner was once behind by more than 5% of the leader's points.]),
  gl-entry("conditional-entropy", [Conditional entropy, $H(O mid(|) A)$], [The uncertainty about the outcome that remains after you know the intended aim. Also called equivocation.]),
  gl-entry("controllability", [Controllability, $cal(C)$], [Mutual information divided by outcome entropy. It is the fraction of outcome variety that the player controls.]),
  gl-entry("empowerment", [Empowerment, $frak(E)$], [The channel capacity from the player's aim to the outcome. It is the control that a smart player who picks the best angles can reach.]),
  gl-entry("entropy", [Entropy, $H$], [A measure of variety or surprise in an outcome, in bits.]),
  gl-entry("fever", [Fever], [The game state after all red pegs are cleared. The multiplier is ×100 and special buckets appear.]),
  gl-entry("first-player-balance", [First-player balance, $cal(B)$], [A rating from 0 to 1 of how fair the level is to the player who goes second. 1 means each player wins half the time.]),
  gl-entry("galton-board", [Galton board], [A board of pins where a falling ball bounces left or right at each pin. A grid of round pegs behaves like one.]),
  gl-entry("geometric-mean", [Geometric mean], [An average where you multiply the values and take a root. One value near zero pulls it toward zero.]),
  gl-entry("gini-coefficient", [Gini coefficient, $G$], [A measure of inequality from 0 to 1. Here, 0 means every peg is hit equally often.]),
  gl-entry("information-bottleneck", [Information bottleneck], [The idea that a good summary keeps the information that matters for a goal and drops the rest.]),
  gl-entry("integrated-trajectory-agency", [Integrated trajectory agency, $"AUC"_"MI"$], [The sum of the mutual information between aim and the #box[$k$-th] scored peg, for $k = 1$ to 15. It is high only for long shots that the aim still controls.]),
  gl-entry("jaccard-distance", [Jaccard distance], [One minus the share of pegs that two shots have in common. 0 means the same pegs, 1 means none in common.]),
  gl-entry("knife-edge", [Knife edge], [An aim whose basin is shorter than three aims. A tiny aim error changes the shot.]),
  gl-entry("level-quality-index-lqi", [Level Quality Index (LQI)], [The final rating of a level, from 0 to 1. It is half the weighted arithmetic mean and half the weighted geometric mean of the five pillar ratings.]),
  gl-entry("logistic-function", [Logistic function], [An S-shaped curve that turns any number into a value between 0 and 1. The model uses it to turn a score gap into a win chance.]),
  gl-entry("lyapunov-exponent", [Lyapunov exponent, $lambda$], [The average rate at which small differences grow per bounce. Positive means chaos, negative means paths come together.]),
  gl-entry("map-elites", [MAP-Elites], [A search method that keeps the best solution in each cell of a map of features, not only the single best one.]),
  gl-entry("minimum-description-length-mdl", [Minimum Description Length (MDL)], [The principle that the shortest description of something captures its real structure.]),
  gl-entry("mdl-efficiency", [MDL efficiency, $eta_"MDL"$], [Integrated trajectory agency divided by the description length of the level in bits.]),
  gl-entry("multiplier", [Multiplier], [The factor that grows as players clear red pegs. It reaches ×100 at fever.]),
  gl-entry("mutual-information", [Mutual information, $I(A;O)$], [How much knowing the intended aim tells you about the outcome, in bits. It is entropy minus conditional entropy.]),
  gl-entry("outcome-label", [Outcome label], [A short description of what a shot did. The model uses hit set, score tier, tactical label and route label.]),
  gl-entry("perplexity", [Perplexity], [Two raised to the power of an entropy. It is the effective number of equally good options.]),
  gl-entry("pillar", [Pillar], [One of the five parts of the model. Each pillar gives a rating from 0 to 1.]),
  gl-entry("quality-diversity", [Quality-diversity], [A family of search methods that look for many different good solutions, not one best solution.]),
  gl-entry("red-peg-penalty", [Red-peg penalty], [In 1v1, a shot with no red peg earns nothing and costs the player 25% of the banked points.]),
  gl-entry("route-label", [Route label], [The main outcome label. It records the screen region of the hit pegs, the number of pegs on a log scale, the exit quarter, a style flag and a red flag.]),
  gl-entry("sector", [Sector], [A block of 100 neighbouring aim indices. The sector bot picks the best shot in each sector.]),
  gl-entry("shielding", [Shielding], [A layer of pegs that blocks the launcher's direct view of the pegs behind it.]),
  gl-entry("skill-gradient", [Skill gradient], [A rating of how clearly the better bot wins. It uses fine-against-sloppy aim and sector-against-random matches.]),
  gl-entry("skill-horizon", [Skill horizon, $k_(1\/2)$], [The hit number at which the aim's information about the scored peg falls to half of its value at the first hit.]),
  gl-entry("slide", [Slide], [A line of pegs with no gap, along which the ball can roll. The model also calls it a waveguide.]),
  gl-entry("style-shot", [Style shot], [A bonus for a special kind of shot, for example a slide, a long shot or an off-the-wall bounce.]),
  gl-entry("surprise", [Surprise], [The average size of the jump in win chance from one turn to the next.]),
  gl-entry("suspense", [Suspense], [In the paper, the expected size of the next jump in win chance. In the profiler, the root-mean-square size of the jumps that happened.]),
  gl-entry("waveguide-scatterer-balance", [Waveguide–scatterer balance, $B_"wg"$], [$4 f_"slide" (1 - f_"slide")$, where $f_"slide"$ is the fraction of pegs on a slide. It is 1 for an even mix of slides and loose pegs, and 0 for all of one kind.]),
)



















































= References <sec-7>
#set par(justify: false)

Papers with a local copy are in `papers/`. The file name follows each entry.

#refgroup[Information theory and empowerment]

- C. E. Shannon (1948). #emph[A Mathematical Theory of Communication]. Bell System Technical Journal 27. `shannon_1948_mathematical_theory_of_communication.pdf`
- C. Salge, C. Glackin and D. Polani (2014). #emph[Empowerment — An Introduction]. In #emph[Guided Self-Organization: Inception], Springer. arXiv:1310.1863. `salge_glackin_polani_2014_empowerment_introduction.pdf`
- N. Tishby, F. C. Pereira and W. Bialek (2000). #emph[The Information Bottleneck Method]. arXiv:physics/0004057. `tishby_pereira_bialek_2000_information_bottleneck.pdf`
- #emph[The Geometry of Empowerment] (2026). arXiv:2610.07796. `geometry_of_empowerment_2026.pdf`
- #emph[Information-Theoretic Policy Pre-Training with Empowerment] (2025). arXiv:2510.05996. `empowerment_policy_pretraining_2025.pdf`

#refgroup[Skill, luck and game design]

- J. Jerdee and M. E. J. Newman (2023). #emph[Luck, skill, and depth of competition in games and social hierarchies]. arXiv:2312.04711. `luck_skill_depth_of_competition_2023.pdf`
- #emph[Quantifying Skill and Chance: A Unified Framework for the Geometry of Games] (2025). arXiv:2511.11611. `quantifying_skill_and_chance_geometry_of_games_2025.pdf`
- J. Ely, A. Frankel and E. Kamenica (2015). #emph[Suspense and Surprise]. Journal of Political Economy 123(1). No local copy.
- C. Browne and F. Maire (2010). #emph[Evolutionary Game Design]. IEEE Transactions on Computational Intelligence and AI in Games 2(1). No local copy.

#refgroup[Chaos and billiards]

- #emph[Estimating Lyapunov Exponents in Billiards] (2019). arXiv:1904.05108. `estimating_lyapunov_exponents_in_billiards_2019.pdf`
- #emph[Dynamics of the No-Slip Galton Board] (2022). arXiv:2208.07790. `dynamics_of_no_slip_galton_board_2022.pdf`
- H. van Beijeren, J. R. Dorfman, H. A. Posch and Ch. Dellago (2004). #emph[The Kolmogorov-Sinai Entropy and Lyapunov Spectrum of the Many-Dimensional Dilute Random Lorentz Gas]. arXiv:nlin/0404034. `lyapunov_spectrum_random_lorentz_gas_2004.pdf`

#refgroup[Level generation and quality-diversity]

- J. Togelius, G. N. Yannakakis, K. O. Stanley and C. Browne (2011). #emph[Search-Based Procedural Content Generation: A Taxonomy and Survey]. IEEE TCIAIG 3(3). `togelius_2011_search_based_pcg.pdf`
- J.-B. Mouret and J. Clune (2015). #emph[Illuminating search spaces by mapping elites]. arXiv:1504.04909. `mouret_clune_2015_map_elites.pdf`
- D. Gravina, A. Khalifa, A. Liapis, J. Togelius and G. N. Yannakakis (2019). #emph[Procedural Content Generation through Quality Diversity]. IEEE CoG. arXiv:1907.04053. `gravina_2019_pcg_through_quality_diversity.pdf`

#refgroup[Project sources]

- `wiki/brainstorming/mathematical_evaluation_model.md`: the original model note.
- `wiki/brainstorming/literature_review.md`: the original literature notes.
- `wiki/brainstorming/information_theory.md` and `wiki/brainstorming/level_design.md`: the first idea notes.
- `scripts/profile_level.jl`: the profiler. The report follows this code where the notes differ.
- `results/analysis/level_evaluation_profiles.json`: the measured profiles.

