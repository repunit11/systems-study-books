#import "../theme.typ": checkpoint, caution, terminal

= Go ランタイムを読む前の前提整理

runtime source を読むときに最初につまずくのは、scheduler そのものより前提知識のズレです。goroutine は知っていても、`interface` の実体、escape analysis、memory model、system stack の意味が曖昧だと、個々のコードは追えても全体像が繋がりません。この章では、runtime 読解に必要な前提だけを絞って整理します。

#checkpoint[
  この章では次を押さえます。

  - Go の値が「見た目通りの箱」ではなく、runtime のデータ構造に支えられていること
  - `happens-before` と同期原語の意味を、runtime の視点で捉え直せること
  - thread、stack、calling convention の最低限が `proc.go` と `stack.go` 読解の前提になること
]

== `slice`、`string`、`interface` を実体として捉える

普段 Go を書くとき、`slice` や `string` や `interface` は高水準な値として扱います。しかし runtime を読むには、それらがどういう形の値として存在しているかを意識したほうがよいです。

- `slice`
  ポインタ、長さ、容量を持つ
- `string`
  ポインタと長さを持つ
- `interface`
  型情報とデータへの参照を持つ

これらを理解しておくと、stack growth や write barrier や escape analysis がなぜ必要かが見えやすくなります。値の見た目が高水準でも、runtime は最終的にポインタとメタデータの整合性を管理しているからです。

== `unsafe.Pointer` は何を破るのか

runtime source では `unsafe` が頻繁に出てきます。これは単なる低レイヤ好みではなく、通常の型システムだけでは表しにくい内部データ構造や ABI 境界を扱う必要があるからです。`unsafe.Pointer` を理解するうえで重要なのは、「何でも自由にしてよい」ではなく、「GC と型追跡の前提を自分で保証する」ことです。

ランタイム内部では、ポインタの生存、stack 移動時の更新、write barrier の適用など、GC と深く結びついた事情があります。したがって `unsafe` の意味は、C 風の生ポインタ操作というより、*GC と協調するための危険な抜け道* と捉えるほうが実情に近いです。

== escape analysis が runtime と繋がる理由

escape analysis はコンパイラの話に見えますが、runtime 読解にも重要です。変数が stack に置かれるのか heap に逃がされるのかで、GC の対象になるか、pointer map の扱いがどう変わるか、stack growth 時にどう更新されるかが変わるからです。

この点を押さえると、「なぜこの値は heap にあるのか」「なぜ stack 上の一時オブジェクトが GC と関係するのか」が見えやすくなります。コンパイラの判断が runtime の責務に直結している、という接点です。

== `defer`、`panic`、`recover`

`defer`、`panic`、`recover` は表面上は言語機能ですが、runtime の支えなしには成立しません。特に stack unwinding、panic chain、system stack への切り替え、reporting などは runtime の仕事です。これらの細部を今すぐ追う必要はありませんが、「制御フローが通常の return だけで進むわけではない」という前提は持っておく必要があります。

これは stack の章で効きます。stack は単なる配列ではなく、panic、preemption、GC scan など、多くの機構の舞台だからです。

== Go のメモリモデル

`The Go Memory Model` を読む理由は、アプリケーションの正しさだけではありません。runtime そのものが、どの同期で何を保証しているかを読むためです。`happens-before` を理解していないと、run queue への push/pop、状態遷移、atomic field の意味が見えにくくなります。

特に意識したいのは次です。

- goroutine 間の順序は自動では保証されない
- channel、mutex、atomic は順序保証の道具である
- scheduler が切り替えることと、メモリ順序が保証されることは別問題である

この 3 つが混ざると runtime のコードは読みづらくなります。スケジューリングと同期は別層であり、両方を区別して読む必要があります。

== thread と stack の最小前提

Go runtime を読むには OS の thread モデルを最低限知っている必要があります。Go は goroutine を user-space scheduler で multiplex しますが、その下では依然として OS thread が実行主体です。さらに syscalls や cgo に入ると、thread のブロッキングや pinning が scheduler に影響します。

stack についても、ただ「関数呼び出しで積まれる領域」というだけでは足りません。特に意識したいのは次です。

- 各 thread は OS 由来の stack を持つ
- 各 goroutine は小さく始まる可動 stack を持つ
- runtime の一部処理は goroutine stack ではなく system stack で動く

この区別が見えるだけで、`stack.go` の見え方はかなり変わります。

== calling convention と Go assembler

`A Quick Guide to Go's Assembler` を読む価値は、アセンブリを書くためだけではありません。prologue/epilogue、レジスタ、stack frame、ABI、`TEXT` 宣言、引数と戻り値の置き方が分かると、runtime source に出てくる低レベル部分が急に怖くなくなります。

特に stack growth や preemption では、関数の入口で stackguard を見る、必要なら `morestack` へ飛ぶ、といった処理が重要です。これは言語仕様だけ読んでいても見えません。最低限の ABI 感覚があると、なぜそのコードが必要かが理解しやすくなります。

== `go:systemstack` の意味

runtime 内部では、goroutine stack で動くと危険な処理があります。たとえば stack growth の最中にさらに stack を必要とする処理、scheduler の核心、GC や signal に近い処理です。そうした場所では system stack を使う必要があります。

ここで system stack を「特別な別世界」と思わないことが大切です。要するに、「今の goroutine の可動 stack に依存すると危ないから、固定的で runtime 管理しやすい stack で動く」というだけです。この感覚を持つと `go:systemstack` が自然に見えます。

== `netpoll` と syscalls を理解する最低限

Go の scheduler を理解するとき、syscall と I/O 待ちは避けて通れません。goroutine が syscall で止まると、その goroutine を動かしていた thread も詰まることがあります。そのとき scheduler は別 thread と `P` を使って他の仕事を進める必要があります。さらに network I/O は `netpoll` を通じて待ち合わせと再開が行われます。

本書では `netpoll` の source を深追いしませんが、「I/O 待ちは scheduler 設計に直結している」という認識は前提として持ちます。

== ここで押さえるべきキーワード

この章を終える時点で、最低限次の言葉が曖昧でなければ十分です。

- `happens-before`
- `atomic`
- goroutine stack
- system stack
- escape analysis
- `unsafe.Pointer`
- ABI
- syscall block

これだけでも、次章の `G/M/P` や stack growth の話にかなり入りやすくなります。

#caution[
  ここで挙げた前提を完璧にする必要はありません。重要なのは、runtime source を読んでいて「あ、これはメモリモデルの話だ」「ここは system stack の話だ」とラベル付けできることです。完全な予習より、概念の見出しを持っておくほうが効きます。
]

== 次章への橋渡し

ここまでで、Go の値表現、メモリモデル、OS/ABI の最小前提は揃いました。次章ではいよいよ `G/M/P`、run queue、preemption、goroutine stack、system stack をまとめて見て、`proc.go` と `stack.go` の見取り図を作ります。
