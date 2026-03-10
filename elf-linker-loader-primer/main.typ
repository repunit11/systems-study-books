#import "theme.typ": *

#set document(title: "ELF Linker Loader Primer")

#align(center)[
  #set text(size: 24pt, weight: "bold")
  ELF Linker Loader Primer
]

#v(8pt)

ELF、`SysV ABI`、静的リンク、動的リンク、`_start` から `main` までの起動経路を、Linux x86-64 上の最小例でつなぐ学習用ノートです。`compilerbook` の次に読むことを想定し、コンパイラが吐いた `.o` が、どのように実行可能ファイルとプロセスへ変わるのかを 1 冊で追えるように構成しています。

#editorial_note[
  この文書は仕様書や source tree の逐語訳ではありません。`ELF gABI`、`AMD64 psABI`、GNU toolchain、glibc、Linux の公開資料をもとに、学習の主線が見える順に再構成した版です。完全な網羅よりも、「誰が、いつ、どこを書き換えるのか」を説明しやすい順序を優先しています。
]

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-elf-and-object-files.typ"
#include "chapters/03-abi-and-static-linking.typ"
#include "chapters/04-shared-objects-and-dynamic-linking.typ"
#include "chapters/05-loader-and-process-startup.typ"
#include "chapters/06-appendices.typ"
