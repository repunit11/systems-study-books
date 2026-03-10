#set page(
  paper: "a4",
  margin: (x: 32mm, y: 30mm),
  header-ascent: 0mm,
  footer-descent: 0mm,
)

#set text(
  lang: "ja",
  font: ("Noto Sans CJK JP", "DejaVu Sans"),
  size: 11pt,
)

#set par(
  justify: true,
  leading: 1.08em,
)

#set heading(
  numbering: "1.1",
)

#show heading.where(level: 1): it => [
  #pagebreak(weak: true)
  #set text(size: 19pt, weight: "bold")
  #it
]

#show heading.where(level: 2): it => [
  #set text(size: 14pt, weight: "bold")
  #it
]

#show heading.where(level: 3): it => [
  #set text(size: 11.5pt, weight: "bold")
  #it
]

#show raw.where(block: true): it => block(
  fill: rgb("f7f3ea"),
  stroke: (paint: rgb("d8d0c0"), thickness: 0.5pt),
  inset: 9pt,
  radius: 4pt,
  width: 100%,
)[#it]

#let editorial_note(body) = block(
  fill: rgb("faf3dc"),
  stroke: (paint: rgb("d9c98e"), thickness: 0.5pt),
  inset: 10pt,
  radius: 4pt,
  width: 100%,
)[
  *編集注記* \
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
