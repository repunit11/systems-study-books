#import "../theme.typ": editorial_note, checkpoint, caution, diagram

= はじめに

この文書は、複数サービスが通信するときに何が難しくなるのかを整理するためのノートです。単一 process の関数呼び出しでは、call して戻れば話が終わります。しかしサービス間通信では、相手は別 process であり、別 host かもしれず、別 deployment cadence と failure mode を持っています。戻り値だけでなく timeout、retry、重複、順序、遅延、再配信、観測可能性まで設計に入ってきます。本書は、その増えた論点を `RPC` と `Kafka` の二つの題材で一本の線にすることを目指します。

`network-io-primer` では、blocking / nonblocking I/O、`select/poll/epoll`、Go runtime の `netpoll` を通して、「待つとは何か」を low-level に整理しました。本書はその次の層です。今度は socket 1 本ではなく、service A と service B、API handler と worker、同期 request と非同期 event のあいだで、どのような約束と失敗が発生するかを見ます。

本書では全章を通して 1 つの継続例を使います。題材は EC サイトの注文システムです。注文 API は `API Gateway` から `Order Service` に入り、`Inventory Service` と `Payment Service` に同期 `RPC` します。そのあと注文確定という事実を `Kafka` に書き込み、`Email Worker`、`Analytics Consumer`、`Search Indexer` がそれぞれ非同期に処理します。つまり、1 つの user 操作の中に、同期通信と非同期通信の両方が入っています。これがサービス間通信の設計を学ぶ題材として都合がよい理由です。

#diagram("assets/service-overview.svg", [注文システム全体と、同期の critical path、response 後の非同期 fan-out], width: 96%)

この構成は特別に複雑なものではありません。むしろ多くの backend system にかなり近い形です。だからこそ学びやすいのです。user にすぐ返したい結果、後でよい副作用、順序を守りたい更新、重複を許容したい処理が、1 つの業務フローの中に同時に出てきます。

== この教材の主題

本書の主線は次の 5 点です。

1. `RPC` を「remote function call」ではなく、timeout と失敗を含む request/response として理解する
2. broker と `Kafka` を、queue ではなく「複数 consumer が読む append-only log」として理解する
3. retry、重複、順序、再処理を、delivery semantics の問題として整理する
4. consumer group、lag、rebalancing、backpressure を、運用の都合ではなく設計の一部として理解する
5. 同期通信と非同期通信を対立させず、system 全体で役割分担させる感覚を持つ

この順序を取る理由は、いきなり `Kafka` の内部や `gRPC` の API へ飛ぶと、「何を守るためにその仕組みがあるのか」が曖昧になりやすいからです。まず request/response の素朴な世界を見て、そこから broker と log が必要になる理由へ進みます。そのうえで delivery semantics と運用の問題へ戻ると、同期と非同期を比較しやすくなります。

#checkpoint[
  本書を読み終えるころには、少なくとも次を説明できる状態を目指します。

  - `RPC` と local call がどこで決定的に違うか
  - timeout、retry、deadline、idempotency をどう組み合わせるべきか
  - `Kafka` の `topic`、`partition`、`offset`、consumer group が何を表すか
  - at-most-once / at-least-once / exactly-once を end-to-end でどう解釈するか
  - `RPC` と `Kafka` を同じ system の中でどう使い分けるか
]

== local call の直感はどこで壊れるのか

分散システムの最初のつまずきは、local call の直感をそのまま持ち込むことです。関数呼び出しなら、「呼んだ」「戻ってきた」「失敗した」がかなり明確です。しかしサービス間通信では、そのあいだに DNS、load balancer、sidecar、connection pool、thread pool、queue、broker、worker が入ります。途中のどこかが遅くても caller からはただ timeout に見えるかもしれませんし、callee は成功したのに response だけ失われるかもしれません。

この違いを雑に扱うと、設計はすぐに壊れます。retry は成功率を上げるどころか重複実行を増やし、`Kafka` は疎結合どころか状態遷移を曖昧にし、監視は green なのに user 体験は壊れる、といったことが起きます。本書は、そこを技術名ではなく設計判断の問題として整理するための本です。

== なぜ `RPC` と `Kafka` を一緒に扱うのか

分散システムの本は、`RPC` 側に寄ると service mesh、serialization、load balancing、deadline propagation の本になり、`Kafka` 側に寄ると broker、partition、consumer group、stream processing の本になりがちです。もちろんそれぞれ価値があります。しかし system を設計する立場から見ると、本当に欲しいのは個別技術の encyclopedic な説明ではなく、「いつ同期で頼み、いつ非同期に流し、失敗時に何が壊れるか」を一続きで考える地図です。

`RPC` は「相手に今すぐ仕事をしてほしい」という要請を表すのに向いています。一方 `Kafka` は、「今ここで完了させなくてもよいが、後で複数の側が読める形で残したい」という要求に向いています。両者は競合ではなく補完関係です。本書ではその補完関係を主題にします。

== 本書が扱う問い

本書では特に次の問いを中心に据えます。

- timeout が起きたとき、相手は本当に失敗したのか
- retry したとき、重複処理はどこで止めるべきか
- 同じ event を複数 service が読むとき、順序はどこまで守れるのか
- `RPC` の失敗を `Kafka` へ逃がせば本当に頑健になるのか
- queue や broker の長さは、単なる運用指標なのか、それとも設計上の信号なのか

これらの問いに共通しているのは、「相手の状態を完全には知らない」という点です。分散システムでは、失敗は単純な真偽値ではなく、観測できる failure と内部で起きている failure がずれることが普通です。そのずれをどう扱うかが、本書の中心線です。

この中心線を支える補助的な問いもあります。どの field を partition key にするべきか。どの request に idempotency key を持たせるべきか。consumer lag の増加は、単に worker を増やせばよいのか。どこからが user-facing critical path で、どこからが background work なのか。これらは別々の設問に見えますが、実際には「いつ結果を必要とし、何を一貫させ、失敗時に誰が責任を持つのか」という同じ問題へ戻っていきます。

== 対象読者と前提

読者には、TCP の基本、`HTTP` や `gRPC` の存在、queue や event の概念、Go か他の一般的な backend 言語で server を書いた経験があることを想定します。ただし分散システムの専門知識は前提にしません。`Kafka` を実運用したことがなくても構いません。本書では必要な概念を順に導入します。

一方で、初版では次を主題にしません。

- `Kafka` の storage engine や KRaft の細部
- service mesh の全体像
- CDC、Debezium、stream processing の全網羅
- Paxos / Raft の定理や formal proof
- multi-region database や geo-replication の深掘り

これらは重要ですが、最初の一冊で同時に扱うと中心線がぶれます。本書の初版は、サービス間通信の設計判断に必要な地図を作ることを優先します。

また、本書は製品マニュアルではありません。`gRPC` の flag 一覧、`Kafka` broker の内部 storage layout、Kubernetes の manifest 断片を大量に並べるより、設計時に何を先に決めるべきかへ焦点を当てます。だからコード例も本物の production 実装より短く、説明のための擬似コードに寄せます。目的はコピペ可能なサンプルを配ることではなく、読者が自分の system へ応用できる判断軸を手に入れることです。

== この本の見方

本書では「同期通信は簡単、非同期通信は高度」といった序列は取りません。同期通信には timeout と cascading failure の難しさがあり、非同期通信には順序と重複と再処理の難しさがあります。難しさの種類が違うだけです。

したがって読むときの軸は、技術名ではなく次の観点です。

- いまの通信は request/response か、log への append か
- caller はいつ結果を必要としているか
- 失敗時に誰が retry し、誰が重複を吸収するか
- 順序や整合性はどの範囲で必要か
- 負荷が上がったとき、どこで backpressure をかけるか

#caution[
  「`Kafka` を入れれば非同期になって頑健になる」「`RPC` なら単純だから安全」といった理解は危険です。同期・非同期の違いは、難しさが消えることではなく、どの層へ移動するかです。本書では、その移動先を明確にします。
]

図やコードを見るときも、常に次の 3 つを自問すると理解しやすくなります。

1. この call / event の caller は、いつ結果を必要としているのか
2. 失敗したとき、どの層が retry し、どの層が重複を吸収するのか
3. 順序や整合性を守りたい単位は何か

この 3 問に答えられれば、多くの API や middleware は「よく分からない仕組み」ではなく、設計上の道具として見えてきます。

== 本書を通して繰り返す 4 つの問い

本書を読み進めると、`timeout`、`lag`、`idempotency`、`replay`、`ownership` といった言葉が何度も出てきます。これらは別々のトピックに見えますが、実際には次の 4 問へ戻っていきます。

1. caller はいつ結果を必要としているか
2. 成功を返したとき、何を保証したことにするのか
3. 重複や順序崩れはどこで吸収するのか
4. 壊れたとき、誰が観測し、誰が修復するのか

`RPC` の章では 1 と 2 が前に出ます。`Kafka` と consumer の章では 3 が前に出ます。playbook の章では 4 が前に出ます。しかし主題は同じです。読むときにこの 4 問へ戻ると、各章の論点がつながりやすくなります。

== 継続例で追う状態境界

本書の注文システムでは、同じ `注文` でも見る人によって境界が違います。

- client
  `accepted` / `rejected` / `temporary_failure`
- Order Service
  inventory と payment を含む同期 path の結果
- `Kafka` consumer
  `OrderCreated` をそれぞれの速度で処理する非同期 path
- operator
  lag、DLQ、redrive、manual recovery の対象

この境界を混ぜると会話が壊れます。たとえば `注文は成功している` と `確認メールはまだ送られていない` は両立しますし、`client は timeout を見た` と `backend では遅れて accepted になった` も両立します。分散システムでは、`どの観測者から見た状態か` を明示する癖が重要です。

```text
Same order, different viewpoints

Client
  accepted / rejected / temporary_failure

Order Service
  inventory + payment + order row + outbox

Consumer side
  mail sent / analytics updated / search refreshed

Operator
  lag / DLQ / replay / recovery
```

この図式を頭に置くと、各章で出てくる `成功` や `失敗` が、誰の視点で語られているかを追いやすくなります。

== accepted、rejected、unknown を分けて読む

分散設計の初学者がつまずきやすいのは、`success` と `failure` だけで世界を見てしまうことです。実務では、そのあいだに `まだ断言できない` 状態がかなりあります。

- `accepted`
  注文は同期 path の意味で成立している
- `rejected`
  業務的に成立していない
- `unknown`
  caller からはまだ断言できない。user-facing response では `temporary_failure` に近い

本書の中では、この `unknown` が重要です。payment timeout、response loss、relay 遅延、consumer lag は、どれも `何かが壊れた` だけでなく `状態確認が必要になった` と読むべき場面です。だから inquiry path、idempotency key、runbook が必要になります。

この 3 分類で読むと、同期 `RPC` と `Kafka` の役割も整理しやすくなります。`RPC` は `accepted / rejected / unknown` を早く狭めるための道具であり、`Kafka` は `accepted` のあとに残る仕事を時間方向へ押し出すための道具です。本文の user-facing な説明では、この `unknown` を多くの場合 `temporary_failure` として表現します。

== 各章の見取り図

本書は次の順で進みます。

1. `注文作成` の critical path を使って request/response の設計を整理する
2. `RPC` client 運用、load balancing、timeout budget、streaming を追加する
3. `order-created` event を使って `Kafka` の log モデルと producer 設計を見る
4. consumer group、lag、DLQ、redrive を通して worker 設計を見る
5. delivery semantics、ordering、outbox、saga を通して end-to-end consistency を考える
6. 最後に障害対応、観測、ownership、使い分けの playbook をまとめる
7. 付録で演習、用語、設計レビュー観点、次に読む資料を整理する

この順序には理由があります。`Kafka` から入ると、なぜ同期 request では足りないのかが見えにくくなります。逆に `RPC` だけ見ていると、結果を今すぐ返さなくてよい仕事や fan-out する event の扱いが抜けます。両方を見ることで、通信設計の判断軸が立体的になります。

各章では必ず継続例へ戻ります。たとえば `Inventory Service` はなぜ同期 `RPC` で扱うのか、`Email Worker` はなぜ `Kafka` consumer にするのか、`Payment Service` にはなぜ idempotency key が必要なのか、`Search Indexer` はなぜ replay を前提に設計すべきなのか、といった問いです。別々の service を見るのではなく、1 つの user 体験を支える部品として眺めることが重要です。

== 最初に押さえる読み方

読み進めるときは、全部を同じ深さで覚える必要はありません。まず次の順で押さえると入りやすいです。

1. `02`
   request/response が何を保証する契約か
2. `04`
   `Kafka` が queue ではなく log として何を増やすか
3. `05`
   consumer 側にどんな責務が移るか
4. `06`
   end-to-end で何が 1 回に見え、何が遅れてよいか
5. `07`
   壊れたときに何をどの順で見るか

この順で一周すると、本書の中心線である `同期 path で意味を固定し、非同期 path で副作用を分離し、障害時は ownership と runbook で回復する` という流れが見えやすくなります。

== この本を読み終えたときの出口

最終的に目指しているのは、`Kafka を説明できる` や `gRPC を使える` だけではありません。自分の system を見たときに、少なくとも次を言葉にできる状態です。

- この API の success は何を意味するか
- retry してよい境界と、してはいけない境界はどこか
- event の ordering scope は何か
- lag や DLQ を誰が見るべきか
- unknown state が起きたとき、どこで確認するか

そこまで行けば、新しい middleware や product に出会っても、`その道具がどの問題を引き受け、どの問題を残すか` で考えやすくなります。本書が作りたいのは、特定技術の暗記ではなく、この判断の地図です。

#editorial_note[
  本書は特定の framework の使い方本ではありません。`gRPC`、HTTP API gateway、`Kafka` producer/consumer のコード例は登場しますが、それらは API の暗記ではなく、「何を caller の責務にし、何を broker や consumer の責務にするか」を考えるための足場として使います。
]
