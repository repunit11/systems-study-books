#import "../theme.typ": checkpoint, caution

= root と mark-sweep

allocator が「どう配るか」を担当するなら、GC は「いつ戻せるか」を判断します。本章では最小 tracing GC として `mark-sweep` を扱います。主題は fancy な並行化ではなく、root set、到達可能性、mark bit、sweep の役割分担をはっきりさせることです。

#checkpoint[
  この章の到達点は次の通りです。

  - root set が tracing GC の出発点だと説明できる
  - mark phase と sweep phase の役割を説明できる
  - object header と mark bit がなぜ必要か分かる
  - `mark-sweep` の利点と弱点を allocator の観点から説明できる
]

== なぜ tracing が必要か

manual free の世界では、不要かどうかはプログラマが知っています。しかし pointer が複雑に共有されるプログラムでは、その判断は簡単ではありません。参照カウントは局所的には分かりやすいですが、cycle を扱うのが苦手です。そこで tracing GC は、「今生きている根から到達できるか」を基準に object の生死を決めます。

この視点は非常に強いです。解放のタイミングを個々の pointer 更新に散らさず、定期的に「全体を見回して到達不能を回収する」ことができます。

== root set はどこから来るか

tracing GC は空から始められません。起点になるのが root set です。典型的には次が root になります。

- スタック上の pointer
- global / static 変数
- register にある live pointer
- runtime 自身が保持する特別な参照

この時点で GC は allocator だけの話ではなくなります。stack layout、global data、calling convention、compiler が知る liveness 情報まで関わってくるからです。`go-runtime-primer` で stack と GC が強く結び付くと言っていたのもこのためです。

== object graph を辿る

root が決まったら、次は object graph を辿ります。各 object の header や type 情報から内部の pointer field を見つけ、まだ未訪問なら mark し、さらにその先を辿ります。最小モデルでは「すべての object は pointer 配列を持つ」と仮定しても十分です。

ここで重要なのは、GC が object の中身を何も知らなくてよいわけではないことです。少なくとも「どの語が pointer か」は知る必要があります。だから production collector は compiler や runtime metadata と密接に結び付きます。

== mark bit は何をしているか

mark phase では、訪問済み object に印を付ける必要があります。その最小形が mark bit です。header の 1 bit でも、外部 bitmap でも構いません。重要なのは、「到達したかどうか」を sweep phase まで持ち越せることです。

mark bit を持つことで、collector は 2 回目の訪問を避けられますし、sweep 時には「印がない object は回収可能」と判断できます。つまり mark bit は、到達可能性を短い metadata として保存する役割を持ちます。

== sweep は allocator へ戻す処理

mark phase が終わったら、heap 全体を走査して印の付いていない object を回収します。ここで allocator と GC が再び合流します。回収した領域は最終的に free list や class ごとの空き集合へ戻さなければ意味がありません。

したがって sweep は、単に object を捨てる処理ではありません。reclaim した領域を allocator の vocabulary へ戻す処理です。ここが見えると、GC は allocator の上に載った別世界ではなく、空き領域生成の別経路だと理解できます。

== stop-the-world の意味

最小 `mark-sweep` では、GC 中に object graph が書き換わられると整合が崩れるので、いったん world を止めるのが分かりやすいです。これが stop-the-world です。すべての mutator を止め、root を固定し、mark と sweep を済ませてから再開します。

これは遅く見えますが、教材としては非常に良い単純化です。並行化を入れる前に、「なぜ barrier や safe point が必要になるのか」を見せやすいからです。

== `mark-sweep` の良い点

最小 `mark-sweep` の利点は次の通りです。

- cycle を扱える
- object を動かさなくてよい
- allocator と比較的素直に接続できる
- object の実アドレスを保ちやすい

特に「動かさなくてよい」は、C 風の pointer world や kernel 近傍ではかなり大きい利点です。アドレス固定を期待するコードと相性がよいからです。

== `mark-sweep` の弱い点

一方で弱点もはっきりしています。

- heap 全体走査が必要
- sweep 後も外部断片化が残る
- 停止時間が伸びやすい
- root や pointer map が曖昧だと conservative になりやすい

allocator の章で fragmentation を見てきたので、ここで「回収できても形が悪い」ことの痛みが理解しやすくなります。`mark-sweep` は reclaim しても compact しません。だから長寿命 heap では外部断片化が残ります。

== どこをテストするか

最小 `mark-sweep` のテストでは、次を見たいです。

- root から到達できる object が残るか
- cycle を持つが root から切れた object が回収されるか
- sweep 後に free list が再利用できるか
- mark bit の初期化忘れやリセット忘れがないか

GC は「何も起きないこと」が成功に見えやすいので、reachable / unreachable を明確に分けた小さな graph で確認するのが重要です。

#caution[
  最小実装では stack や register の pointer map をかなり雑に扱いがちです。そこを曖昧にすると、「本来死んでいる object を root 扱いして回収されない」方向のバグが出やすくなります。教材としては許容できますが、production collector で compiler 協調が必要になる理由はここにあります。
]

== この章の出口

ここまでで最小 `mark-sweep` は見えました。しかし allocator の章を思い出すと、まだ問題が残っています。回収できても、heap の形は悪いままかもしれません。次章では compaction と moving GC の発想を見て、その代償として必要になる runtime 協調へ進みます。
