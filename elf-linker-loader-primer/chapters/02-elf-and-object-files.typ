#import "../theme.typ": checkpoint, caution

= ELF とオブジェクトファイル

リンクとローダの話を始めるには、まず観察対象を小さく固定する必要があります。本章では、単一の C ファイルと、外部関数呼び出しを含む複数ファイルの最小例を頭に置きながら、`.o` の中に何が入っているかを整理します。主題は「完成した実行ファイルを読むこと」ではなく、「まだ未完成な部品に、どのような情報が残されているか」を見ることです。

#checkpoint[
  この章の到達点は次の通りです。

  - `.o` が機械語だけではなく symbol と relocation を持つと説明できる
  - section と program header の違いを説明できる
  - `.text`、`.data`、`.bss`、`.rodata` の役割を言い分けられる
  - `readelf` と `objdump` をどう使い分けるか分かる
]

== まず観察対象を固定する

本書で繰り返し使う最小例は次の 2 つです。

```c
// single.c
int main(void) {
  return 42;
}
```

```c
// main.c
int ext(void);

int main(void) {
  return ext() + 1;
}
```

```c
// ext.c
int ext(void) {
  return 41;
}
```

最初の例は、section の基本を見るのに向いています。二つ目の例は、未解決シンボルと relocation を見るのに向いています。以後の章でも、この小ささをなるべく保ちます。大きなプログラムをいきなり読まないのは、仕組みを減らして役割を見やすくするためです。

== `.o` は未完成な部品

コンパイラやアセンブラが吐く `.o` は、まだ完成した実行形式ではありません。そこには命令列や静的データが入っていますが、同時に「この場所はあとで直してほしい」「この名前は外で定義される」という情報も残っています。つまり `.o` は、実行可能というより *結合待ちの部品* です。

この観点を持つと、`.o` の見え方が変わります。`.text` だけを見て「命令はもう全部ある」と思っても、外部関数呼び出しやグローバル参照の値はまだ確定していないかもしれません。未確定な場所があるからこそ、symbol table と relocation table が必要になります。

== section が表すもの

`.o` の内部は、多くの場合 section という単位で整理されています。初学者がまず覚えるべき section は次です。

- `.text`
  命令列
- `.rodata`
  読み取り専用データ。文字列リテラルや定数表など
- `.data`
  初期値付きの書き換え可能データ
- `.bss`
  初期値 0 の大域データ。ファイル内にはサイズ情報だけを持つことが多い
- `.symtab`
  symbol table
- `.rela.text`, `.rela.data`
  relocation entry

section は、主に *部品を組み立てる側* の都合で分かれています。命令、定数、未解決参照、symbol 情報を別々に持っておくと、リンカが扱いやすいからです。

== ELF header と section header

`ELF` 形式のファイル先頭には `ELF header` があります。ここには「これは ELF である」「32bit か 64bit か」「実行形式か共有オブジェクトか relocatable object か」「section header はどこか」といった、全体を読むための入口情報が入っています。

一方、section header table は「各 section がファイル内のどこにあり、どのくらいの大きさで、どんな属性か」を列挙します。`.o` を読む段階では、section header がとても重要です。なぜなら、この段階の主役は loader ではなく linker だからです。linker は section を単位に部品を集め、symbol を解決し、relocation を適用します。

== symbol table は何を持つか

symbol table は、名前とその意味付けの表です。ただし、ここでいう「意味」は単にアドレスではありません。代表的には次の情報を持ちます。

- 名前
- どの section に属するか
- 値またはオフセット
- 大域か局所か
- 関数かオブジェクトか
- 未定義か定義済みか

たとえば `ext` は `main.o` 側では未定義 symbol として現れますが、`ext.o` 側では `.text` 内の定義済み symbol として現れます。linker の仕事は、これらを照合して「`main.o` のこの参照は `ext.o` のこの定義へつながる」と決めることです。

== relocation entry は「あとで埋める印」

relocation entry は、ファイルのある位置に入っている仮の値を、後で正しい値へ直すための指示です。外部関数呼び出し、グローバル変数参照、アドレス定数などで現れます。重要なのは、relocation は「値そのもの」ではなく *値の作り方* を表している点です。

たとえば x86-64 では、次のような違いがあります。

- 絶対アドレスを書き込みたいのか
- 現在位置からの相対オフセットを書き込みたいのか
- `PLT` を経由する呼び出しとして扱いたいのか

この違いが relocation type に現れます。つまり relocation table を見ると、linker や dynamic loader が後でどういう計算をするつもりなのかが見えてきます。

== `objdump` と `readelf` の役割分担

最初に使い分けたい道具は `readelf` と `objdump` です。

- `readelf`
  ELF header、section header、symbol、relocation のような構造を見る
- `objdump`
  逆アセンブルして、命令列と参照の位置関係を見る

たとえば `call` 命令が `ext` を呼んでいると聞いても、`objdump -dr` で命令位置を見なければ「どこに relocation が刺さるのか」が分かりにくいです。逆に `objdump` だけ見ても、symbol が未定義なのか、どんな relocation type が付いているのかは見落としやすいです。両方を往復するのが基本になります。

== section header と program header は別物

ここで非常に重要なのが、section header と program header を混同しないことです。section は linker が部品を扱うための単位でした。これに対して program header は、実行時に loader が何をどこへ写像するかを表します。

この違いは、`.o` と実行形式の役割の違いそのものです。

- `.o` では section が主役
- 実行形式や shared object では program header が主役

section は「部品の都合」、program header は「起動時の写像の都合」です。後者は次章以降で改めて扱いますが、この区別をここで持っておくと、`readelf -S` と `readelf -l` の出力を混同しにくくなります。

#caution[
  section があるからといって、kernel が section ごとにメモリへ載せるわけではありません。実際に `execve` 後の写像を決めるのは program header です。section は主に static link のためにあり、起動時の直接の単位ではありません。
]

== この章で押さえるべき最小像

本章の要点を縮めると、`.o` は次の 3 層から見れば十分です。

1. 命令や静的データそのもの
2. 名前を付ける symbol table
3. 後で値を直す relocation table

この 3 つが見えると、linker は「不完全な部品を集め、symbol を照合し、必要な位置を書き換える仕事」だと自然に見えてきます。次章では、その書き換えが `ABI` とどう結び付くかを見ます。
