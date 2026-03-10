#import "../theme.typ": editorial_note, checkpoint, caution

= 付録と次の一歩

本編では、最小 allocator から始めて、size class、`mark-sweep`、compaction の直感までを一つの流れとして見ました。この章では、復習、演習、用語整理、典型的なつまずき、次に読む source をまとめます。allocator と GC は細部に沈みやすいので、復習するときも「配る」「印を付ける」「戻す」「必要なら寄せる」の 4 語へ戻ると整理しやすくなります。

== 章ごとの復習ポイント

本編の核を短く戻すと、各章は次のように整理できます。

- 導入:
  allocator と GC は、解放判断を誰が持つかが違うだけで、どちらも heap 状態管理の仕組みである
- 最小 allocator:
  metadata、alignment、free list、split/coalesce が土台
- 現実の allocator:
  size class、local cache、page 供給の三層で性能と断片化を折衷する
- `mark-sweep`:
  root set から到達可能性を辿り、mark して sweep で allocator へ戻す
- compaction と橋渡し:
  fragmentation を減らすには object 移動が欲しくなり、その代償として barrier と runtime 協調が必要になる

== 小さな演習課題

理解を固めるなら、次の順で短い演習が効きます。

1. bump allocator に alignment 丸めを入れ、なぜ 8-byte 境界が必要か説明する
2. free list allocator に split を足し、最小 block サイズの条件を明文化する
3. coalesce を足し、外部断片化が減る例と減らない例を作る
4. object graph を手で描き、root から辿って `mark-sweep` の結果を紙上で確認する
5. semi-space copying collector を図だけで追い、どの pointer を更新しなければならないか列挙する
6. `rust-os-book`、`sanitizer-fuzzer-book`、`go-runtime-primer` の各章へ戻り、allocator/metadata/root の語で読み直す

大きなプログラムである必要はありません。10 個程度の object と短い allocation/free 系列でも十分です。

#checkpoint[
  本書の理解確認として、最低限次を説明できるかを試してください。

  - なぜ free list だけでは長期利用で辛くなるのか
  - `mark-sweep` は allocator とどこで接続するのか
  - compaction が嬉しい理由と、その代償は何か
  - kernel heap と Go runtime GC の制約は何が違うのか
]

== よくあるつまずき

== 「空き総量が多ければ十分」と思ってしまう

allocator にとって重要なのは量だけでなく形です。外部断片化があると、総量が足りていても大きな要求へ応えられません。

== GC が allocator の代わりだと思ってしまう

違います。GC は reclaim 判断を自動化しますが、回収後の領域をどう管理するかは allocator の仕事です。

== root set を「グローバル変数だけ」と考えてしまう

実際には stack、register、runtime 内参照が重要です。ここを曖昧にすると collector の難しさを過小評価します。

== moving GC の大変さを「コピーコストだけ」だと思ってしまう

本質は pointer 更新と mutator 協調です。barrier や safe point が必要になる理由を見落としやすい点です。

== kernel でも user-space でも同じ collector が使えると思ってしまう

制約が違います。停止時間、外部公開ポインタ、割り込み文脈、物理メモリ近傍の扱いが大きく変わります。

== 用語小事典

- heap
  動的確保に使う領域
- allocator
  ヒープから要求サイズに応じて領域を切り出し、再利用を管理する仕組み
- object header
  サイズや mark bit などの metadata
- free list
  空きブロックをつないだ列
- split
  大きな空きブロックを要求サイズに応じて分割すること
- coalesce
  隣接空きブロックを結合すること
- internal fragmentation
  丸めにより payload の外側に生じる無駄
- external fragmentation
  空き総量はあるのに連続領域が足りない状態
- root set
  tracing GC の出発点になる参照集合
- mark bit
  到達済み object を示す印
- sweep
  到達不能 object を回収して allocator へ戻す工程
- compaction
  live object を寄せて空きを大きな塊にすること
- write barrier
  pointer 更新時に collector の整合を保つ補助処理

== 次に読むなら

本書の次に進む方向は大きく 3 つあります。

- OS 側を深める:
  `rust-os-book` のヒープ章へ戻り、より良い allocator、demand paging、user/kernel 分離へ進む
- sanitizer 側を深める:
  allocator metadata、quarantine、interceptor の視点で `sanitizer-fuzzer-book` を読み直す
- Go runtime 側を深める:
  `go-runtime-primer` の `mallocgc`, `mcache/mcentral/mheap`, `mgcmark`, `mgcsweep` へ進む

== 参考資料

本書を進める際の主要な足場は次です。

- `rust-os-book` の paging / heap 部分
- `sanitizer-fuzzer-book` の runtime と allocator 差し替え部分
- `go-runtime-primer` の allocator / GC 入口
- Go `GC Guide`
- allocator / garbage collection の一般解説資料

#editorial_note[
  allocator と GC の学習で重要なのは、特定実装の関数名を覚えることではありません。metadata がどこにあり、誰が書き換え、どのタイミングで reclaim するかを追えることです。その視点があれば、source を開いたときに「今どの層を見ているか」がかなり分かりやすくなります。
]

= おわりに

メモリ管理は、低レイヤ学習の中でも特に「全部つながっている」分野です。OS ではページ供給とヒープ初期化が必要で、allocator では metadata と断片化管理が必要で、GC では root、graph、barrier が必要になります。分野が違って見えても、見ている対象は同じ heap です。

本書が目指したのは、allocator と GC を別々の箱に入れず、一つの地図として読めるようにすることでした。ここまで読めたなら、kernel heap を改善するときも、sanitizer runtime を読むときも、Go runtime の `mallocgc` や `mgc*` を読むときも、どこで何を管理しているのかをかなり追いやすくなるはずです。
