#import "../theme.typ": editorial_note, checkpoint, caution, terminal

= 付録と次の一歩

本編では、Go ランタイムの中でも `Scheduler` と `Stack` を主線に、必要な前提知識と official source の入口を整理しました。この章では、復習、観測用の小課題、GC/allocator の最小見取り図、用語整理、次に読む source file をまとめます。

== 章ごとの復習ポイント

ここまでの内容を短く戻すと、各章の核は次のように整理できます。

- 導入:
  Go runtime は巨大な黒箱ではなく、scheduler、stack、GC、allocator、syscall/I/O 管理の責務の集合である
- 前提整理:
  `slice`、`interface`、memory model、ABI、system stack の意味を押さえると runtime source が読みやすくなる
- scheduler/stack:
  `G/M/P`、run queue、syscall block、preemption、stack growth が主線
- 観測:
  `trace`、`schedtrace`、`pprof`、`runtime/metrics` で runtime の挙動に手触りを持つ
- source guide:
  `runtime/HACKING.md` → `proc.go` → `stack.go` → `malloc.go`/GC の順で読む

この順序を持っているだけで、Go runtime の学習はかなり迷いにくくなります。

== 小さな観測課題

本編の理解を固めるなら、次の順で短い観測課題を試すとよいです。

1. goroutine を大量生成し、`GODEBUG=schedtrace=1000,scheddetail=1` で `P` と run queue を見る
2. `runtime/trace` を仕込み、sleep と busy loop を混ぜた program の時系列を見る
3. 再帰関数で stack growth を起こし、panic trace や profile を観察する
4. `runtime/metrics` で goroutine 数や heap/stack 系の指標を眺める
5. `pprof` で runtime 関数が CPU/heap profile に現れるのを確認する

これらは大きなサンプルである必要はありません。10〜20 行でも十分です。重要なのは、観測した現象を source のどこへ結びつけるかです。

== allocator と GC の最小見取り図

本書では allocator と GC を主役にはしませんでしたが、runtime 全体像として最低限の見取り図は持っておくとよいです。

- allocator:
  `mcache` が各 `P` に近い小さなキャッシュとして働き、足りなくなると `mcentral` や `mheap` から補充される
- GC:
  mark/sweep と pacer によって、application goroutine と background worker が協調して回収を進める
- write barrier:
  pointer 更新が GC の正しさと結びつくため、compiler と runtime が協調する

この 3 点だけでも、`mallocgc` や `mgc*` 系ファイルを開いたときの心理的負荷がかなり下がります。

== Go 1.26 との差分の見方

GC については `GC Guide` が Go 1.19 前提である一方、Go 1.26 では `Green Tea` GC が既定です。したがって読む順番としては、

1. `GC Guide` で mark/sweep、pacer、assist の原理を掴む
2. `Go 1.26 Release Notes` で差分を確認する
3. 必要に応じて `mgc.go` 周辺を見る

という順が安全です。guide を最新版の完全説明と見なさないことが重要です。

== 用語小事典

- `G`
  goroutine の実体
- `M`
  OS thread に対応する実行主体
- `P`
  実行に必要なローカル資源の束
- run queue
  runnable goroutine の待ち行列
- work stealing
  暇な `P` が他の `P` から仕事を盗む仕組み
- preemption
  実行中 goroutine に途中で制御を返してもらう仕組み
- goroutine stack
  小さく始まり grow する stack
- system stack
  runtime が危険な処理を行うための固定 stack
- `morestack`
  stack が足りないときの成長経路
- `netpoll`
  I/O 完了待ちと scheduler をつなぐ仕組み
- `write barrier`
  GC の正しさを保つための pointer 書き込み補助

== よくあるつまずき

== `P` がなぜ必要か腹落ちしない

thread と資源を分離し、syscall block 中でも実行資源を他へ回せるようにするためです。`P` を「CPU コアの抽象」ではなく「runtime ローカル資源の単位」と見ると理解しやすいです。

== goroutine stack と system stack の違いが曖昧

goroutine stack は各 goroutine の実行用で grow し得ます。system stack は runtime が危険な内部処理を行うための固定的な足場です。

== `trace` を見ても何が重要か分からない

最初は全部追わず、runnable/running/blocking、syscall、GC の 3 種類だけを見るとよいです。source へ戻すための観測なので、重要なラベルだけ拾えば十分です。

== GC が難しすぎる

正常です。最初から GC source を全部追う必要はありません。scheduler と stack を先に固め、その後 `GC Guide` と release notes で足場を作ってから入るほうがよいです。

== 次に読むなら

本書の次に進む方向は大きく 3 つあります。

- scheduler を深める:
  `proc.go` の syscall, netpoll, timer の細部へ進む
- stack を深める:
  `stack.go`, asm, panic/unwind, signal handling を追う
- GC/allocator を深める:
  `mallocgc`, `mcache/mcentral/mheap`, `mgcmark`, `mgcsweep`, pacer を追う

Go runtime を「理解する」には、最初の一冊で全部やり切る必要はありません。主線を 1 本持っておくと、以後の枝がかなり読みやすくなります。

== 参考資料

- The Go Memory Model
  `https://go.dev/ref/mem`
- A Quick Guide to Go's Assembler
  `https://go.dev/doc/asm`
- Diagnostics
  `https://go.dev/doc/diagnostics`
- `runtime/HACKING.md`
  `https://go.dev/src/runtime/HACKING.md`
- `runtime/proc.go`
  `https://go.dev/src/runtime/proc.go`
- `runtime/stack.go`
  `https://go.dev/src/runtime/stack.go`
- GC Guide
  `https://go.dev/doc/gc-guide`
- Go 1.26 Release Notes
  `https://go.dev/doc/go1.26`

#editorial_note[
  Go runtime は source tree の規模こそ大きいですが、入口を間違えなければ十分に読める対象です。特に `Scheduler` と `Stack` を先に押さえる戦略は、GC や allocator を後から読むときにも効きます。
]

= おわりに

Go runtime を読むために必要なのは、巨大な予備知識ではありません。何が scheduler の話で、何が stack の話で、何が GC や allocator の話かを見分けるラベルです。本書はそのラベルを揃えることを目指しました。

一度この地図を持つと、`proc.go` や `stack.go` はただ長いだけのファイルではなく、「goroutine がどう走り、どう止まり、どこで足場を切り替えるか」を説明する文書に見えてきます。そこまで来れば、あとは必要に応じて枝を伸ばしていけます。
