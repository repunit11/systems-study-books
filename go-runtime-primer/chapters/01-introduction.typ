#import "../theme.typ": editorial_note, checkpoint, caution

= はじめに

この文書は、Go ランタイムの source を読むための足場を作るノートです。目標は、`runtime/proc.go` や `runtime/stack.go` を最初から全部理解することではありません。どの概念がどのファイルに対応していて、どこを読むと何が分かるのかを一本の線にすることです。

Go を普段使っていると、goroutine、channel、`go test`, `pprof`, `trace` のような道具は身近でも、その下で動いている scheduler や stack 管理は黒箱に見えがちです。しかしランタイムを読むと、黒箱の中身は「非常に大きな魔法」ではなく、いくつかの明確な責務の組み合わせだと分かります。どの goroutine をどの thread で走らせるか。stack をどう増やすか。GC と scheduler はどう協調するか。システムコールで止まった thread をどう扱うか。これらはすべて runtime の責務です。

== この教材の主題

本書の主線は `Scheduler` と `Stack` です。理由は単純で、ここが見えると Go ランタイム全体の見取り図が急に読みやすくなるからです。GC や allocator ももちろん重要ですが、それらを深く読む前に、goroutine がどうスケジュールされ、どこで止まり、どの stack で動いているのかが分かっていたほうが全体像を掴みやすいです。

この本では、次の流れで進みます。

1. まず、Go ランタイムを読むために最低限必要な言語とメモリモデルの知識を整理する
2. 次に、OS thread、stack、ABI の最低限を押さえる
3. そのうえで、`G/M/P`、run queue、preemption、system stack をまとめて理解する
4. さらに、`trace`、`pprof`、`runtime/metrics`、`GODEBUG` でそれらを観測する
5. 最後に `runtime/HACKING.md`、`proc.go`、`stack.go` へ入る読書ガイドを示す

つまり「概念の説明」と「source の入口」と「実際の観測」を分断しません。読んだ概念が手元のプログラムでどう見えるかまで一度に繋ぎます。

#checkpoint[
  本書を読み終えるころには、少なくとも次を説明できる状態を目指します。

  - goroutine が OS thread と 1:1 ではない理由
  - `G/M/P` のそれぞれが何を表すか
  - goroutine stack と system stack の違い
  - `schedule` と `findRunnable` が何をしているか
  - `go tool trace` や `GODEBUG=schedtrace` を見て scheduler の混雑を読む基本
]

== Go ランタイムを読むと何が嬉しいのか

最初の利点は、パフォーマンス問題の切り分けが良くなることです。goroutine を大量に立てたとき、どこで詰まっているのか。システムコールが多いとき、scheduler はどう振る舞うのか。GC がどこで停止し、どの程度 background worker が動いているのか。こうしたことは、ランタイムの構造を少し知るだけで trace の見え方が大きく変わります。

次の利点は、`unsafe` や `cgo`、プロファイラ、トレース、低レイヤの同期原語の見え方が良くなることです。たとえば `go:systemstack` がなぜ存在するのか、write barrier がなぜ compiler と runtime の両方にまたがるのか、panic 中にどんな stack が使われるのか、といった疑問に筋の通った答えが持てるようになります。

最後に、言語処理系としての Go の一体感が見えてきます。Go は仕様、コンパイラ、ランタイム、標準ライブラリの境界が比較的よく揃っている言語です。runtime を読むと、「goroutine は文法糖ではなく runtime の実体に支えられた概念だ」ということがよく分かります。

== 前提と範囲

読者には、Go の基本文法、goroutine、channel、`sync.Mutex`、`context`、`pprof` の存在くらいは知っていることを想定します。ただし `interface` の実体や `unsafe.Pointer`、escape analysis までは曖昧でも構いません。本書で runtime 読解に必要な範囲だけ整理します。

一方で、範囲は絞ります。次は本編の主題にはしません。

- GC 実装の細部の完全読解
- `compiler` と `ssa` パッケージの内部
- `cgo` の全体像
- signal 処理の全細部
- `Green Tea` GC の設計を source ベースで追い切ること

GC と allocator は本編後半で概観しますが、それは `proc.go` と `stack.go` を読むための補助として扱います。本書のゴールは runtime の全網羅ではなく、「まず何が重要か」を固めることです。

== 2026年3月10日時点の注意

Go の runtime は継続的に変わります。特に GC まわりは版ごとの差分が大きく、2026年3月10日時点では Go 1.26 の `Green Tea` GC が既定になっています。一方、`GC Guide` は本文中で Go 1.19 時点の GC を説明していると明記されています。したがって GC を理解するときは、「guide で原理を掴む」「release notes で最新差分を補う」を分ける必要があります。

この本では、その違いを曖昧に混ぜません。scheduler と stack は現行 source の読み方を中心に、GC は「今読むために必要な足場」と「差分注記」を分けて整理します。

#caution[
  runtime source は版ごとに細部が変わります。本書の狙いは行番号を暗記することではなく、`proc.go` や `stack.go` を読んだときに「今はこの責務の話をしている」と分かることです。関数名や構造は追えても、版差分にはある程度揺れがある前提で読むのがよいです。
]

== 参考にする一次資料

この文書は `go.dev` 上の公式資料を主参照にします。具体的には次です。

- `The Go Memory Model`
- `A Quick Guide to Go's Assembler`
- `Diagnostics`
- `runtime/HACKING.md`
- `runtime/proc.go`
- `runtime/stack.go`
- `GC Guide`
- `Go 1.26 Release Notes`

これらをそのまま並べると少し散らばって見えますが、実際には互いに強く接続しています。本書ではその接続順を先に示します。

#editorial_note[
  ランタイム読解の最初の失敗は、「とりあえず `proc.go` を開く」ことです。もちろん最終的にはそうしますが、前提のない状態で読むと `G/M/P`、preemption、system stack、sysmon、netpoll が一度に出てきて苦しくなります。本書は、その苦しさを減らすための導入です。
]

== 各章の見取り図

以下の順で進みます。

1. Go の値表現、メモリモデル、OS/ABI の最低限を整理する
2. `G/M/P`、run queue、preemption、stack growth をまとめて理解する
3. `trace`、`schedtrace`、`runtime/metrics` で手元のプログラムから観測する
4. `runtime/HACKING.md` から `proc.go`、`stack.go` へ入る順序を示す
5. 補助として allocator と GC の最小見取り図を載せる

この順序には理由があります。runtime の source は、概念だけ見ても実感が湧きにくく、逆に source だけ見ても文脈が足りません。観測を中間に挟むことで、概念と source の橋を架けます。次章ではそのための前提として、Go の値表現、メモリモデル、OS/ABI の最低限から入ります。
