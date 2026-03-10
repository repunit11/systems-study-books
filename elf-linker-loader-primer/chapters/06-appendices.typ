#import "../theme.typ": editorial_note, checkpoint, caution

= 付録と次の一歩

本編では、`.o` の観察から始めて、静的リンク、動的リンク、`execve`、`_start`、`main` までを一本につなぎました。この章では、復習、観察コマンドの使い分け、演習課題、用語整理、次に読む source をまとめます。リンクとローダの学習は広がりやすいですが、まずは観察の軸を固定するのが大切です。

== 章ごとの復習ポイント

本編の核を短く戻すと、各章は次のように整理できます。

- 導入:
  `compilerbook` の先にある空白は、`.o` からプロセス起動までの層である
- ELF と `.o`:
  section、symbol、relocation があるから `.o` は「未完成な部品」として扱える
- ABI と静的リンク:
  `ABI` が部品同士の約束を決め、linker が symbol 解決と relocation 適用で実行形式を閉じる
- 動的リンク:
  shared object、`PIC`、`GOT`、`PLT`、dynamic loader によって一部の解決を実行時へ遅らせる
- 起動経路:
  `execve`、program header、`PT_INTERP`、`_start`、`__libc_start_main`、`main` が連続している

この順序を頭に置いておくと、細部を忘れても全体地図を失いにくくなります。

== 観察コマンドの使い分け

最初に使い分けたい観察コマンドは次です。

- `readelf -h`
  ELF header を見る
- `readelf -S`
  section header を見る
- `readelf -l`
  program header を見る
- `readelf -s`
  symbol table を見る
- `readelf -r`
  relocation entry を見る
- `objdump -dr`
  逆アセンブルしつつ relocation 位置を見る
- `nm`
  symbol の定義/未定義を軽く眺める
- `ldd`
  実行時依存 shared object を見る

観察の基本は、「どの層の情報を見たいか」を先に決めることです。symbol と relocation を見たいのに `objdump` だけを眺め続けると、未解決参照の意味を落としやすくなります。逆に命令と call site の位置関係を知りたいのに `readelf` だけでは不十分です。

== 小さな演習課題

本編の理解を固めるなら、次の順で短い演習を試すとよいです。

1. 単一ファイルの `main.o` を作り、`.text`, `.data`, `.bss`, `.rodata` がどれだけ現れるか観察する
2. 複数ファイルへ分け、未定義 symbol と relocation entry を確認する
3. `ar` で静的ライブラリを作り、link 順序の違いで結果が変わる例を試す
4. `-fPIC` 付き shared object を作り、`readelf -r` と `objdump -d` で `GOT/PLT` を観察する
5. `readelf -l` と `readelf -S` を見比べ、section と segment の違いを言葉で説明する
6. `_start`、`__libc_start_main`、`main` のつながりを `objdump` と symbol 表でたどる

どの課題も、巨大なアプリケーションである必要はありません。10 行前後の小さな C program で十分です。大事なのは、出力を見て「今どの層を見ているか」を言い分けることです。

#checkpoint[
  本書の理解確認として、最低限次を説明できるかを試してください。

  - なぜ `.o` には relocation が必要なのか
  - `PLT` と `GOT` はそれぞれ何のためにあるのか
  - なぜ `main` ではなく `_start` が entry point なのか
  - section header と program header は誰のための情報なのか
]

== よくあるつまずき

初学者が特につまずきやすい点を挙げます。

== `.text` を読めば実行時の全体が分かると思ってしまう

分かるのは命令列の一部だけです。実行時の写像は program header、動的依存は dynamic section、起動経路は startup object と loader まで見ないとつながりません。

== `GOT` と symbol table を混同する

symbol table は名前と属性の表です。`GOT` は実行時に使うアドレス表です。役割が違います。

== `PLT` を単なる無駄なジャンプだと思ってしまう

`PLT` は lazy binding を支える入口です。初回呼び出しと 2 回目以降で意味が変わる点が重要です。

== section と segment を混同する

section は static link の都合、segment は load の都合です。対象読者の頭の中でも、この二層を分けておく必要があります。

== `main` が最初の関数だと思ってしまう

`main` の前には `_start` と runtime 初期化があります。`main` の後にも `exit` 経路があります。

== 用語小事典

- `ELF`
  実行形式、shared object、`.o` などに使われる形式
- section
  linker が部品を扱うための単位
- segment
  loader が写像を扱うための単位
- symbol
  名前と属性を持つ参照/定義の単位
- relocation
  後で値を書き換えるための指示
- `ABI`
  バイナリ互換のための約束
- `PIC`
  ロード位置に依存しにくいコード生成方針
- `GOT`
  実行時に確定するアドレスを置く表
- `PLT`
  shared object 越しの関数呼び出しを仲介する stub 群
- dynamic loader
  shared object のロードと動的 relocation を担う実行時ローダ
- `_start`
  実行開始直後の入口
- `crt1.o`
  `_start` を提供する startup object の代表
- `__libc_start_main`
  glibc 側の startup 本体
- `auxv`
  kernel から runtime へ渡される補助情報

== 次に読むなら

本書の次に進むなら、方向は大きく 3 つあります。

第一は linker 自体を読む方向です。GNU `ld` や `lld` の source、linker script、relocation 実装を追うと、静的リンク理解が一段深まります。

第二は libc と startup を読む方向です。glibc の `csu`、`ld.so`、`musl` の startup を比較すると、`_start` から `main` への橋渡しがより具体的になります。

第三は OS 側ローダを読む方向です。Linux kernel の `execve` 経路や `binfmt_elf` を読むと、「ユーザ空間へ制御を渡す直前まで」に関心を広げられます。

== 参考資料

本書を進める際の主な資料は次です。

- `ELF gABI`
- `System V AMD64 psABI`
- `man 5 elf`
- `man 2 execve`
- `ld.so(8)`
- GNU binutils documentation
- glibc startup / dynamic loader source
- `lld` design and source comments

#editorial_note[
  本書は Linux x86-64 と GNU 系 toolchain に話を固定しました。これは一般性を捨てたのではなく、最初の 1 冊で「何が主役か」を見失わないためです。別環境へ広げるのは、この地図を持ったあとで十分です。
]

= おわりに

リンクとローダの層が見えるようになると、コンパイラ本で学んだ symbol や呼び出し規約が、急に現実の executable と結び付きます。逆に runtime や OS の本を読むときも、`PLT/GOT` や `_start` の意味が見えているだけで怖さがかなり減ります。

本書が目指したのは、仕様の全網羅ではなく、`.o` から `main` までの一本の線を持てるようにすることでした。ここまで読めたなら、linker、loader、runtime のどこへ進んでも、少なくとも地図を見失わずに歩けるはずです。
