#import "../theme.typ": checkpoint, caution, editorial_note, diagram

= `Kafka`、log、producer 設計

前章までで、user-facing critical path を同期 `RPC` で設計する感覚を作りました。しかし注文システム全体を見ると、それだけでは明らかに苦しい部分があります。メール送信、分析イベント、検索 index 更新、fraud review などは、どれも重要ですが、注文ボタンを押した user をその場で待たせる理由は薄いからです。そこで必要になるのが broker と append-only log です。この章では、`order-created` event を題材に、`Kafka` を「高機能な queue」ではなく、「後から複数 consumer が読める log」として整理します。

以後この章では、概念名は `OrderCreated`、topic 名や event type 名は `order-created` のように書き分けます。概念、log 上の名前、コード識別子を混ぜないためです。

#checkpoint[
  この章では次を押さえます。

  - broker と log が必要になる理由
  - command と event の違い
  - `Kafka` の `topic`、`partition`、`offset` が何を表すか
  - producer が決めるべき key、schema、ack、retry の意味
  - append 成功と処理完了が違うこと
]

== どの仕事を同期 path から外すのか

注文作成のあとにやりたい仕事を挙げると、すぐに同期 path に入りすぎる傾向があります。確認メールも送りたいし、analytics にも流したいし、検索 index も更新したいし、coupon 利用履歴も記録したい。これらを全部 `RPC` で直列に呼べば、もちろん動くことは動くでしょう。しかし checkout の latency と failure surface は急速に悪化します。

そこで最初に決めるべきなのは、「何を後でよい仕事として切り出すか」です。継続例では、少なくとも次を非同期に回します。

- 注文確認メール
- 解析イベント反映
- 検索 index 更新
- recommendation feature への入力

これらに共通しているのは、`注文が発生した` という事実をもとに、それぞれが独立して処理できることです。ここで同期 `RPC` fan-out ではなく、event log が向きます。

=== command と event を区別する

`Kafka` を導入するとき、最初に区別したいのは command と event です。

- command
  誰か特定の相手に「これをやってほしい」と依頼するもの
- event
  すでに起きた事実を「こうなった」と記録するもの

`SendOrderConfirmationEmail` は command 的であり、`OrderCreated` は event 的です。`Kafka` に載せるときは、後者の見方のほうが自然です。なぜなら `Kafka` は、複数 consumer がそれぞれの都合で同じ record を読みたいときに強いからです。

`OrderCreated` が log に書かれていれば、Email Worker はメール送信に使い、Analytics Consumer は集計に使い、Search Indexer は検索 document 更新に使えます。1 つの command を 3 回複製して送るより、1 つの event を 3 つの consumer が読むほうが自然です。

=== queue ではなく log として理解する

`Kafka` を単なる queue として理解すると、すぐに説明しにくい現象にぶつかります。なぜ同じ message を複数の consumer group が読めるのか。なぜ古い record を replay できるのか。なぜ offset が consumer ごとに別なのか。これらは queue というより log として見ると理解しやすくなります。

log として見ると、`Kafka` の責務は比較的単純です。

- producer から record を append する
- append された順序を partition 単位で保持する
- consumer ごとの読了位置は consumer 側が持つ

つまり `Kafka` 自体は「もう処理し終えたから消す」という強い意味を持ちません。保持しているのは log であり、誰がどこまで読んだかは consumer group ごとの状態です。

```text
topic: order-events
partition-0: [offset 0][offset 1][offset 2][offset 3]...
partition-1: [offset 0][offset 1][offset 2]...

email-group       -> partition-0 offset 3, partition-1 offset 1
analytics-group   -> partition-0 offset 2, partition-1 offset 2
search-group      -> partition-0 offset 3, partition-1 offset 0
```

この図から分かるように、同じ record を各 group が別の速度で追えます。これが `Kafka` を「複数下流への fan-out 基盤」として使いやすくしている理由です。

== `topic`、`partition`、`offset`

`Kafka` を読むときの最小語彙は次の 3 つです。

- `topic`
  同種の record を置く論理名
- `partition`
  並列性と順序保証の単位
- `offset`
  partition 内の位置を表す連番

ここで特に重要なのは、順序保証は通常 partition 単位だということです。`order-events` topic 全体に 1 本の total order があるわけではありません。したがって、どの entity の順序を守りたいかに応じて key を決める必要があります。

継続例では、`order_id` を key にするのが自然です。`Kafka` のデフォルトパーティショナーはキーの murmur2 ハッシュを使うため、同じ注文に関する `OrderCreated`、`OrderPaid`、`OrderCancelled` は partition 数が変わらない限り常に同じ partition へ送られ、注文単位の順序を保てます。

=== partition key は business decision である

多くの初学者は、partition key を「適当に均等化するための文字列」と考えます。しかし実際には business decision です。何の順序を守りたいか、どの単位で並列化したいかを表します。

たとえば次のような候補があります。

- `customer_id`
  顧客単位の順序を守りたいときに便利だが、ヘビーユーザが hot key になる
- `order_id`
  注文単位の順序には自然だが、顧客単位の整合性は別管理になる
- `merchant_id`
  店舗単位の集計には便利だが、大規模店舗に偏りやすい

どれを選んでも tradeoff があります。重要なのは、まず守りたい ordering scope を定義し、そのために key を選ぶことです。均等分散だけを目的にすると、必要な順序をあとから回復するコストのほうが大きくなります。

```text
Ordering scope examples

key = order_id
  守りやすい順序: 注文単位
  向いている consumer: order lifecycle, customer notification

key = customer_id
  守りやすい順序: 顧客単位
  向いている consumer: customer timeline, fraud heuristics

key = merchant_id
  守りやすい順序: 店舗単位
  向いている consumer: merchant analytics
```

この比較をしておくと、「なぜこの key にしたのか」が後から説明しやすくなります。

== event schema は何を残すべきか

`OrderCreated` event を設計するとき、迷うのは「どこまで payload に含めるか」です。最小限の ID だけを送り、consumer は追加情報を `RPC` で取りに行く方法もあります。一方、注文時点の金額や商品 snapshot を payload に全部入れてしまう方法もあります。

ここでの判断軸は次の通りです。

- event 単体で consumer が意味を解釈できるか
- あとから replay したとき、当時の状態を再現できるか
- payload が肥大化しすぎないか

継続例では、検索 indexer や analytics は「注文時点の情報」を後から再現したいことが多いので、`order_id` だけでなく `customer_id`、`line_items`、`total_amount`、`created_at` などを event に含める価値があります。逆に機密性の高い決済トークンなどは含めるべきではありません。

```go
type OrderCreatedEvent struct {
    EventID      string
    OrderID      string
    CustomerID   string
    MerchantID   string
    TotalAmount  int64
    Currency     string
    LineItems    []LineItemSnapshot
    CreatedAt    time.Time
    SchemaVersion int
}
```

このような schema は、consumer が `Order Service` へ追加 `RPC` せずに最低限の処理を進められるようにするためのものです。同期依存を減らすことは、非同期設計の大きな利点です。

=== producer が決めるべきこと

producer の責務は「publish を呼ぶ」だけではありません。少なくとも次を決めなければなりません。

- record key を何にするか
- schema version をどう持つか
- append 成功をどこまで待つか
- retry 時の ordering と重複をどう見るか
- timestamp を event time にするか append time にするか

この中でも特に重要なのは `append 成功をどこまで待つか` です。broker に書けたことを確認してから response を返すのか、outbox に記録できた時点でよしとするのかで同期 path の設計が変わります。本書では後者を採ります。理由は、`Kafka` 自体を critical path に直結させすぎないためです。

=== outbox row に何を持つか

outbox を入れるなら、row の設計も大切です。最低限ほしいのは次です。

- `event_id`
- `topic`
- `key`
- `payload`
- `created_at`
- `status`

これに加えて、再送や監査のために `attempt_count` や `last_error` を持つ設計もあります。重要なのは、relay が落ちたあとに何が pending か分かり、同じ row を安全に再処理できることです。

=== append 成功と処理完了は違う

`Kafka` を使い始めると、「publish できたから処理された」と思いがちです。しかし実際には、append 成功と consumer side effect 完了は別物です。

- producer にとっての成功
  record が log に append された
- consumer にとっての成功
  record を読んで自分の処理を完了した
- user にとっての成功
  必要な副作用が見える形で反映された

たとえば `OrderCreated` を append できても、Email Worker が落ちていればメールは送られません。Analytics Consumer が lag していれば dashboard 反映は遅れます。したがって `Kafka` を入れると成功の定義が多層になります。ここが同期 `RPC` と大きく違う点です。

#editorial_note[
  分散設計では「どの層の成功を見ているか」を混ぜると会話が壊れます。`publish は成功している` と `ユーザ通知まで完了している` は別の主張です。
]

=== producer retry と重複

producer も失敗します。network 切断、leader 切り替え、broker 一時停止などが起きれば、publish call は timeout するかもしれません。ここで自動 retry を入れると、多くの場合は便利ですが、「最初の append が本当に失敗だったか」を常に完全には分かりません。したがって producer 側にも重複の視点が必要です。

event に `EventID` を持たせておくのは、consumer 側 dedup や監査で役立ちます。また、outbox pattern を使うなら `outbox_id` 自体を stable identity として扱えます。大切なのは、`同じ事実の再送` を識別できることです。

== ケース 1: order row はあるが event がまだ見えない

outbox を使うときにまず理解したいのは、この状態が正常に起こり得ることです。

```text
T0 order row inserted
T1 outbox row inserted
T2 client receives accepted
T3 relay is delayed or stopped
T4 Kafka does not yet contain OrderCreated
```

このとき `注文は成功しているのに analytics に見えない` という現象が起きます。これは必ずしもバグではなく、`DB state と log append のあいだに時間差がある` ことの自然な結果です。

重要なのは、この差を異常と通常で切り分けられることです。relay lag が freshness budget を超えているなら障害ですが、短時間の遅れ自体は outbox 設計の前提に含まれます。

#diagram("assets/outbox-relay-fanout.svg", [order row と outbox row は先に確定し、その後 relay が `Kafka` と consumer 側の可視性を作る], width: 96%)

=== event time と processing time

analytics や検索更新では、`いつ起きた事実か` と `いつ処理されたか` を分けておく必要があります。イベントが 10 分遅れで処理されることは普通にあるからです。

- event time
  事実が起きた時刻
- append time
  broker に書かれた時刻
- processing time
  consumer が処理した時刻

この 3 つを混ぜると、遅延分析や replay の意味が曖昧になります。注文システムでは、売上集計を event time で行いたい場面が多いはずです。

== topic をどう切るか

topic 設計も実務では重要です。よくある問いは、「`order-created`、`order-cancelled`、`order-paid` を 1 つの topic に入れるか、別 topic に分けるか」です。

1 つにまとめる利点は、同じ aggregate に関する event を 1 本の log として見やすいことです。別 topic に分ける利点は、consumer ごとに必要な event だけ読めることです。継続例では、`order-events` のような大きめの topic に event type を持たせる設計と、`order-created` などを明示的に分ける設計のどちらもあり得ます。

判断軸は次の通りです。

- 同じ consumer が複数 event type をまとめて見たいか
- ordering をどの範囲で保ちたいか
- topic 増加の運用コストをどう見るか

初学段階では、event type ごとに役割が大きく違うなら分ける、同じ aggregate の状態遷移をまとめて見たいなら 1 topic + type field もあり得る、くらいの理解で十分です。

=== thin event が同期依存を呼び戻す

producer 設計でありがちな失敗は、payload を削りすぎて `consumer が毎回 Order Service に問い合わせる` 形へ戻ってしまうことです。これは一見きれいですが、非同期 fan-out の価値をかなり削ります。

たとえば `order_id` だけを流し、Email Worker、Analytics Consumer、Search Indexer がすべて追加 `RPC` で注文詳細を取りに行くと、次の問題が出ます。

- Order Service が新しいボトルネックになる
- replay 時に大量の同期 call が発生する
- 注文当時の snapshot ではなく、現在値を読んでしまう
- consumer の独立性が弱くなる

thin event は悪ではありませんが、`consumer を再び同期依存へ戻していないか` を必ず確認する必要があります。

=== schema evolution を先に考える

`Kafka` では record が後から replay されるので、schema evolution は `RPC` 以上に重要です。producer を更新した瞬間だけ動けばよいのではなく、旧 consumer、新 consumer、旧 record、新 record の組み合わせを考える必要があります。

そのために最低限やっておきたいのは次です。

- 追加 field は optional にする
- consumer は未知 field を無視できるようにする
- 破壊的変更は version を分ける
- event 名自体の意味変更を避ける

`OrderCreated` が昨日までは `pending payment` を含まなかったのに、今日から含む、といった意味変更は後から効いてきます。schema は型だけでなく意味でも互換性が必要です。

== retention と replay cost を見積もる

`Kafka` は log なので replay できる、という説明はよく出ます。しかし replay は無料ではありません。保持期間、topic size、consumer throughput、downstream の受け皿を見積もらなければ、いざ再処理したいときに現実的ではなくなります。

継続例でも、`Search Indexer` の再構築と `Analytics Consumer` の backfill では意味が違います。前者は時間がかかってもよいが、検索 freshness への影響を読まなければいけません。後者は重い再集計で warehouse を詰まらせるかもしれません。replay を設計に含めるなら、少なくとも次を決めておくべきです。

- 何日分を保持したいのか
- 最大どのくらいの速度で replay するのか
- replay 中に通常 traffic をどう守るのか
- replay 済みかどうかをどう識別するのか

`Kafka だからあとから何度でも読める` ではなく、`そのための容量と運用手順を先に持つ` と理解したほうが実務に近いです。

=== compaction が向く場面、向かない場面

`Kafka` には compaction という考え方があります。同じ key に対する古い record を整理し、最新値を取り出しやすくする発想です。これは便利ですが、すべての topic に向くわけではありません。

- 向いている例
  最新状態の projection を再構築したい topic
- 向きにくい例
  全履歴そのものに意味がある監査イベント

注文システムなら、`order-state-snapshots` のような `最新状態をすぐ得たい` topic には検討余地があります。一方 `order-events` のように `作成された、支払われた、取消された` の全履歴に意味がある log では、単純に compaction へ寄せると過去の因果が見えにくくなります。

重要なのは、`log を残したいのか`、`最新状態を引きたいのか` を topic ごとに区別することです。

=== producer 側にも backpressure がある

`Kafka` を使うと `consumer lag` ばかり目立ちますが、producer 側にも backpressure はあります。broker が遅い、ack を待つ、buffer が詰まる、といった状況では producer 自体が block したり error を返したりします。

ここで設計が問われるのは、注文受付の同期 path に `Kafka` publish を直接入れていないか、という点です。継続例で outbox を使うのは、producer 側 backpressure が checkout path を直撃しないようにするためでもあります。`Kafka` は強力ですが、それ自体が依存先である以上、同期 path に近づけるほど failure surface も増えます。

=== relay は producer の一部である

outbox を採ると、application code の `publish()` 呼び出しは同期 path から消えます。しかし producer の責務が消えるわけではありません。それは relay へ移るだけです。

relay 側でも少なくとも次を決める必要があります。

- pending row をどの順で読むか
- 失敗時の retry と backoff をどうするか
- `sent` への遷移をどこで確定するか
- stuck row をどう観測するか

つまり relay は単なるバッチ job ではなく、producer の後半です。ここを雑に実装すると、outbox を入れたのに event delivery の信頼性が上がらないことがあります。

== `Kafka` は非同期 fan-out の土台

ここまでの話を注文システムへ戻すと、`Kafka` の役割はかなりはっきりします。Order Service が同期 path の最後で `order-created` を outbox に記録し、後段が `Kafka` へ流す。Email、Analytics、Search はそれぞれの consumer group で読んで処理する。1 つの事実を複数の関心事が独立に消費する構造です。

これにより、Order Service は「注文を受け付けること」に集中し、下流 consumer はそれぞれ自分の SLO で処理できます。まさに疎結合の利点です。

=== producer 設計の比較表

```text
Producer design choices

1. key = order_id
   向いている: 注文ライフサイクルの順序を見たい consumer
   注意点: 顧客単位の偏りは別途吸収が必要

2. payload = thin event (IDs only)
   向いている: 厳密な source of truth を常に RPC で取りに行く設計
   注意点: consumer が再び同期依存を持ちやすい

3. payload = snapshot-rich event
   向いている: replay, analytics, index rebuild
   注意点: schema evolution と payload size の管理が必要
```

この比較を見ると、producer 設計は `publish call の書き方` ではなく、consumer の未来まで含んだ意思決定だと分かります。

=== topic 命名と ownership を先に決める

producer 設計で地味に重要なのが、topic 名を `事実` として表現し、その owner を明確にすることです。`send-email` のような command 的な名前と、`order-created` のような event 的な名前では、consumer の期待が変わります。

ここで曖昧さを残すと、topic が次第に `何でも流す共有バス` になりやすくなります。そうなると schema 変更も owner も曖昧になり、結局は replay や debugging が難しくなります。

最低限決めておきたいのは次です。

- topic 名は命令ではなく事実を表しているか
- producer owner は誰か
- schema 変更レビューは誰が持つか
- retention と replay の方針は誰が決めるか

`Kafka` の topic は queue 名ではなく、組織的な契約名でもあります。

=== producer 設計レビューの問い

producer 側のレビューでは、次の 6 問があると議論しやすくなります。

1. この topic 名は事実を表しているか
2. payload だけで主要 consumer は処理できるか
3. key は ordering scope を表しているか
4. replay したとき payload の意味は保てるか
5. relay / retry による重複を `EventID` で追えるか
6. retention と owner は誰が決めるか

この問いに答えられない topic は、あとから `何のための log か` が曖昧になりやすいです。

=== 章末で見る producer の責務

producer は `イベントを投げる人` ではなく、system の境界を定義する人です。どの field を残すか、どの key を使うか、append 成功をどの段で観測するかによって、consumer の自由度と整合性のコストが変わります。

だからこそ producer 設計は、Order Service の内部実装 detail ではなく、ドメイン設計の一部として扱うべきです。

#caution[
  `Kafka` を使えば設計が楽になるわけではありません。同期 path の latency と引き換えに、lag、replay、ordering、schema evolution、consumer ownership の問題を引き受けることになります。
]

== 章末まとめ

`Kafka` の本質は、message をどこかへ送ることではなく、`起きた事実を log に残し、複数の consumer が独立進捗で読む` ことです。そのため、producer 設計は key、schema、payload、append 成功の意味まで含んだ architectural decision になります。

継続例では `order-created` を outbox 経由で `Kafka` へ流すことで、checkout の同期 path を短くしつつ、Email、Analytics、Search が自分の速度で追える形を作っています。ここが request/response だけでは得られない価値です。

=== この章の設計判断の要点

producer 設計で先に決めるべきなのは、broker の設定値より `何を事実として残すか` です。topic 名、key、payload、owner を曖昧にしたまま publish だけ先に作ると、consumer 側で同期依存や schema 破壊を呼び込みやすくなります。

注文システムで言えば、`order-created` は `Email Worker` への命令ではなく、注文が成立したという事実です。この見方を固定すると、後段 consumer ごとに速度も責務も変えられるようになります。

=== 演習

1. `order-created` event に最低限必要な field と、含めるべきでない field を書き分けてください。
2. あなたの system で partition key を選ぶとき、何の順序を守りたいかを 1 文で定義してください。
3. `publish 成功` と `業務完了` がずれる例を 3 つ挙げてください。
4. command と event を混同すると、どのような consumer 設計の混乱が起きるか整理してください。

=== この章の出口

`Kafka` を append-only log として置く意味が見えたら、次に問うべきは `誰がその log を引き受けるのか` です。次章では consumer 側へ視点を移し、lag、rebalancing、DLQ、backpressure を通して責務の置き場所を見ます。
