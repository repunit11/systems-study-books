#import "../theme.typ": checkpoint, caution, terminal

= 観測しながら理解する

runtime の概念は、文章だけで理解しようとすると少し乾きやすいです。scheduler も stack も、実際にプログラムを走らせたときにどう見えるかを一度観測すると理解が定着しやすくなります。この章では `go tool trace`、`pprof`、`runtime/metrics`、`GODEBUG` を使って、runtime の振る舞いを手元で観測するための最小導線をまとめます。

#checkpoint[
  この章では次を押さえます。

  - `trace` は scheduler の時系列を見る道具だということ
  - `pprof` は資源消費の偏りを見る道具だということ
  - `runtime/metrics` は定常状態の指標を見る入口だということ
  - `GODEBUG=schedtrace` は scheduler の荒い健康診断として便利だということ
]

== `go tool trace`

`trace` は runtime の時系列イベントを追うための道具です。goroutine の生成、blocking、syscall、network wait、GC、STW などが時間軸で見えます。scheduler を理解したいときに最も強い入口で、`G/M/P` の動きや goroutine の詰まり方を視覚的に捉えやすいです。

実際には、短いプログラムへ `runtime/trace` を仕込み、出力を `go tool trace` で開きます。

```go
f, _ := os.Create("trace.out")
trace.Start(f)
defer trace.Stop()
```

この一手間で、「goroutine を 1000 個立てたが本当に同時に進んでいるのか」「syscall 中に他の goroutine はどう動いたか」といった疑問が時間軸で見えるようになります。

== 何を見るとよいか

最初は細かいイベント名を全部追う必要はありません。まず見るべきは次です。

- goroutine が runnable から running へ移る流れ
- syscall へ入ったときの thread 側の変化
- GC 周期の始まりと終わり
- thread 数と runnable goroutine の関係

この観点だけでも、scheduler が単に round-robin しているのではなく、かなり多くの状態遷移を扱っていることが見えてきます。

== `GODEBUG=schedtrace`

`schedtrace` は、一定周期で scheduler の概要を stderr へ吐く簡易観測です。trace ほど視覚的ではありませんが、セットアップが軽く、手元の小さな検証には非常に便利です。

```text
GODEBUG=schedtrace=1000,scheddetail=1 go run main.go
```

この出力からは、`gomaxprocs`、idle `P`、run queue の長さ、thread 数などをざっくり見られます。まずは「暇な `P` があるのに runnable goroutine が多いのか」「thread が増えすぎていないか」といった荒い健康診断に使うとよいです。

== `pprof`

`pprof` は CPU 時間やメモリ使用量の偏りを見る道具です。scheduler そのものの状態遷移を直接見るわけではありませんが、「runtime にどれくらい時間を使っているか」「GC や allocator にどの程度コストが乗っているか」を知るのに役立ちます。

特に次の観点が useful です。

- CPU profile で runtime 関数の比率を見る
- heap profile で allocation の偏りを見る
- goroutine profile で block している場所を見る

runtime source を読む前に `pprof` を一度触っておくと、「この関数は trace ではここに見え、profile ではこう見える」と多面的に理解しやすくなります。

== `runtime/metrics`

`runtime/metrics` は、GC、scheduler、memory、assist などの定常指標を programmatic に取るための入口です。trace や profile が一回の観測の道具だとすれば、metrics は継続的な状態把握に向いています。

scheduler の観点では、「goroutine 数」「GC worker の挙動」「heap と stack の大きさ」といった数字を、過度に runtime source へ潜る前にざっくり把握できます。これにより、source 中の構造体や counters が「何のために存在するか」を実感しやすくなります。

== 短い観測用プログラムを持つ

runtime 読解を進めるなら、短い観測用プログラムをいくつか持っておくのが有効です。たとえば次のようなものです。

- goroutine を大量生成して channel 待ちさせる
- `time.Sleep` と busy loop を混ぜる
- network I/O を使って block/unblock を見る
- 深い再帰で stack growth を起こす

これらは本に大きな実装を載せる必要はありません。10〜20 行の小さな断片で十分です。重要なのは、「この現象を見たいからこのプログラムを走らせる」という対応があることです。

== stack を観測するには

stack 自体は scheduler より視覚化しにくいですが、再帰や大きなフレームを持つ関数を使うと grow の気配が見えやすくなります。また panic 時の stack trace、goroutine dump、`pprof` の goroutine profile も役立ちます。

ここで意識したいのは、「stack の変化は常に目に見えるイベントとは限らない」ことです。scheduler のように timeline に出にくくても、panic trace、recursion、system stack への切り替えに注目すると、存在感が見えてきます。

== `trace` と source の接続

観測の価値は、結果を source のどこへ戻せるかにあります。たとえば trace で runnable goroutine が長く溜まっているなら、`findRunnable` や run queue の取り回しを読みたくなります。深い再帰で stack に関連する挙動が気になるなら、`morestack` と `stack.go` を読みたくなります。

つまり観測は、「source を読む理由」を具体化するための道具です。本書で中盤に置いているのはそのためです。

== 何を観測したら読み始めるか

目安として、次のどれか一つでも観測できれば次章へ進めます。

- `trace` で goroutine の runnable/running/blocking を見た
- `schedtrace` の出力から `P` や run queue の存在を確認した
- 再帰や panic から stack の存在を意識できた
- `pprof` で runtime 側の関数が profile に現れるのを見た

全部を揃える必要はありません。大事なのは、`proc.go` や `stack.go` を「見たことのある現象の説明書」として読める状態にすることです。

#caution[
  観測ツールはどれもオーバーヘッドを持ちます。trace や profile の結果は、無計測時の実行と完全に同じではありません。ここでは絶対値より、状態遷移や偏りの傾向を見る道具だと理解しておくのが安全です。
]

== 次章への橋渡し

ここまでで、概念と観測の土台ができました。次章では、いよいよ `runtime/HACKING.md`、`proc.go`、`stack.go` をどの順で読むとよいか、関数単位の読書ガイドとしてまとめます。加えて `mallocgc` と GC まわりの最小入口も置きます。
