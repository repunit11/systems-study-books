#import "theme.typ": *

#set document(title: "Syscalls Process Primer")

#align(center)[
  #set text(size: 24pt, weight: "bold")
  Syscalls Process Primer
]

#v(8pt)

user mode、syscall、address space、context switch、`fork/exec/wait` を、x86-64 の最小 kernel / user 境界として整理する学習用ノートです。`elf-linker-loader-primer` の `execve` / startup と `rust-os-book` の kernel 側をつなぎ、`go-runtime-primer` の syscall / netpoll の理解にも戻れるように構成しています。

#editorial_note[
  この文書は Linux kernel や xv6 の逐語訳ではありません。x86-64 の特権遷移、syscall entry/exit、process image、`fork/exec/wait` の役割がつながる順に再構成した版です。完全な OS 実装手順書ではなく、「user/kernel 境界で何が保存され、何が切り替わるのか」を一本の線で追うことを優先しています。
]

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-rings-traps-and-user-mode.typ"
#include "chapters/03-syscall-path.typ"
#include "chapters/04-process-and-address-space.typ"
#include "chapters/05-fork-exec-wait-and-context-switch.typ"
#include "chapters/06-appendices.typ"
