#import "../theme.typ": checkpoint, caution, editorial_note

= compaction と runtime への橋

`mark-sweep` を理解したあとに自然に出る疑問は、「回収できても heap の形が悪いなら、詰め直せばよいのではないか」です。その発想が compaction です。本章では copying / compaction の直感を押さえたうえで、moving GC がなぜ compiler、runtime、barrier、ABI と密接に結び付くのかを整理します。最後に Go runtime と kernel heap へ戻ります。

#checkpoint[
  この章の到達点は次の通りです。

  - compaction が fragmentation 対策だと説明できる
  - moving GC が pointer 更新と barrier を必要とする理由を説明できる
  - Go runtime が allocator と GC をどう分業しているかの見取り図を持てる
  - kernel 側で moving GC が採りにくい理由を説明できる
]

== なぜ compaction が欲しくなるのか

`mark-sweep` は回収後も object をその場に残します。そのため、長く動く heap では外部断片化が積み上がりやすくなります。空き総量は足りていても、大きな連続領域が作れないことがあるわけです。allocator 側で coalesce しても、live object が点々と残っていれば限界があります。

compaction は、この問題を「live object を寄せて空きを大きな塊にする」ことで解決しようとします。つまり GC が reclaim だけでなく、配置の改善まで担うわけです。

== copying collector の最小像

compaction の最小モデルとして分かりやすいのが semi-space copying collector です。heap を from-space と to-space に分け、live object だけを to-space へコピーし、終わったら役割を入れ替えます。こうすると compaction は自動的に起こり、allocation も bump pointer で速くできます。

この設計の魅力は強いです。

- allocation が速い
- fragmentation が基本的に出ない
- live object だけをなぞるので sweep 不要

しかし代償も明確です。object が動くので、参照元の pointer を全部直さなければなりません。

== moving GC が難しくなる瞬間

object を動かすなら、GC は少なくとも次を保証しなければなりません。

- root set 内の pointer を新アドレスへ更新する
- heap 内 object の pointer field を更新する
- mutator が古いアドレスを握り続けないようにする

ここで compiler と runtime の協調が急に重要になります。どの field が pointer か、どの stack slot が live か、いつ mutator を止めるか、実行中に pointer 更新をどう追いつかせるかが問題になるからです。write barrier や read barrier は、まさにこの更新の正しさを支える仕組みです。

== 世代別 GC の直感

多くの object は短命である、という経験則を使うのが generational GC です。若い世代を頻繁に、古い世代をまれに回収すると、全体コストを抑えやすくなります。ただし世代間参照を追うために remembered set や write barrier が必要になります。

本書では generational GC の実装には入りませんが、ここで見ておきたいのは「collector を速くしようとすると metadata と barrier が増える」という一般原理です。production GC が大きくなるのは、そのためです。

== Go runtime へ戻す

`go-runtime-primer` で触れた `mcache/mcentral/mheap` は allocator 側の骨格でした。GC 側では mark/sweep と pacer がその上へ載り、background worker や assist が協調します。本書の視点から見ると、Go runtime の全体像は次のように縮小できます。

- allocator:
  小さい object を size class ごとに速く配る
- GC:
  到達不能性に基づいて reclaim し、必要な pacing をかける
- barrier:
  pointer 更新と collector の整合を保つ

これだけでも `mallocgc` や `mgcmark` 周辺を読む心理的負荷はかなり下がります。名前は多くても、解いている問題はここまで見てきたものの延長だからです。

== kernel 側で moving GC が難しい理由

kernel は allocator を持ちますが、一般に moving GC とは相性が良くありません。理由は複数あります。

- 生ポインタや物理アドレスに近い前提が多い
- 割り込み文脈や停止時間の制約が厳しい
- デバイスやページテーブルが固定アドレス的に扱われる場面がある
- compiler と runtime の全面協調を導入しにくい

つまり kernel 側は、「allocator は必要だが、collector が自由に object を動かす世界ではない」ことが多いです。ここが Go runtime との大きな対比になります。

== sanitizer runtime との接点

sanitizer runtime は GC ではありませんが、metadata を別に持ち、allocation block の状態を追跡するという点では近縁です。quarantine は collector の回収待ち集合ではないものの、「すぐには再利用せず状態を保持する」という発想は似ています。こうして見ると、allocator、GC、sanitizer はいずれも heap の状態機械を違う目的で持っていると言えます。

#editorial_note[
  production GC や production allocator を読むと、ポリシーの違いに目が行きがちです。しかし骨格は比較的単純です。配る、印を付ける、戻す、必要なら寄せる。そのうえで barrier、cache、pacing、OS 協調が積み上がります。本書で骨格を先に押さえる理由はそこにあります。
]

#caution[
  moving GC は理論上きれいでも、外部へ露出した生ポインタや ABI 境界が多い環境では急に難しくなります。collector の設計は、heap の内部だけで完結せず、言語と runtime の約束全体で決まると考えるのが安全です。
]

== この章の出口

allocator と GC を一緒に見ると、production runtime が大きな黒箱ではなく「配る」「回収する」「寄せる」「更新を追跡する」という層の重なりに見えてきます。次章では、ここまでを復習し、演習課題、つまずき、次に読む source をまとめます。
