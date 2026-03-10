#import "../theme.typ": checkpoint, caution

= size class と現実の allocator

free list allocator は allocator の本質をよく見せてくれますが、現実の runtime はそれだけでは足りません。サイズの偏り、断片化、スレッド競合、ページ供給、キャッシュ局所性といった事情が入り、設計は一段複雑になります。本章では size class と局所キャッシュの発想を足し、現実の allocator が何を最適化しているかを整理します。

#checkpoint[
  この章の到達点は次の通りです。

  - size class が探索コストと断片化の折衷だと説明できる
  - slab/segregated free list の利点を説明できる
  - local cache と central heap の役割分担を説明できる
  - kernel heap、user-space allocator、sanitizer runtime の違いを言い分けられる
]

== free list 一本では何が起きるか

サイズの違うブロックが同じ list に混ざると、探索コストが高くなり、split/coalesce の頻度も増えます。さらに小さい要求のために大きいブロックを削り続けると、長期的に断片化が悪化します。ここで size class という考え方が必要になります。

size class は、要求サイズをいくつかの箱に丸めて管理する方法です。たとえば 8, 16, 32, 64 byte といった粒度で class を切り、同じ class の object は同じような大きさのスロットから取るようにします。これにより探索は速くなり、metadata も単純化できます。その代わり、丸めによる内部断片化は増えます。つまり speed と space の折衷です。

== slab / segregated free list

size class を実装しやすい代表的な形が slab や segregated free list です。大きなページや span を class ごとのスロット集合として切り、その中の空きスロットを管理します。こうすると、同じ class の object は同じ layout を共有するため、split/coalesce を毎回考えなくて済みます。

この方式が嬉しいのは次の点です。

- 探索がほぼ class 選択だけで済む
- metadata を class ごとに持ちやすい
- 同じ大きさの object が集まるので局所性が良い
- free 時の処理が比較的単純になる

Go runtime の `mcache/mcentral/mheap` にも、この「サイズ別にまとまりを持つ」という発想が強く出ています。

== local cache と central 管理

実際の runtime では、毎回グローバルな heap 管理構造を lock していると遅くなります。そこで thread または実行資源に近い位置へ local cache を持ち、不足したときだけ central 管理から補充します。

この分割は非常に重要です。

- local cache:
  よく使う小さな object を速く配る
- central allocator:
  class ごとのまとまりを供給する
- page heap:
  さらに大きな単位で OS からページを受け取る

`go-runtime-primer` の `mcache`、`mcentral`、`mheap` はまさにこの構造です。`P` ごとに近い cache を持つ理由も、allocator を通すとかなり理解しやすくなります。

== OS からの供給単位

allocator が無限にブロックを作れるわけではありません。最終的には OS から page 単位で供給を受ける必要があります。user-space allocator なら `mmap` や `brk`、kernel なら frame allocator や page allocator に戻ります。つまり allocator の最上流には、より粗い粒度のメモリ管理がいます。

この層構造は `rust-os-book` ときれいにつながります。

- page/frame allocator が大きな塊を供給する
- heap allocator がその塊を object サイズへ切り分ける

この二層を分けて考えるだけで、「ヒープ確保は allocator だけでは済まない」という話が allocator 側からも見えるようになります。

== sanitizer runtime との接点

`sanitizer-fuzzer-book` の runtime は、`malloc` 差し替えと shadow 更新を持っていました。あれは allocator を再発明しているように見えて、実際には allocator の metadata が検査装置にとっても重要だという例です。

sanitizer が欲しい情報は次のようなものです。

- 実確保サイズ
- user payload の開始位置
- redzone 幅
- 解放済みか quarantined か

これは allocator にとっても自然な情報です。つまり sanitizer runtime は、allocator の責務に検査用 metadata を足したものとして理解すると読みやすいです。

== kernel heap は何が違うか

kernel heap と user-space allocator は、解く問題が似ていても前提が違います。

- kernel は page fault や割り込み文脈を強く意識する
- `malloc` 失敗時の回復や panic 方針が重い
- moving GC のような強い再配置は採りにくい
- allocator 自体のバグがシステム全体に直結する

このため、kernel 側では比較的保守的な allocator が好まれやすく、停止時間や再配置コストの高い手法は導入しづらくなります。ここは次章の GC と対比すると面白い点です。

== real allocator をどう縮小して捉えるか

学習用としては、現実の allocator を次の三層へ縮小して捉えると分かりやすいです。

1. class ごとの小さい空きスロット集合
2. 不足時に class へ塊を補充する central 管理
3. さらにその上で page 単位供給を受ける粗い heap

この三層が見えると、production allocator の source を開いても「名前は違うが、どの層の仕事をしているのか」が見えやすくなります。

#caution[
  size class を入れると、探索コストは減りますが内部断片化は必ず増えます。allocator は常に何かを得る代わりに何かを失う設計です。万能なポリシーはない、という感覚を早めに持っておくと比較がしやすくなります。
]

== この章の出口

ここまでで allocator 側の現実的な制約はかなり見えました。次はようやく「不要になった object をどう知るか」という GC の側へ入れます。tracing GC は allocator と別物ではなく、解放判断を自動化した再利用装置として見ると整理しやすいです。
