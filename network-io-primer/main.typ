#import "theme.typ": *

#set document(title: "Network I/O Primer")

#align(center)[
  #set text(size: 24pt, weight: "bold")
  Network I/O Primer
]

#v(8pt)

`socket`、blocking / nonblocking I/O、`select/poll/epoll`、socket buffer、`go-runtime-primer` の `netpoll` を、Linux x86-64 の user/kernel 境界として整理する学習用ノートです。`syscalls-process-primer` で見た syscall / sleep / wakeup の感覚を network I/O へ伸ばし、Go の goroutine が I/O 待ちでどう止まり、どう再開するのかへ戻れるように構成しています。

#editorial_note[
  この文書は `socket` API や Linux source の逐語訳ではありません。`socket` を作る、待つ、再開する、複数 connection をさばく、runtime とつなぐ、という学習の主線が見えやすい順に再構成した版です。TCP/IP 全史や NIC driver の網羅ではなく、「network I/O は待ち合わせの問題でもある」という感覚を掴むことを優先しています。
]

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-sockets-and-blocking-io.typ"
#include "chapters/03-nonblocking-and-readiness.typ"
#include "chapters/04-select-poll-epoll.typ"
#include "chapters/05-kernel-bridge-and-runtime.typ"
#include "chapters/06-appendices.typ"
