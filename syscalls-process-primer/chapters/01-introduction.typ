#import "../theme.typ": editorial_note, checkpoint, caution

= はじめに

この文書は、user mode と kernel mode の境界で何が起きているのかを整理するためのノートです。`elf-linker-loader-primer` では `execve`、loader、`_start` までを扱いました。しかしその先で、ユーザコードがどうやって kernel へ入り、どうやって戻り、どうやって新しい process を作り、どうやって終了を回収するのかは別の話として残っています。`rust-os-book` もヒープまでで止まっており、その次に自然に現れるのが task、syscall、user process です。本書の役割は、その空白を埋めることです。

低レイヤ学習では、syscall と process 管理が別々の話に見えやすいですが、実際には強くつながっています。syscall は user space が kernel に仕事を頼む入口であり、process はその user space 自体を管理する単位です。`fork`、`exec`、`wait`、context switch、user stack、trap frame は、すべて「どの実行主体が、どの address space で、どの権限で走っているか」という一つの問いへ戻ってきます。

== この教材の主題

本書の主線は次の 4 点です。

1. なぜ user mode / kernel mode を分けるのか
2. syscall entry/exit で、CPU 状態と stack をどう扱うのか
3. process image と address space をどう作り替えるのか
4. `fork/exec/wait` と context switch がどうつながるのか

この順序を取る理由は、まず権限境界が見えていないと、syscall や process の役割分担がぼやけるからです。`exec` だけを見ても、その先で戻る先が user mode だと分からなければ意味が薄くなりますし、context switch だけを見ても、どの trap frame を保存しているのかが曖昧になります。

#checkpoint[
  本書を読み終えるころには、少なくとも次を説明できる状態を目指します。

  - user mode と kernel mode を分ける理由
  - syscall entry で何を保存し、どこで dispatch するか
  - `exec` が新しい address space と初期 user stack をどう用意するか
  - `fork` と context switch の違い
  - `wait` と zombie がなぜ必要なのか
]

== なぜ今これを学ぶのか

`rust-os-book` の流れで見ると、ページングとヒープまで来た時点で「次は user process を動かしたい」と自然に思います。しかしそのためには、単に新しい address space を作るだけでは足りません。特権遷移、trap frame、kernel stack、syscall entry、scheduler の都合まで一気に増えます。本書は、その増えた層を順番にほどくためのものです。

`elf-linker-loader-primer` との接続も強いです。あちらは `execve` の前後で何がロードされるかを扱いましたが、本書は「ロード後に kernel がどのように user mode へ制御を渡すか」を扱います。つまり、`_start` へ飛ぶ直前の話です。

さらに `go-runtime-primer` とも接続します。Go runtime では syscall block や `netpoll` が重要でしたが、それを深く理解するには OS 側の syscall と process の直感があるとかなり楽になります。user-space runtime が何を肩代わりし、何を kernel に依存しているかが見えるからです。

== 対象と範囲

対象は x86-64 固定です。特権レベル、trap frame、`iretq`、`syscall/sysret`、page table 切り替えといった具体例を揃えやすく、既存の `rust-os-book` と `elf-linker-loader-primer` とも自然につながるからです。

一方で、初版では次を主題にしません。

- file system や pipe
- signal と async I/O
- `epoll` や `kqueue`
- SMP 上の高度な scheduler
- Linux kernel source の完全読解

初版の目標は、`fork/exec/wait` までで process lifecycle を閉じることです。I/O は面白いですが、本筋に入れると process 本体の説明が薄くなります。

== x86-64 の説明方針

本書では、x86-64 の具体性を保ちながらも、説明は「教育用の最小 kernel モデル」に寄せます。つまり、最初に trap / interrupt 的な枠で user から kernel へ入る流れを理解し、そのうえで実際の x86-64 では `syscall/sysret` の専用経路がある、と見る方針です。

こうする理由は、`rust-os-book` で既に例外と割り込みを見ているからです。既存の感覚を活かしつつ、専用 syscall fast path が何を省略し、何を前提にしているかを見たほうが理解しやすくなります。

#caution[
  本書の toy kernel モデルは説明用です。実在 OS の細部、たとえば Linux の全 ABI や security mitigation の詳細をそのまま再現するわけではありません。ここで重視するのは、「どの情報がどの stack にあり、どのタイミングで address space が切り替わるか」です。
]

== 参照する一次資料

本書では、次の種類の資料を主に参照します。

- x86-64 の特権遷移と例外・syscall の説明
- `rust-os-book` とその周辺 crate / OSS
- `execve` と process startup の公開資料
- `go-runtime-primer` が触れている syscall / netpoll の接点資料
- 教育 OS としての xv6 など

source を直接読むときも、最初に持つべき問いは同じです。「今保存しているのは user の状態か kernel の状態か」「この切り替えは trap 由来か scheduler 由来か」です。本書はその問いを揃えることを目指します。

#editorial_note[
  process 管理は、一見すると無数の構造体と状態遷移に見えます。しかし骨格は比較的単純です。user mode を安全に走らせ、必要なときだけ kernel へ入り、必要なら別の process へ切り替える。それを実現するために trap frame、kernel stack、page table、process table が出てきます。
]

== 各章の見取り図

本書は次の順で進みます。

1. 特権レベル、trap、user mode への移行を整理する
2. syscall path を entry / dispatch / return に分けて理解する
3. process image、address space、`exec` を扱う
4. `fork`、context switch、`wait` まで process lifecycle を閉じる
5. 付録で演習、用語、次に読む source を整理する

この順序には理由があります。`fork` は魅力的ですが、その前に「戻る先の user mode」を理解していないと、process 切り替えの意味が薄くなります。したがって本書では、まず境界そのものから始めます。
