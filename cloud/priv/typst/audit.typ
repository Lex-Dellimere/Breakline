// breakline audit export report (D38).
//
// everything shown comes from data.json, the render model of
// Cloud.AuditExport.to_render_model/1, and is placed as a string: a string
// in content is always set as plain text, so markup or code inside it
// (`*x*`, `$x$`, `#read(..)`, `#import ..`) prints literally. this file never
// evaluates data (no eval), imports nothing (no packages, so no network)
// and reads no file but data.json. it only uses fonts embedded in the typst
// binary: libertinus serif for text and dejavu sans mono for hashes.

#let data = json("data.json")

#let ink = luma(20)
#let muted = luma(95)
#let rule = luma(200)
#let ok-fill = rgb("#e8f5ec")
#let ok-ink = rgb("#13612e")
#let bad-fill = rgb("#fdecec")
#let bad-ink = rgb("#9b1c1c")

#let mono(s, size: 7.5pt) = text(font: "DejaVu Sans Mono", size: size, s)

// lets long tokens (ids, hashes, json) wrap inside a table cell by adding a
// zero-width space after every run of 24 characters without a space; the
// result is still a string, shown as text
#let wrappable(s) = s.replace(regex("\S{24}"), m => m.text + "\u{200B}")

#set document(title: data.title + ": " + data.tenant, author: "Breakline", date: auto)
#set text(font: "Libertinus Serif", size: 9.5pt, fill: ink, lang: "en")
#set par(justify: false, leading: 0.55em)

#set page(
  paper: "a4",
  margin: (x: 16mm, top: 22mm, bottom: 18mm),
  header: {
    set text(size: 8pt, fill: muted)
    grid(
      columns: (1fr, auto),
      column-gutter: 8pt,
      [Breakline audit export · #data.tenant], data.period,
    )
    v(-4pt)
    line(length: 100%, stroke: 0.4pt + rule)
  },
  footer: context {
    set text(size: 8pt, fill: muted)
    grid(
      columns: (1fr, auto),
      [Generated #data.generated_at], [Page #counter(page).display() of #counter(page).final().first()],
    )
  },
)

#show heading.where(level: 1): set text(size: 20pt, weight: 700)
#show heading.where(level: 2): it => block(above: 14pt, below: 8pt, text(size: 13pt, weight: 700, it.body))

// cover

= Breakline audit export

#v(4pt)
#grid(
  columns: (auto, 1fr),
  column-gutter: 14pt,
  row-gutter: 7pt,
  text(fill: muted)[Tenant], text(weight: 600, data.tenant),
  text(fill: muted)[Period], data.period,
  text(fill: muted)[Exported by], data.exported_by,
  text(fill: muted)[Generated at], data.generated_at,
)

== Verification

#for v in data.verification {
  let ok = v.ok
  block(
    width: 100%,
    breakable: false,
    inset: (x: 12pt, y: 10pt),
    radius: 4pt,
    fill: if ok { ok-fill } else { bad-fill },
    stroke: 1.2pt + if ok { ok-ink } else { bad-ink },
    below: 8pt,
    {
      text(size: 8.5pt, weight: 700, fill: if ok { ok-ink } else { bad-ink }, if ok { "VERIFIED" } else { "BROKEN" })
      linebreak()
      text(size: 12.5pt, weight: 600, fill: if ok { ok-ink } else { bad-ink }, v.summary)
      if v.head_hash != none {
        linebreak()
        text(size: 8pt, fill: muted)[head hash ]
        mono(v.head_hash, size: 7.5pt)
      }
    },
  )
}

#block(
  width: 100%,
  inset: (x: 12pt, y: 9pt),
  radius: 4pt,
  stroke: 0.6pt + rule,
  {
    text(weight: 700)[Scope. ]
    [Verification covers each whole chain, from its first record to its head; the records listed below cover only the period. ]
    data.coverage
  },
)

// one table per chain, the first starting on page 2

#pagebreak()

#for (i, section) in data.sections.enumerate() {
  heading(level: 2, section.title)
  if section.rows.len() == 0 {
    text(fill: muted)[No records in this period.]
  } else {
    set text(size: 8pt)
    table(
      columns: (auto, 6.8em, 1fr, 1fr, 2.6fr, auto),
      inset: (x: 4pt, y: 3.5pt),
      stroke: (x, y) => (bottom: 0.4pt + rule, top: if y == 0 { 0.8pt + ink } else { none }),
      fill: (x, y) => if y == 0 { luma(238) } else if calc.even(y) { luma(250) } else { none },
      align: (x, y) => if x == 0 { right + top } else { left + top },
      table.header(
        repeat: true,
        ..section.columns.map(c => text(weight: 700, c)),
      ),
      ..section.rows.map(row => (
        row.at(0),
        row.at(1),
        wrappable(row.at(2)),
        wrappable(row.at(3)),
        wrappable(row.at(4)),
        mono(row.at(5), size: 7pt),
      )).flatten(),
    )
  }
}
