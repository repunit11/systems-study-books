#import "../theme.typ": checkpoint, caution

= ローダとプロセス起動

静的リンクと動的リンクの役割が見えたら、最後にそれらが実行開始とどうつながるかを見ます。本章では `execve`、program header、interpreter、dynamic loader、`crt1.o`、`__libc_start_main` を一本の流れとして整理します。目標は、`main` が「最初に走る関数」ではないことを、手順として説明できるようになることです。

#checkpoint[
  この章の到達点は次の通りです。

  - `execve` が新しいプロセス像を作る入口だと説明できる
  - program header が loader のための写像情報だと説明できる
  - `PT_INTERP` と dynamic loader の役割を説明できる
  - `_start`、`__libc_start_main`、`main` の呼び出し順を説明できる
]

== `execve` は何を始めるか

ユーザ空間プログラムの起動は、典型的には `fork` と `execve` の組み合わせで見えますが、実際に新しい実行イメージを作るのは `execve` です。kernel は指定された ELF executable を読み、必要なメモリ領域を用意し、初期 stack を構成し、entry point へ飛べる状態を作ります。

ここで重要なのは、`execve` が単にファイルを読み込むだけではないことです。アドレス空間、初期 stack、補助ベクタ、必要なら interpreter の起動経路まで含めて、新しいプロセス像を作ります。

== program header は loader の地図

section header は linker の都合でした。起動段階で主役になるのは program header です。kernel や dynamic loader は、`PT_LOAD`、`PT_DYNAMIC`、`PT_INTERP` などの segment 情報を見て、どの範囲をどんな権限でメモリへ写像するかを決めます。

ここで section と segment の違いが改めて効きます。`readelf -S` で見える section は細かい部品の境界ですが、`readelf -l` で見える segment は起動時の写像単位です。複数の section が 1 つの loadable segment にまとめられることも普通です。

== `PT_INTERP` が意味するもの

動的リンク executable には、どの dynamic loader を使うかを示す `PT_INTERP` segment が入っています。Linux x86-64 では、典型的には `/lib64/ld-linux-x86-64.so.2` がここに入ります。kernel はこれを見て、「この executable はまず dynamic loader を経由して起動しなければならない」と判断します。

つまり、動的リンク executable では kernel が直接 `main` に近いコードへ飛ぶのではありません。まず interpreter を起動経路へ載せ、その interpreter が依存関係解決と relocation を済ませてから、最終的な entry point へ制御を渡します。

== 初期 stack に何が積まれるか

プロセス起動時の stack には、単に return address があるわけではありません。典型的には次の情報が並びます。

- `argc`
- `argv[]`
- `envp[]`
- 補助ベクタ `auxv`

`auxv` は、page size、program header の位置、entry 情報、random bytes など、runtime が初期化に使う補助情報を渡す仕組みです。glibc や dynamic loader はこの情報を参照しながら startup を進めます。ここを知っておくと、「なぜ `main(int argc, char **argv, char **envp)` の手前にこんなに多くの層があるのか」が見えやすくなります。

== `_start` は誰のコードか

実際の entry point は通常 `main` ではなく `_start` です。これは多くの場合 `crt1.o` などの startup object が提供するコードで、process 起動直後の最低限の初期化を担います。ユーザが直接書いた関数ではありませんが、C program の最初の土台として必ず通る場所です。

`_start` の役割は、すぐに何か複雑な処理をすることではありません。初期 stack から必要な情報を取り出し、glibc startup へ橋渡しし、最終的に `main` を呼べる形へ持っていくことです。つまり `_start` は「language runtime へ渡すための薄い入口」です。

== `__libc_start_main` の役割

glibc を使う典型的な C program では、`_start` は最終的に `__libc_start_main` を呼びます。この関数が、libc 側の初期化、constructor 実行、`main` 呼び出し、`main` の戻り値を受けたあとの `exit` 経路をまとめます。

この 1 段があることで、ユーザは単に `main` を書くだけで済みます。しかし裏側では、runtime 初期化、環境変数の準備、destructor 処理の登録など、言語とライブラリにとって必要な前準備が済まされています。

== `main` から先も startup の一部である

初学者は `main` が始まった時点で起動処理が終わったように感じがちですが、実際には `main` からの return も startup の一部です。戻り値は `exit status` として処理され、登録済み destructor や `atexit` handler の実行を経て、最終的にプロセス終了へ至ります。

この見方を持つと、program startup は「先頭に少しだけ付く序章」ではなく、`execve` から終了までを貫く runtime の導入部だと分かります。

== kernel loader と dynamic loader の境界

ここで境界を明確にしておくと、責務は次のように分かれます。

- kernel:
  ELF executable を開き、loadable segment と初期 stack を用意し、必要なら interpreter を起動経路へ入れる
- dynamic loader:
  shared object を読み、動的 relocation を適用し、依存関係を解決し、entry point へ渡す
- libc startup:
  `main` を呼べる状態を作り、終了経路まで面倒を見る

この分業を持っているだけで、`execve`、`ld.so`、`crt1.o`、glibc startup を一つの巨大な黒箱として恐れずに済みます。

#caution[
  本章で扱うのは Linux x86-64 の典型経路です。`static-pie`、完全静的リンク、独自 runtime、`musl` ベースの起動経路では見え方が少し変わります。ただし、program header を見て写像し、必要なら依存解決を行い、startup object を通って言語 runtime へ渡すという骨格は共通しています。
]

== この章の出口

本章の出口は、次の流れを一息で説明できることです。

1. `execve` が ELF を読む
2. program header に従って写像が準備される
3. 動的リンク executable なら interpreter が起動経路に入る
4. dynamic loader が依存解決と relocation を行う
5. `_start` が `__libc_start_main` へ橋渡しする
6. 最終的に `main` が呼ばれる

ここまでつながると、コンパイラ、linker、loader、runtime の境界がかなり整理されます。
