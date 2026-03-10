#import "theme.typ": *

#set document(title: "Allocator GC Primer")

#align(center)[
  #set text(size: 24pt, weight: "bold")
  Allocator GC Primer
]

#v(8pt)

ヒープ管理とガベージコレクションを、最小 allocator と最小 `mark-sweep` を軸に整理する学習用ノートです。`rust-os-book` のヒープ、`sanitizer-fuzzer-book` の allocator 差し替え、`go-runtime-primer` の allocator/GC 入口をつなぎ、メモリ管理をシリーズ横断の視点で読めるように構成しています。

#editorial_note[
  この文書は特定実装の逐語訳ではありません。OS 教材、allocator 解説、Go runtime の一次資料をもとに、`bump allocator`、free list、`mark-sweep`、compaction の関係が見えやすい順に再構成した版です。性能最適化や production 実装の全網羅ではなく、「どこで metadata を持ち、どこで reclaim するか」を追うことを優先しています。
]

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-heap-and-minimal-allocators.typ"
#include "chapters/03-size-classes-and-real-allocators.typ"
#include "chapters/04-roots-and-mark-sweep.typ"
#include "chapters/05-compaction-and-runtime-bridges.typ"
#include "chapters/06-appendices.typ"
