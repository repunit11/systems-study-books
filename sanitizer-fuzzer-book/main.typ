#import "theme.typ": *

#set document(title: "Sanitizer Fuzzer Book")

#align(center)[
  #set text(size: 24pt, weight: "bold")
  Sanitizer Fuzzer Book
]

#v(8pt)

セキュリティ・キャンプ全国大会 `Y1: Code Sanitizer・Fuzzer自作ゼミ` に着想を得て、学習用コンパイラへ instrumentation を加えながら、`AddressSanitizer`、`SanitizerCoverage`、coverage-guided fuzzing の原理を 1 冊で追うためのノートです。`compilerbook` を読み終えたあとに「生成したコードをどう観測し、どう壊し、どう自動で見つけるか」を学ぶ流れを意図しています。

#editorial_note[
  この文書は公式ゼミ資料や LLVM 文書の逐語訳ではありません。公開されている一次資料をもとに、学習用の小さな C コンパイラを改造しながら理解できるように再構成した教材です。説明の中心は原理の再実装であり、LLVM/Clang の全実装を追体験することではありません。
]

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-instrumentation.typ"
#include "chapters/03-address-sanitizer.typ"
#include "chapters/04-runtime-and-limits.typ"
#include "chapters/05-coverage-and-fuzzer.typ"
#include "chapters/06-appendices.typ"
