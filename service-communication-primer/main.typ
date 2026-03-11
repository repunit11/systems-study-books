#import "theme.typ": *

#set document(title: "サービス間通信の設計入門")

#set page(numbering: none, footer: [])

#align(center)[
  #v(28mm)
  #set text(size: 11pt, fill: rgb("5b6674"))
  Systems Study Books
  #v(18mm)
  #set text(size: 26pt, weight: "bold")
  サービス間通信の設計入門
  #v(6pt)
  #set text(size: 15pt, fill: rgb("4f5d73"))
  Service Communication Primer
]

#v(18pt)

#align(center)[
  #block(width: 74%)[
    `RPC` と `Kafka` を題材に、サービス間通信をどう設計するかを整理する学習用ノートです。同期通信と非同期通信を対立する流派としてではなく、timeout、retry、ordering、delivery semantics、backpressure、consumer group といった判断軸で並べて理解できるように構成しています。`network-io-primer` で見た待ち合わせの感覚を、複数サービスが協調する分散システムへ伸ばすのが本書の役割です。
  ]
]

#v(16pt)

#align(center)[
  #block(
    width: 74%,
    fill: rgb("fbfcfe"),
    stroke: (paint: rgb("d8e0ee"), thickness: 0.5pt),
    inset: 12pt,
    radius: 6pt,
  )[
    *対象読者* \
    `HTTP` や `gRPC` の存在は知っているが、`RPC`、`Kafka`、consumer 運用、delivery semantics を一本の線で理解したい backend 実務者。

    *この本で扱うこと* \
    critical path、timeout、retry、idempotency、append-only log、consumer group、lag、DLQ、outbox、replay、playbook。
  ]
]

#v(14pt)

#align(center)[
  #set text(size: 9pt, fill: rgb("667387"))
  2026 Edition
]

#pagebreak(to: "odd")

#set page(
  numbering: "1",
  footer: context align(center)[
    #set text(size: 8.8pt, fill: rgb("5b6674"))
    #counter(page).display()
  ],
)

#heading(numbering: none, outlined: false)[この本の使い方]

最初から順に読んでもよいですが、実務でぶつかっている痛みから入っても構いません。`request/response` の意味づけに迷っているなら `02` と `03`、`Kafka` を入れたあとの責務分解で詰まっているなら `04` と `05`、整合性や replay の会話を具体化したいなら `06`、障害対応や ownership を整えたいなら `07` と `08` から読み始めるのが効きます。

本書は製品マニュアルではありません。`gRPC` や `Kafka` の設定項目を網羅するのではなく、`何を同期 path に残し、何を非同期へ逃がし、失敗時に誰が責任を持つか` を言葉にできる状態を目指します。各章の演習と付録の worksheet は、そのまま設計レビューや runbook づくりに持ち込めるようにしてあります。

#editorial_note[
  この文書は `gRPC` や `Kafka` の feature list を網羅する製品マニュアルではありません。サービス間通信で本当に難しくなる点、たとえば timeout、partial failure、retry、重複、順序、再処理、監視を、`RPC` と `Kafka` を対比しながら学べるように再構成した版です。設定項目や vendor 差分の完全網羅よりも、「なぜその設計判断が必要か」を説明できる状態を目指します。
]

#pagebreak(to: "odd")

#heading(numbering: none, outlined: false)[目次]

#outline(depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-request-response.typ"
#include "chapters/03-rpc-operations.typ"
#include "chapters/04-kafka-log-model.typ"
#include "chapters/05-consumers-and-backpressure.typ"
#include "chapters/06-semantics-and-consistency.typ"
#include "chapters/07-design-playbook.typ"
#include "chapters/08-appendices.typ"
