#import "theme.typ": *

#set document(title: "Rust OS Book")

#align(center)[
  #set text(size: 24pt, weight: "bold")
  Rust OS Book
]

#v(8pt)

Philipp Oppermann 氏の公開チュートリアル `Writing an OS in Rust` と、その周辺の `rust-osdev` エコシステムをもとに、`Boot` から `Paging` と `Heap` までを 1 冊に再構成した学習用ノートです。`compilerbook` の次に読むことを想定し、言語実装の次に「そのコードが動く場」を自分で作る流れになるように章立てしています。

#editorial_note[
  この文書は公式記事の逐語訳ではありません。公開されている章順と設計意図を尊重しつつ、単一の Typst PDF として読みやすいように再構成した版です。記事ごとの分割をそのまま写すのではなく、教材として連続して読めるように説明順序と粒度を調整しています。
]

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-freestanding-and-boot.typ"
#include "chapters/03-vga-and-testing.typ"
#include "chapters/04-interrupts.typ"
#include "chapters/05-paging-and-heap.typ"
#include "chapters/06-appendices.typ"
