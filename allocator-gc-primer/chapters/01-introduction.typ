#import "../theme.typ": editorial_note, checkpoint, caution

= はじめに

この文書は、ヒープ管理とガベージコレクションを一つの流れとして整理するためのノートです。低レイヤ学習では allocator と GC が別々の話に見えがちですが、実際にはどちらも「どのメモリ領域が今使われていて、どこを再利用できるか」を管理する仕組みです。違うのは、解放のタイミングを誰が決めるかです。allocator は要求に応じて領域を切り出し、GC は到達不能性を根拠に領域を回収します。本書の役割は、その二つを一本の地図に載せることです。

既存の 5 冊との関係で見ると、この本はかなり中央に位置します。`rust-os-book` では、ヒープ用ページを写像して `GlobalAlloc` をつなぐところまで進みました。しかし、その先にある fragmentation、free list、size class、reclaim は本格的には扱っていません。`sanitizer-fuzzer-book` では `malloc` 差し替えと shadow 更新が主題でしたが、そこでも allocator metadata の設計が前提になっています。`go-runtime-primer` では `mallocgc` と GC へ入る足場だけを置きましたが、その手前にある「allocator と collector をどんな役割分担で見るか」は別の本として切り出す価値があります。

== この教材の主題

本書の主線は次の 4 点です。

1. ヒープ allocator はどの metadata を持ち、どうやって空き領域を再利用するのか
2. fragmentation、alignment、size class がなぜ必要になるのか
3. root set と object graph を使う `mark-sweep` がどのように回収を行うのか
4. moving GC や production allocator が、OS・runtime・ABI の制約とどう接続するのか

この順序を取る理由は、GC を理解する前に allocator の制約が見えていたほうが、collector の設計判断がかなり読みやすくなるからです。たとえば compaction が嬉しい理由は fragmentation が見えて初めて腹落ちしますし、write barrier の必要性は「pointer を動かしたい」という欲求が先に分かっていたほうが自然です。

#checkpoint[
  本書を読み終えるころには、少なくとも次を説明できる状態を目指します。

  - bump allocator と free list allocator の違い
  - split、coalesce、fragmentation が何を意味するか
  - root set、mark bit、sweep の役割分担
  - moving GC が pointer 更新や runtime 協調を必要とする理由
  - kernel heap と Go runtime allocator/GC が同じ問題を別の制約下で解いていること
]

== なぜ allocator と GC を一緒に学ぶのか

allocator だけを見ると、「要求サイズに応じて空き領域を返す仕組み」と説明できます。しかし長く走るプログラムでは、それだけでは足りません。どのオブジェクトがもう不要なのかを知らなければ、空き領域は増えません。逆に GC だけを見ると、「到達不能オブジェクトを回収する仕組み」と説明できますが、回収した領域をどう再利用するかは allocator の設計に戻ってきます。つまり両者は、回収と再配分の両輪です。

この接点は、既存本を横断するとよりはっきり見えます。OS ではヒープを最初に使えるようにするだけでも大仕事でした。sanitizer では allocation block の metadata と quarantine が必要でした。Go runtime では `mcache` や `mheap` と GC worker が協調します。形は違っても、どれも「メモリの所有状態を metadata として管理している」という点で共通しています。

== 対象と範囲

本書は Linux x86-64 を暗黙の背景に置きますが、説明の中心は特定の ABI や OS 依存挙動ではありません。最小のヒープモデルを使い、allocator と GC の原理がどこで OS や runtime の制約にぶつかるかを見ます。

一方で、次は初版の主題にはしません。

- 並行 GC、incremental GC、read barrier の詳細実装
- 世代別 GC の tuning と production pacer
- jemalloc, tcmalloc, mimalloc の詳細比較
- precise stack map の完全実装
- finalizer、weak reference、ephemeron の設計

これらは重要ですが、最初の 1 冊で全部やると焦点が散ります。初版の目標は、allocator と `mark-sweep` の骨格をつかみ、その先の source 読解や OS 実装へ進む土台を作ることです。

== 2026年3月11日時点の注意

GC や allocator の一次資料は、実装の細部が版ごとにかなり変わります。特に Go runtime の GC は、`GC Guide` が古い版を前提にしている一方、現行版では差分が増えています。本書ではその差分をすべて吸収しようとはしません。代わりに、版差分に振り回されにくい概念を主線に置きます。size class、local cache、mark bit、root scan、fragmentation、compaction といった骨格は比較的安定しています。

#caution[
  allocator と GC は、教科書的な最小モデルと production 実装の距離がかなり大きい分野です。本書の疑似実装は、そのまま実戦投入するためではなく、source を読んだときに「今どの問題を解いているのか」を見失わないための地図として読んでください。
]

== 参照する一次資料

本書では、次の種類の資料を主に参照します。

- OS 教材におけるヒープ allocator と frame/page allocator の説明
- Go runtime の `mallocgc`, `mcache/mcentral/mheap`, `mgc*` 周辺
- sanitizer runtime が allocator 差し替えと quarantine を持つ理由の説明
- 一般的な allocator / GC 解説資料

特定実装へ寄せ過ぎると視野が狭くなり、逆に一般論だけだと既存本との接続が弱くなります。そこで本書では、まず最小モデルを作り、そのあとに `rust-os-book`、`sanitizer-fuzzer-book`、`go-runtime-primer` へ戻す構成にします。

#editorial_note[
  GC を理解するときに最初から production collector を読むのは重すぎます。逆に allocator を完全に無視して GC だけ追うと、「なぜ sweep 後の領域管理が必要か」「なぜ compaction が嬉しいか」が曖昧になります。本書はその間を埋める位置付けです。
]

== 各章の見取り図

本書は次の順で進みます。

1. ヒープの前提、alignment、最小 allocator を整理する
2. size class と real allocator の発想を導入する
3. root set と `mark-sweep` を最小 tracing GC として組み立てる
4. compaction と moving GC の発想を見たうえで、Go runtime や kernel heap へ戻る
5. 付録で演習、用語、つまずき、次に読む source を整理する

この順序には理由があります。GC は魅力的ですが、その前に allocator の失敗モードを知らないと、回収戦略の意味が半分しか見えません。したがって本書では、まず「どう配るか」から始めます。
