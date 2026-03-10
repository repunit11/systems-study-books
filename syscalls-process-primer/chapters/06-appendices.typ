#import "../theme.typ": editorial_note, checkpoint, caution

= 付録と次の一歩

本編では、特権境界から始めて、syscall path、process image、`fork/exec/wait`、context switch までを一本につなぎました。この章では、復習、演習、つまずき、用語集、次に読む source をまとめます。process 管理は枝が多いですが、最初は「どの mode で走っているか」「どの stack を使っているか」「どの address space を見ているか」の 3 つへ戻ると整理しやすいです。

== 章ごとの復習ポイント

本編の核を短く戻すと、各章は次のように整理できます。

- 導入:
  今の空白は `execve` の先と user/kernel 境界である
- user mode:
  trap frame と kernel stack が user 文脈を安全に持ち運ぶ
- syscall:
  entry、dispatch、`copyin/copyout`、return で構成される
- process:
  address space、kernel stack、trap frame を束ねた実行主体
- lifecycle:
  `fork` は複製、`exec` は image 差し替え、`wait` は終了回収、context switch は current/next の切り替え

== 小さな演習課題

理解を固めるなら、次の順で短い演習が効きます。

1. user mode に入るための最低限の trap frame を紙上で書き出す
2. `write` syscall の引数検証で、どこで `copyin` が必要かを列挙する
3. `exec` 時に新しい user stack へ何を置くかを図にする
4. `fork` 後に親と子で何が同じで何が違うかを表にする
5. `wait` で zombie が必要になる理由を、親子 2 process の時系列で説明する
6. `go-runtime-primer` の syscall block と、本書の kernel scheduler を比較する

大きな実装である必要はありません。短い状態遷移図と register / stack 図のほうが理解に効くことも多いです。

#checkpoint[
  本書の理解確認として、最低限次を説明できるかを試してください。

  - なぜ user stack と kernel stack を分けるのか
  - syscall が普通の関数呼び出しではない理由
  - `exec` が新 process 生成ではない理由
  - context switch と trap return の違い
  - `wait` と zombie の関係
]

== よくあるつまずき

== `exec` が child を作る syscall だと思ってしまう

違います。child を作るのは `fork`、image を差し替えるのが `exec` です。

== syscall return と context switch を同じものだと思ってしまう

前者は同じ process の user 文脈へ戻る出口、後者はどの process を次に走らせるかの切り替えです。

== user pointer を kernel でそのまま触ってしまう

`copyin/copyout` が必要です。ここを抜くと保護境界の意味が壊れます。

== zombie を「ただのリーク」と思ってしまう

zombie は親が終了状態を回収するまで残る設計上の待機状態です。不要な残骸ではなく、`wait` のための情報保持です。

== trap frame を「割り込み専用構造」と思ってしまう

user/kernel 境界で文脈を保存する枠として見ると、syscall、例外、初回 user entry までまとめて理解しやすくなります。

== 用語小事典

- user mode
  制限付き権限で動く通常の program の実行モード
- kernel mode
  privileged operation を実行できるモード
- trap
  例外、割り込み、syscall を含む kernel entry の一般形
- trap frame
  user 文脈の保存結果
- kernel stack
  kernel で処理するときの stack
- address space
  仮想アドレスから物理ページへの対応全体
- syscall
  user が kernel に仕事を依頼する入口
- `copyin/copyout`
  user memory と kernel memory の安全なコピー
- `fork`
  process を複製する syscall
- `exec`
  process の実行 image を差し替える syscall
- `wait`
  child の終了を回収する syscall
- zombie
  実行は終わったが、親の回収待ちで情報が残っている process 状態
- context switch
  CPU 上の current process を別 process へ切り替える処理

== 次に読むなら

本書の次に進む方向は大きく 3 つあります。

- OS 側を深める:
  `rust-os-book` の続きとして user memory 保護、copy-on-write、file descriptor、file system へ進む
- ELF / startup 側を深める:
  `elf-linker-loader-primer` と往復し、`execve` の前後や user stack 構築をより詳しく追う
- runtime 側を深める:
  `go-runtime-primer` へ戻り、syscall block、`netpoll`、user-space scheduler との役割分担を見る

== 参考資料

主な足場は次です。

- `rust-os-book` の割り込み・ページング・次に伸ばす方向
- `elf-linker-loader-primer` の `execve` / startup 部分
- `go-runtime-primer` の syscall / scheduler 接点
- x86-64 の特権遷移資料
- xv6 などの教育 OS

#editorial_note[
  process 管理を読むときに大切なのは、構造体名より保存点を見抜くことです。今保存しているのが user 側の状態か kernel 側の状態か、戻り先が同じ process か別 process か。その 2 問が分かれば、長い source でもかなり読みやすくなります。
]

= おわりに

user/kernel 境界は、低レイヤ学習の中でも特に「複数の本が合流する場所」です。ELF と loader はここへ process を渡し、OS はここで保護と切り替えを行い、runtime はこの境界の上で scheduler や GC を組み立てます。

本書が目指したのは、syscall と process を別々の箱に入れず、一つの lifecycle として見られるようにすることでした。ここまで読めたなら、OS 側の実装を伸ばすときも、runtime が syscall とどう付き合うかを見るときも、かなり地図を持って進めるはずです。
