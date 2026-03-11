#set page(
  paper: "a4",
  margin: (x: 35mm, y: 33mm),
  header-ascent: 0mm,
  footer-descent: 0mm,
)

#set text(
  lang: "ja",
  font: ("Noto Sans CJK JP", "DejaVu Sans"),
  size: 10.8pt,
)

#set par(
  justify: true,
  leading: 1.2em,
  spacing: 0.8em,
)

#set heading(
  numbering: "1.1",
)

#show heading.where(level: 1): it => [
  #pagebreak(to: "odd")
  #v(12mm)
  #set text(size: 20pt, weight: "bold")
  #it
  #v(7mm)
]

#show heading.where(level: 2): it => [
  #v(0.7em)
  #set text(size: 14.3pt, weight: "bold")
  #it
  #v(0.5em)
]

#show heading.where(level: 3): it => [
  #v(0.35em)
  #set text(size: 11.5pt, weight: "bold")
  #it
  #v(0.3em)
]

#show raw.where(block: true): it => [
  #v(0.5em)
  #block(
    fill: rgb("f4f6fb"),
    stroke: (paint: rgb("c9d2e5"), thickness: 0.5pt),
    inset: 9pt,
    radius: 4pt,
    width: 100%,
  )[#it]
  #v(0.5em)
]

#let editorial_note(body) = block(
  fill: rgb("faf1dc"),
  stroke: (paint: rgb("dcc989"), thickness: 0.5pt),
  inset: 10pt,
  radius: 4pt,
  width: 100%,
)[
  *編集注記* \
  #body
]

#let checkpoint(body) = block(
  fill: rgb("eef3ff"),
  stroke: (paint: rgb("b8c8ea"), thickness: 0.5pt),
  inset: 10pt,
  radius: 4pt,
  width: 100%,
)[
  *この章の到達点* \
  #body
]

#let caution(body) = block(
  fill: rgb("fff1ee"),
  stroke: (paint: rgb("e1b8ab"), thickness: 0.5pt),
  inset: 10pt,
  radius: 4pt,
  width: 100%,
)[
  *注意* \
  #body
]

#let terminal(body) = block(
  fill: rgb("f2f2f2"),
  stroke: (paint: rgb("cfcfcf"), thickness: 0.5pt),
  inset: 9pt,
  radius: 4pt,
  width: 100%,
)[
  #set text(font: ("DejaVu Sans Mono", "Noto Sans Mono CJK JP"), size: 9pt)
  #body
]

#let diagram(path, caption, width: 100%) = block(
  fill: rgb("fbfcfe"),
  stroke: (paint: rgb("d8e0ee"), thickness: 0.5pt),
  inset: (x: 10pt, y: 9pt),
  radius: 5pt,
  width: 100%,
)[
  #v(0.2em)
  #align(center)[#image(path, width: width)]
  #v(6pt)
  #align(center)[
    #block(width: 88%)[
      #set text(size: 8.8pt, fill: rgb("5b6674"))
      #caption
    ]
  ]
  #v(0.2em)
]
