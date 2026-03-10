#import "../theme.typ": checkpoint, caution

= 共有ライブラリと動的リンク

静的リンクが「ビルド時に全部を閉じる」方法だとすると、動的リンクは「一部の解決を実行時まで遅らせる」方法です。本章では共有ライブラリ、`PIC`、`GOT`、`PLT`、遅延束縛を通して、動的リンクで誰が何をしているのかを整理します。

#checkpoint[
  この章の到達点は次の通りです。

  - shared object が再利用可能な部品である理由を説明できる
  - `PIC` が必要になる理由を説明できる
  - `GOT` と `PLT` の役割の違いを説明できる
  - 動的リンカが `DT_NEEDED` や relocation を見て依存関係を解決すると理解する
]

== なぜ共有ライブラリが必要か

静的リンクだけでもプログラムは動きます。しかし、巨大な標準ライブラリを各 executable へ毎回取り込むと、ディスク使用量も更新のコストも増えます。そこで、実行時に共通部品として読み込める shared object が使われます。

このとき重要なのは、shared object は単に「別ファイルに分けた `.text`」ではないことです。実行時にどのアドレスへ載るかは固定されませんし、複数プロセスで共有されることもあります。だからこそ、位置に依存しにくいコードと、実行時の relocation を支える仕組みが必要になります。

== `PIC` は何を守っているか

`PIC` は position-independent code の略です。共有ライブラリは、毎回同じ仮想アドレスへ載るとは限りません。したがって、コード中へ絶対アドレスを直接焼き込む形では扱いにくくなります。`PIC` は、相対参照や indirection を多用して、ロード位置が変わっても動くようにする方針です。

ここで大事なのは、`PIC` は「絶対アドレスを一切使わない魔法」ではないということです。必要なアドレス参照は残ります。ただし、それをコード中へ直接散らさず、`GOT` のような表へ集めることで、実行時の修正箇所を限定します。

== `GOT` はアドレスの表

`GOT` は Global Offset Table の略です。名前から global variable 専用に見えますが、実際には「実行時に確定するアドレスを間接参照するための表」と考えるのが分かりやすいです。shared object や executable のコードは、必要な先を直接知らず、まず GOT のスロットを参照します。

この 1 段の indirection にはコストがありますが、得られるものも大きいです。ロード位置が変わっても、dynamic loader が修正すべき場所を GOT へ集中させやすくなります。つまり `PIC` と `GOT` は別の概念ですが、実用上は強く結び付いています。

== `PLT` は関数呼び出しの踏み台

`PLT` は Procedure Linkage Table の略です。関数呼び出しを shared object 越しに行うとき、call site から直接最終アドレスへ飛ぶのではなく、いったん `PLT` の stub を経由する形が使われます。初回呼び出しではこの stub が dynamic loader へ制御を渡し、symbol 解決後は対応する GOT エントリが更新され、2 回目以降は直接近い形で飛べるようになります。

ここで混同しやすいのは、`PLT` と `GOT` の役割です。

- `GOT`
  実行時に確定するアドレスを置く表
- `PLT`
  関数呼び出しを一度受けて、必要なら解決処理へ渡す stub 群

関数呼び出しでは両者が協調しますが、同じものではありません。

== 遅延束縛とは何か

動的リンクでは、全 symbol を起動直後に解決する方法と、必要になるまで遅らせる方法があります。後者が lazy binding です。`PLT` の初回呼び出し時に dynamic loader が symbol を探し、対応する GOT スロットを書き換えることで、その後の呼び出しを速くします。

遅延束縛が腹落ちすると、`PLT` stub の奇妙な見た目にも意味が出てきます。あれは単なる余計なジャンプではなく、「まだ解決されていないなら resolver を呼び、解決済みならそのまま本体へ飛ぶ」ための分岐点です。

== dynamic loader の責務

Linux x86-64 では、典型的には `ld-linux-x86-64.so.2` が dynamic loader です。`execve` 後、kernel は `PT_INTERP` が示す interpreter を起動経路へ組み込みます。dynamic loader は主に次の仕事をします。

1. 必要な shared object を読み込む
2. 各 object の依存関係を解決する
3. dynamic relocation を適用する
4. 必要なら `PLT/GOT` を初期化する
5. 最終的な entry point へ制御を渡す

静的リンクでは build 時にやっていた仕事の一部を、ここで実行時に行っているわけです。

== `DT_NEEDED` と dependency graph

共有ライブラリ依存は、`ELF` の dynamic section に並ぶ `DT_NEEDED` から見えてきます。これは「この executable または shared object は、実行時にこの shared object を必要とする」という宣言です。dynamic loader はこれをもとに dependency graph をたどり、必要な object をロードしていきます。

重要なのは、linker が build 時に dependency 情報を埋め込み、loader が実行時にそれを読むという分業です。動的リンクは「全部実行時の魔法」ではなく、build 時と実行時の共同作業です。

== 静的リンクとの違いを一文で言うと

ここまでの違いを一文で縮めると、次のようになります。

- 静的リンク: build 時に symbol 解決と relocation をほぼ閉じる
- 動的リンク: 一部の symbol 解決と relocation を実行時まで持ち越す

この「いつ解決するか」の違いが、shared object、`PIC`、`GOT`、`PLT`、dynamic loader を必要にしています。

#caution[
  `GOT` は symbol table ではありません。symbol 名を見て検索する表ではなく、解決済みアドレスを置くための表です。名前解決そのものは dynamic loader 側の責務であり、`GOT` はその結果を高速に再利用するための入れ物です。
]

== この章の出口

本章の出口は、`PLT/GOT` を「ややこしい x86-64 の小細工」ではなく、「実行時解決を支える分業」として見られることです。ここまで来ると、次は自然に「では kernel と dynamic loader は、どうやって最初の 1 命令目まで運ぶのか」という疑問になります。次章では `execve` から `_start` までを追います。
