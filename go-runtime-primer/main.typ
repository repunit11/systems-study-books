#import "theme.typ": *

#set document(title: "Go Runtime Primer")

#align(center)[
  #set text(size: 24pt, weight: "bold")
  Go Runtime Primer
]

#v(8pt)

Go ランタイムの source を読むために必要な前提知識を、`Scheduler` と `Stack` を主線に整理した学習用ノートです。Go を日常的に書いているが `runtime/proc.go` や `runtime/stack.go` はまだ重く感じる、という段階から読み始められるように構成しています。

#editorial_note[
  この文書は Go 公式文書や `runtime` source の逐語訳ではありません。`go.dev` 上の一次資料をもとに、概念の接続が見えやすい順に再構成した版です。実装の全網羅ではなく、「どこから読めば runtime が怖くなくなるか」を主目的にしています。
]

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-go-prerequisites.typ"
#include "chapters/03-scheduler-and-stack.typ"
#include "chapters/04-observability.typ"
#include "chapters/05-source-reading-guide.typ"
#include "chapters/06-appendices.typ"
