#import "../theme.typ": checkpoint, caution, editorial_note

= `Scheduler` と `Stack`

Go ランタイムを読むうえで最初の核は `Scheduler` と `Stack` です。goroutine は OS thread と 1:1 ではありませんし、stack も固定長ではありません。この二つが分かると、`proc.go` と `stack.go` の大半は「巨大な謎」ではなく、「複数の制約を解くための設計」に見えてきます。

#checkpoint[
  この章では次を理解することを目標にします。

  - `G/M/P` の役割分担
  - run queue と work stealing の意味
  - preemption と syscall block が scheduler にどう効くか
  - goroutine stack と system stack の違い
  - stack growth と `morestack` の目的
]

== `G/M/P` とは何か

Go runtime を初めて読むと、`G`, `M`, `P` という一文字名に戸惑います。意味は次の通りです。

- `G`
  実行対象そのもの。goroutine の状態、stack、実行位置などを持つ
- `M`
  machine の略で、OS thread に対応する実行主体
- `P`
  processor の略で、実行に必要なローカル資源の束

重要なのは `P` です。多くの初学者は `G` と `M` だけでよさそうに見えますが、Go runtime は `P` を介することで、ローカル run queue、allocator cache、timer などの資源を thread から少し切り離しています。これにより work stealing や syscall 中の資源の受け渡しが整理しやすくなります。

== なぜ `P` が必要なのか

もし goroutine を thread へ直接束ねるだけなら、local queue や cache も thread ごとに持てそうです。しかし thread は syscall や cgo で簡単にブロックします。そのたびに実行資源まで一緒に止まると、他の goroutine を動かしづらくなります。

そこで `P` を独立資源として持ち、thread が止まったら `P` を別の `M` へ渡せるようにします。これが Go runtime の非常に重要な発想です。OS thread を実行器、`P` を実行許可とローカル資源の単位として分けることで、goroutine scheduler を柔軟にしています。

== run queue

各 `P` はローカル run queue を持ちます。新しく runnable になった goroutine は、まずどこかの `P` の local queue へ入ります。これにより lock 競合を減らし、近くの仕事を近くで回しやすくします。全体共有 queue もありますが、常にそこを主に使うわけではありません。

この構造は、CPU scheduler や work stealing runtime でよく見る設計と似ています。共有 queue を 1 個だけにすると競合が増え、ローカルだけだと負荷が偏ります。そこで local queue を基本にしつつ、足りないときは stealing で均します。

== `schedule` と `findRunnable`

`proc.go` を読むときの入口は `schedule` と `findRunnable` です。細部は多いですが、役割を荒く見ると次のようになります。

- `schedule`
  今この `M` が次にどの `G` を走らせるか決める中心ループ
- `findRunnable`
  local/global queue、netpoll、timer、steal などを見て runnable な仕事を探す

この二つを先に押さえると、周辺の関数が「どこで新しい `G` を enqueue し、どこでそれを拾うか」という関係で見えてきます。逆にここを押さえないと、個々の helper 関数が何のためにあるのか見えにくくなります。

== work stealing

ある `P` が暇で、別の `P` が多くの runnable goroutine を抱えているなら、仕事を盗んだほうが全体が進みます。これが work stealing です。Go runtime は local queue を基本にしつつ、必要に応じて他の `P` から仕事を分けてもらいます。

この仕組みがあるおかげで、goroutine 生成が偏っても scheduler 全体が極端に崩れにくくなります。もちろん万能ではありませんが、thread ごとの固定割り当てよりずっと柔軟です。

== syscall で止まると何が起きるか

goroutine が syscall に入ると、その goroutine を実行していた `M` も OS 側で止まり得ます。しかし runtime は全体を止めたくありません。そこで、その `M` が持っていた `P` を切り離して別の `M` へ回し、他の runnable goroutine を進められるようにします。

ここで `P` の分離が効きます。もし thread と実行資源が一体なら、syscall で thread が止まるたびにスケジューリング資源も失われます。`P` を介しているからこそ、Go は blocking syscall と user-space scheduling を両立しやすくなっています。

== preemption

goroutine を cooperative に走らせるだけだと、長く CPU を握り続ける goroutine が他の goroutine を飢えさせる危険があります。そこで runtime は preemption を入れ、必要なら途中で実行権を返してもらいます。

Go の preemption は OS の割り込みと完全に同じではありません。safe point や stack check と協調しながら、runtime が goroutine を止めやすい場所で止めます。この「どこでも即停止できるわけではない」という感覚は重要です。GC の停止や stack scan も safe point と深く関係するからです。

== goroutine stack は小さく始まる

各 goroutine に最初から巨大 stack を割り当てると、軽量 thread としての利点が薄れます。そこで Go は小さな stack から始め、必要になったら成長させます。これが goroutine stack の設計です。

固定 stack ではなく可動 stack を持つということは、runtime が stack growth、stack copy、pointer 更新、GC scan を扱う必要があることを意味します。つまり stack は単なるメモリ領域ではなく、runtime の主要管理対象です。

== `morestack` と stackguard

関数呼び出しの入口では、今の stack に十分な空きがあるかを確認する必要があります。足りなければ `morestack` のような経路へ入り、stack を増やしてから再実行します。これが `stackguard` チェックの基本的な意味です。

ここで面白いのは、stack check が「関数 prologue の一部」として言語実装に組み込まれていることです。つまり compiler と runtime が協調しないと成立しません。runtime だけ見ても、なぜ `morestack` が必要かは半分しか分かりません。

== system stack

goroutine stack は grow し得る可動 stack です。一方で runtime の一部処理は、その上で動くと危険です。たとえば stack growth の途中でさらに stack growth が必要になるような処理、scheduler の重要部分、signal や GC の一部などです。そのため runtime は system stack を使います。

system stack を理解するときは、「goroutine stack より偉い stack」ではなく、「runtime が自分自身の足場を確保するための固定 stack」と捉えるのがよいです。`go:systemstack` は、その足場へ明示的に切り替える印です。

== stack growth と pointer

stack が成長するとき、ただ新しい大きい領域を確保してバイト列をコピーすれば終わりではありません。stack 上のポインタやフレーム境界、GC が見る pointer map などと整合が取れていなければいけません。ここで runtime と compiler の協調が再び重要になります。

この点が見えると、stack は「各 goroutine にくっついた単純な配列」ではなく、「GC と ABI と scheduler の接点」として見えてきます。

== `runtime.HACKING.md` の位置づけ

`runtime/HACKING.md` は source を読む前の見取り図として非常に有用です。`G/M/P`、goroutine stack、system stack、malloc ルール、write barrier 禁止領域など、runtime 独特の常識が短くまとまっています。本書で先にこれらを文章で整理しているのは、まさにこのファイルを読みやすくするためです。

#editorial_note[
  `proc.go` の中身を先に全部追いかけるより、「`P` はローカル資源の束」「syscall 中は `P` を他へ渡せる」「goroutine stack は grow する」「危ない処理は system stack でやる」という 4 点を固めたほうが、結果的に読む速度が上がります。
]

== scheduler と stack を一緒に学ぶ理由

この二つは別の話に見えて、実際には強く結びついています。preemption は stack check と関係し、GC scan は stack map と関係し、system stack への切り替えは scheduler と深く関係します。したがって「まず scheduler だけ」「あとで stack」はあまり効率がよくありません。本書で同じ章に置くのはそのためです。

#caution[
  runtime source の変数名や helper 関数は版ごとに変わることがあります。しかし `G/M/P` の責務分担、stack growth、system stack、syscall block といった設計の核は比較的安定しています。まずは核を掴むのが先です。
]

== 次章への橋渡し

ここまでで概念の見取り図はできました。次章では `trace`、`pprof`、`runtime/metrics`、`GODEBUG=schedtrace` などを使って、scheduler と stack の振る舞いを実際のプログラムから観測する方法を整理します。source を読む前に観測を挟むことで、概念に手触りを持たせます。
