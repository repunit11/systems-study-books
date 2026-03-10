#import "../theme.typ": checkpoint, caution, editorial_note

= source reading guide

この章では、Go ランタイム source を「どこから読むか」という順序を決めます。闇雲に `runtime` ディレクトリを開くと重すぎますが、入口を絞ればかなり読みやすくなります。本書では `runtime/HACKING.md` を最初の案内板にし、そこから `proc.go`、`stack.go`、最後に `malloc.go` と GC 周辺へ入る順序を取ります。

#checkpoint[
  この章では次を固めます。

  - 最初に読むべきファイルとその理由
  - `proc.go` のどの関数が scheduler の中心か
  - `stack.go` で何を追えばよいか
  - GC/allocator はどの粒度で触れれば十分か
]

== 1. `runtime/HACKING.md`

最初に読むべきなのは `runtime/HACKING.md` です。このファイルは runtime の内部常識を短くまとめたもので、`G/M/P`、goroutine stack、system stack、malloc まわりの作法、write barrier に触れてはいけない場面など、source を読む前に必要な前提が載っています。

ここでの読み方は「全部覚える」ではありません。次の見出しだけ先に押さえると十分です。

- `G`, `M`, `P`
- `stacks`
- scheduler に関する説明
- runtime code で特に注意するルール

このファイルを読むだけで、`proc.go` の一文字名が少し人間的になります。

== 2. `runtime/proc.go`

`proc.go` は scheduler の中心です。ただし最初から全部追う必要はありません。入口は次の関数で固定するとよいです。

- `schedule`
- `findRunnable`
- `execute`
- `newproc` 周辺
- syscall での出入りに関わる箇所

まずは「goroutine を作る」「runnable を探す」「実行する」「syscall で一時的に止まる」の流れだけを読むのがよいです。細かな timer や `netpoll` の枝にすぐ潜らず、中心線を先に作ります。

== `schedule` をどう読むか

`schedule` は次の runnable goroutine を決めるループだと捉えます。重要なのは、そこに全ての policy が直接書いてあるわけではなく、実際の探索は `findRunnable` や run queue helper、steal、poll へ分散していることです。したがって `schedule` は「司令塔」、`findRunnable` は「仕事探し」と分けて読むのが整理しやすいです。

また、`schedule` は thread、`P`、goroutine の関係が最も露骨に見える場所でもあります。「なぜ `P` が必要か」は、この関数の前後を見るとかなり腑に落ちます。

== `findRunnable` をどう読むか

`findRunnable` では、local queue、global queue、steal、timer、netpoll といった複数の候補から runnable な仕事を探します。ここは枝が多いので、最初は「仕事の供給源一覧」として読むのがよいです。つまり、

- 手元の `P` に仕事はないか
- 全体共有 queue にないか
- 他の `P` から steal できないか
- I/O 完了待ちから戻った仕事はないか

という順で読むと整理しやすいです。個々の分岐を暗記する必要はありません。

== `runtime/stack.go`

`stack.go` の入口は、まず goroutine stack が grow し得ることを念頭に置くことです。そのうえで、次のテーマを追います。

- stackguard チェック
- `morestack`
- stack copy / grow
- system stack を使う場面

stack の章で重要なのは、単にコピー手順を追うことではありません。なぜ runtime が stack を自分で管理しなければならないか、なぜ system stack が必要かを source の中で確認することです。

== `morestack` の見方

`morestack` は、stack が足りないときの逃げ道です。ここを読むと、compiler-generated prologue と runtime の接続がよく見えます。つまり stack growth は runtime 単体の話ではなく、関数呼び出し規約と結びついた設計だと分かります。

この視点は、ランタイム全体の読み方にも効きます。Go の機能は spec、compiler、runtime の境界で成立しているものが多く、stack はその典型です。

== 3. `malloc.go`

本書の主線は scheduler/stack ですが、runtime を読む以上 allocator の入口は触れておいたほうがよいです。`malloc.go` では `mallocgc` を中心に、size class、tiny allocator、`mcache` / `mcentral` / `mheap` の関係を「名前が怖くない程度」に整理します。

ここで目指すのは、malloc subsystem を完全に理解することではありません。`runtime` で allocation が発生したとき、どの層のキャッシュや共有構造が関わるのかを荒く掴むことです。

== 4. GC 周辺

GC は本書では補助章です。入口としては次を押さえれば十分です。

- `GC Guide` で mark/sweep と pacer の原理を掴む
- `mgc.go`、`mgcmark.go`、`mgcsweep.go` の責務分担を見る
- Go 1.26 の release notes で `Green Tea` GC の差分を確認する

重要なのは、`GC Guide` の説明対象が Go 1.19 時点であることを忘れないことです。guide は原理の足場として使い、最新版との差分は release notes と source で補います。

#editorial_note[
  GC をいきなり source から読むのはやや重いです。scheduler/stack よりも変数名や phase 分岐が多く、歴史的差分もあります。本書では「runtime の全体像を壊さない程度に読む」位置付けに留めます。
]

== 実際の読書順

本書のおすすめ順は次で固定します。

1. `runtime/HACKING.md`
2. `runtime/proc.go` の `schedule`
3. `runtime/proc.go` の `findRunnable`
4. `runtime/stack.go` の stack growth 関連
5. `runtime/malloc.go` の `mallocgc`
6. `GC Guide`
7. `runtime/mgc.go` 周辺
8. `Go 1.26 Release Notes`

この順は、概念が先に積み上がり、観測と source の対応が取りやすい順です。

== 読み方のコツ

runtime source は、最初から top-to-bottom に読む必要はありません。むしろ、次の読み方が有効です。

- 役割単位で読む
- 1 回で全部理解しようとしない
- trace や `schedtrace` と対応付ける
- 「これは scheduler の話」「これは stack の話」とラベルを持つ

この読み方をすると、ファイルの長さに圧倒されにくくなります。

== この段階で説明できるようになりたいこと

この章まで来たら、少なくとも次が言えれば十分です。

- `proc.go` は scheduler の中心で、`schedule` と `findRunnable` が入口
- `stack.go` は goroutine stack と system stack の関係を見る場所
- `malloc.go` と GC 周辺は runtime 全体の補助線
- official docs と source は役割を分けて読むと進みやすい

#caution[
  runtime source は内部 API なので、版が変わると関数の細部や helper の構成が変わります。したがって、「この関数のこの行が重要」と固定しすぎないほうがよいです。関数の責務を掴む読み方のほうが長持ちします。
]

== 次章への橋渡し

最後の章では、ここまでの復習、観測用の短い題材、GC/allocator の最小見取り図、用語集、次に読むべき source file をまとめます。
