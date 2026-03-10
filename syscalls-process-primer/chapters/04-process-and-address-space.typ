#import "../theme.typ": checkpoint, caution

= process と address space

syscall path が見えたら、次はその呼び出し元である process 自体を整理します。process は単なる PID ではありません。address space、kernel stack、trap frame、状態、親子関係などをまとめて持つ実行主体です。本章では、process image と `exec` を主線に、address space の切り替えと user stack 構築を扱います。

#checkpoint[
  この章の到達点は次の通りです。

  - process が持つ最小状態を列挙できる
  - address space 切り替えが process 管理の中心だと分かる
  - `exec` が「新しい process を作る」のではなく「既存 process の image を差し替える」と説明できる
  - 初期 user stack に何を置くかを説明できる
]

== process は何を持つか

最小モデルでは、process は少なくとも次を持ちます。

- PID
- 実行状態
- page table / address space
- kernel stack
- trap frame
- 親子関係
- 終了コード

ここで trap frame が process 構造体の一部として出てくるのは自然です。なぜなら process が kernel へ入ったときの user 側文脈を表しているからです。scheduler が後でその process を再開したいなら、trap frame をどこかに保持しなければなりません。

== address space が process を分ける

複数 process を持つとは、単に複数の `rip` を持つことではありません。どの仮想アドレスが何へ写っているか、つまり page table まで含めて process ごとに持つことです。これがあるから、同じ 0x400000 という user address でも、別 process では別の物理ページを指せます。

この意味で process 管理の中心は address space 管理です。`fork` も `exec` も、結局はどの page table を使い、どの user memory を見せるかの話に戻ります。

== user stack をどう作るか

`elf-linker-loader-primer` で見たように、program startup には `argc`, `argv`, `envp`, `auxv` などが初期 stack に載ります。toy kernel ではそこまで全部を再現しなくても構いませんが、「user mode に渡す最初の stack が空ではない」という点は重要です。

最小モデルでも次の発想は持ちたいです。

1. user stack 領域を map する
2. 引数文字列や `argv` 配列を user memory へ置く
3. user `rsp` をその先頭へ向ける
4. user `rip` を entry point へ向ける

これがあるから `exec` は単なる page table 差し替えではなく、「新しい image を起動可能な形に整える」処理になります。

== `exec` は何をするか

`exec` は新しい process を作りません。既存 process の実行イメージを差し替えます。この一点は極めて重要です。PID は通常そのままで、親子関係も引き継ぎます。しかし user memory、user stack、entry point、program image は新しくなります。

この操作を最小化すると、`exec` の仕事は次のようになります。

1. 新しい executable を開いて読み込む
2. 新しい user address space を作る
3. segment を map し、必要なら page を埋める
4. 初期 user stack を作る
5. trap frame の user `rip/rsp` を新 image に向け直す

つまり `exec` は、「次に user mode へ戻ったときの世界」を丸ごと差し替える操作です。

== kernel stack と trap frame の置き場所

process の user image を差し替えても、kernel stack と process 管理構造そのものは kernel 側に残ります。この分離が大事です。kernel は user memory を捨てても、自分がその process を管理するための足場は捨てません。だから `exec` 後も同じ PID の process として扱えます。

この視点を持つと、「user memory は process の一部だが process そのものではない」と分かります。process は user image より一段広い概念です。

== scheduler と process 状態

この段階で最低限持っておきたい process 状態は次です。

- runnable
- running
- blocked / sleeping
- zombie

本格的な scheduler を作らなくても、この 4 つを持つだけで `wait` や context switch をかなり説明しやすくなります。`exit` 後すぐに process 構造体を消せない理由も、zombie を入れると自然に見えます。

#caution[
  `exec` を「新しい process を作る syscall」だと覚えると、`fork` との役割分担が崩れます。`fork` は実行主体を複製し、`exec` は image を入れ替える。この分離が Unix 系 process モデルの核心です。
]

== この章の出口

ここまでで process image と address space は見えました。次章ではそれを複製し、切り替え、終了を回収する話へ進みます。`fork`、context switch、`wait` がそこで一つにつながります。
