#import "theme.typ": *

#set document(title: "Compilerbook")

#align(center)[
  #set text(size: 24pt, weight: "bold")
  Compilerbook
]

#v(8pt)

Rui Ueyama 氏による公開記事 `compilerbook` をもとに、内容を Typst 向けに再構成した学習用ノートです。既存公開部分は論旨と章立てを保ちながら書き直し、未完だった `ステップ29以降` は新規に補完しています。

#editorial_note[
  この文書は元サイトの公開本文をそのまま写したものではありません。公開されている章立てと説明の流れを保ちつつ、Typst で読みやすいように再構成した版です。`ステップ29以降` については、公開ページ上の未完部分を埋めるための新規続編を含みます。
]

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-assembly.typ"
#include "chapters/03-calculator.typ"
#include "chapters/04-functions-and-linking.typ"
#include "chapters/05-pointers-and-initializers.typ"
#include "chapters/06-continuation-and-appendices.typ"
