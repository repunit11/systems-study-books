#import "../theme.typ": checkpoint, caution

= ヒープと最小 allocator

allocator の話を始めるには、まずヒープを特別な領域として見る必要があります。スタックは LIFO で自動的に巻き戻りますが、ヒープはそうではありません。いつ確保し、いつ解放するかはプログラムの論理に依存します。そのため allocator は、単にメモリを返す関数ではなく、「ヒープのどこが使われていて、どこが空いているか」を保持する metadata の管理者になります。

#checkpoint[
  この章の到達点は次の通りです。

  - ヒープ allocator が metadata を必要とする理由を説明できる
  - alignment と object header が allocator 設計へどう効くか分かる
  - bump allocator と free list allocator の違いを説明できる
  - split と coalesce が fragmentation の対策だと説明できる
]

== ヒープは「使えるようにしただけ」では足りない

`rust-os-book` では、ヒープとして使う仮想アドレス範囲を写像し、その上に bump allocator を置くところまで進みました。これは非常に重要な一歩ですが、まだ allocator の世界では入口に過ぎません。ヒープが「存在する」ことと、「長く使える」ことは別だからです。

最初の数回の確保だけなら、単にポインタを前へ進めるだけでも十分です。しかし、解放、再利用、異なるサイズ、長寿命オブジェクトと短寿命オブジェクトの混在が始まると、それだけではすぐに破綻します。allocator はヒープを 1 回使うための仕組みではなく、長く生きるプロセスの中で繰り返し配るための仕組みです。

== alignment は地味だが支配的

allocator を最小実装するときでも、alignment を無視できません。CPU や ABI は、特定の型が特定境界に載っていることを前提に高速化や正しさを組んでいます。そのため、ユーザが 3 バイト欲しいと言っても、allocator は 8 バイトや 16 バイト境界へ丸めて返すことがあります。

この丸めは無駄に見えますが、実際には重要な契約です。

- misaligned access を避ける
- object header と payload の境界を保つ
- free list node や mark bit 参照を簡単にする

つまり alignment は、性能の小技ではなく metadata を安定して扱うための前提でもあります。

== metadata はどこに置くか

allocator は空き領域を管理するための情報をどこかに持たなければなりません。典型的には次の 2 パターンがあります。

- 管理対象ブロックの前後に header/footer を埋める
- 外部表を持ち、payload とは別に管理する

学習用として分かりやすいのは前者です。たとえば各ブロックの先頭に「サイズ」「使用中かどうか」を置けば、split や coalesce が説明しやすくなります。ただしこの設計は、header の破壊が allocator 全体を壊す危険も持ちます。この性質は sanitizer 本の metadata 管理ともつながっています。

== bump allocator

bump allocator は、最も単純な allocator の一つです。現在位置ポインタを持ち、要求サイズを alignment に丸めて、その分だけ前進させます。

```c
void* bump_alloc(size_t n) {
  n = align_up(n, 8);
  if (cur + n > heap_end) return NULL;
  void* p = cur;
  cur += n;
  return p;
}
```

この方式の利点は圧倒的に単純なことです。lock も free list も不要で、最初のヒープ接続には非常に向いています。`rust-os-book` が最初にこれを採るのも自然です。

一方で欠点も明確です。個別解放ができず、長く動かすと使い切るだけです。つまり bump allocator は、「配る」ことしかしていません。「戻す」ことがありません。

== free list allocator

個別解放を入れたくなると、最初に自然なのが free list です。空いているブロックを linked list でつなぎ、要求サイズに合うブロックを探して返します。ここで allocator は初めて「空き領域の集合」を持つことになります。

free list を導入すると、allocator の仕事は次のように増えます。

1. 空きブロック探索
2. 必要なら大きなブロックの分割
3. 解放時に free list へ戻す
4. 隣接空きブロックの結合

この時点で allocator は、単なるポインタ進行器ではなく小さなメモリ管理システムです。

== split と coalesce

要求サイズより大きい空きブロックをそのまま返すと、内部断片化が増えます。そこで大きなブロックを 2 つに分け、片方だけを返す split が必要になります。一方、解放を繰り返すと、小さな空きブロックがばらばらに散らばります。そこで隣接する空きブロックをまとめる coalesce が必要になります。

この二つは allocator 設計の基本中の基本です。split がないと大きい空きブロックを無駄にし、coalesce がないと長期的に外部断片化が積み上がります。

== fragmentation は何が辛いのか

fragmentation には大きく 2 種類あります。

- 内部断片化:
  alignment や size class の都合で、ユーザが使わない余白を抱える
- 外部断片化:
  空き総量は足りているのに、連続した大きな塊が足りず割り当てに失敗する

初学者は「空きバイト数」の総量だけを見がちですが、allocator にとって重要なのは形です。100 バイト空いていても、1 バイトずつ 100 個に割れていたら 64 バイト要求には応えられません。compaction が嬉しくなるのは、この外部断片化が見えてからです。

== テストで見るべきこと

allocator の最初のテストは、単に 1 回動くかでは足りません。最低限、次を見たいです。

- 異なるサイズで確保したときに alignment が守られるか
- `alloc` → `free` → `alloc` で領域が再利用されるか
- split 後に残りブロックが壊れていないか
- 隣接ブロック解放後に coalesce されるか

allocator は小さな off-by-one や header サイズ計算ミスで簡単に壊れます。したがって「少数の大きいテスト」より、「短い系列を何度も揺さぶるテスト」のほうが効きます。

#caution[
  最小 allocator を実装するとき、payload サイズだけを見て block 全体サイズを忘れるバグが頻発します。header、alignment padding、split 後の残り最小サイズを必ず別々に考えると崩れにくくなります。
]

== この章の出口

ここまでで allocator の最小骨格は見えました。しかし実際の runtime は、free list を 1 本持つだけでは済みません。サイズ偏り、競合、局所性、ページ単位供給の問題が出てきます。次章では size class とより現実的な allocator の発想を見ます。
