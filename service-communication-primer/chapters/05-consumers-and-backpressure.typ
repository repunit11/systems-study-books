#import "../theme.typ": checkpoint, caution, editorial_note, diagram

= consumer、lag、backpressure

`Kafka` を導入すると、つい producer 側に目が向きます。どの topic に書くか、どの key を使うか、どの schema にするか。しかし実務で苦しみやすいのは、その先の consumer 側です。誰がどの partition を読むのか、処理に失敗したらどこまで戻すのか、lag が増えたら何を疑うのか、poison message をどう隔離するのか。非同期化で得た疎結合は、consumer 運用の責務と引き換えです。この章では `Email Worker`、`Analytics Consumer`、`Search Indexer` を使って、`Kafka` consumer の設計を整理します。

#checkpoint[
  この章では次を押さえます。

  - consumer group が何を並列化しているのか
  - offset commit と side effect 完了の関係
  - lag を throughput 問題ではなく設計信号として読む方法
  - rebalancing、poison message、DLQ、redrive の意味
  - backpressure をどこでかけるべきか
]

== 3 つの consumer は同じではない

継続例では、`order-created` を少なくとも 3 つの consumer が読みます。

- `Email Worker`
  確認メール送信。外部メール API に依存し、再送時の重複通知が問題になる
- `Analytics Consumer`
  集計更新。多少遅れてもよいが、長期的には欠損を避けたい
- `Search Indexer`
  検索 document 更新。replay や backfill が比較的しやすい

この 3 つは、同じ event を読んでいても性質が違います。したがって consumer 設計も同じではいけません。メール送信では idempotency と provider 制約が重要になり、analytics では event time と replay が重要になり、search では bulk 処理と index versioning が重要になります。

つまり `Kafka` を入れたからといって「下流は全部同じ worker」で片付くわけではありません。consumer ごとに failure mode と SLO が違うのです。

```text
Consumer comparison

Email Worker
  重要なもの: idempotency, provider rate limit, duplicate suppression
  許容 lag: 小さめ
  replay safety: 低い

Analytics Consumer
  重要なもの: throughput, event time, backfill, aggregation correctness
  許容 lag: 中〜大
  replay safety: 高い

Search Indexer
  重要なもの: upsert, bulk update, rebuild, schema/index version
  許容 lag: 中
  replay safety: 比較的高い
```

=== consumer group は何を分担するのか

consumer group の役割は、「同じ論理 consumer を複数 instance で水平分割する」ことです。重要なのは、group ごとに独立した責務を持つ点です。

- `email-group`
  各注文についてメール送信を 1 回やる責務
- `analytics-group`
  各注文について集計を 1 回以上取り込む責務
- `search-group`
  各注文について検索 document を更新する責務

同じ topic を読んでいても、group が違えば処理は独立です。ここを理解すると、「なぜ同じ record を複数 consumer が読めるのか」が自然になります。`Kafka` は `1 message = 1 consumer` ではなく、`1 record = group ごとに 1 回の処理機会` を与える仕組みなのです。

=== offset commit の意味

consumer を実装するとき、最初に出てくるのが offset commit です。ここで最も大事なのは、`commit した` と `業務処理が安全に終わった` を同一視しないことです。

典型的な流れは次の通りです。

1. broker から record を poll する
2. その record に対する side effect を実行する
3. side effect が安全に完了したことを確認する
4. そのあとで offset を commit する

順序を逆にすると、commit 済みなのに side effect が失敗して record を失う危険があります。逆に commit を遅らせすぎると、重複再処理の窓が広がります。ここが at-least-once / at-most-once の話につながります。

```go
for {
    records := consumer.Poll(ctx)
    for _, rec := range records {
        event := decodeOrderCreated(rec.Value)
        if err := emailSender.Send(event); err != nil {
            markForRetry(rec, err)
            continue
        }
        if err := consumer.Commit(rec); err != nil {
            log.Warn("commit failed", "offset", rec.Offset, "err", err)
        }
    }
}
```

この擬似コードの問題点は、`Send` と `Commit` のあいだで process が落ちたら重複送信が起き得ることです。したがって `Email Worker` には idempotent な送信設計が必要になります。

#diagram("assets/consumer-failure-paths.svg", [consumer は side effect、offset commit、retry topic、DLQ、redrive をまとめて設計する必要がある], width: 96%)

=== consumer の並列化はどこで行うのか

consumer の throughput を上げたいとき、単純に instance 数を増やしたくなります。しかし並列化の場所は 1 つではありません。

- partition 数を増やす
  group 全体の並列度上限が増える
- consumer instance 数を増やす
  partition 所有を分散できる
- 1 partition 内で handler worker を増やす
  処理 throughput は上がるが、順序維持が難しくなる
- batch 化する
  1 record あたりの固定コストを減らせる

ここで大切なのは、何の順序を守りたいかです。`order_id` 単位の順序が必要なら、同じ order に属する record を同時に別 worker が処理しない工夫が要ります。並列化は無料ではなく、ordering scope と引き換えです。

== lag を設計信号として読む

consumer lag は「まだ読み終えていない量」を表します。多くの運用では lag が増えると「worker を増やそう」で終わりがちですが、それだけでは不十分です。lag は system がどこかで入力速度に追いつけていないサインです。

lag 増加の原因は大きく分けて次です。

- handler が遅い
  外部 API、DB、重い CPU 処理
- partition が偏っている
  hot key が一部 partition に集中
- rebalance や deploy が多すぎる
  consumer が安定して働けていない
- retry / poison message
  同じ record で足踏みしている

したがって lag を見たら、「平均 throughput が足りない」のか「一部 partition だけが詰まっている」のかを分けて見る必要があります。単一の平均値では分かりません。

```text
lag dashboard
  email-group / partition-2    15
  analytics-group / partition-2 54000
  analytics-group / partition-7 30
  search-group / partition-2   10
```

この例なら、`analytics-group` の `partition-2` だけが明らかにおかしいことが分かります。単なる instance 不足より、hot partition や poison message を疑うべきです。

=== rebalancing のコスト

consumer group の便利さは、instance が増減しても partition を再配分できることです。しかし rebalance は無料ではありません。所有者が切り替わる瞬間、処理は一時停止し、in-flight record の扱いも慎重さが要ります。

rebalancing が高頻度で起きる原因としては次があります。

- autoscaling が敏感すぎる
- consumer process が不安定ですぐ落ちる
- deploy が頻繁で rolling update が長い
- session timeout や heartbeat 設定が実態に合っていない

この問題を単に `Kafka` の都合と見るのは危険です。rebalancing の頻発は、consumer を安定運用できていないという architectural signal です。

== poison message は「壊れた 1 件」では済まない

poison message とは、特定 record だけが何度処理しても失敗する状態を指します。schema 不整合、想定外の field 値、外部依存の永続的 4xx、アプリケーション bug などが原因です。

1 件だけなら些細に見えますが、`Kafka` ではその 1 件が partition の進行を止めることがあります。`Email Worker` が offset 1532 で毎回落ちれば、1533 以降へ進めないかもしれません。だから poison message は queue 全体の問題になります。

対策は主に 3 つあります。

- fail fast して警告を上げる
- retry policy を分け、即時 retry と遅延 retry を区別する
- 最終的に DLQ へ隔離する

重要なのは、DLQ を「とりあえず捨てる場所」にしないことです。何を持って poison と判断したのか、あとでどう redrive するのかを決めて初めて運用になります。

=== DLQ と redrive

DLQ を設計するとき、少なくとも次を決める必要があります。

- 何回失敗したら隔離するか
- 元 topic / partition / offset / error をどこまで保存するか
- redrive は手動か自動か
- redrive 時に同じ consumer code を使うのか、修復専用 job を使うのか

`Search Indexer` のように replay が比較的安全な consumer では、修正後に DLQ からまとめて redrive しやすいかもしれません。一方 `Email Worker` では、古い注文確認メールを大量にまとめて再送すると user 体験が悪化することがあります。consumer ごとに policy を分ける必要があります。

#editorial_note[
  DLQ は隔離であって解決ではありません。DLQ 件数が 0 であることより、「入ったら誰が見て、どう戻すか」が明確であることのほうが重要です。
]

=== idempotent consumer の設計

consumer は at-least-once を前提に設計するほうが安全です。つまり、同じ record を複数回処理しても業務的に破綻しないようにします。

方法は複数あります。

- processed table を持つ
  `event_id` を記録し、2 回目以降を無視する
- upsert を使う
  検索 document のように最終状態へ収束させる
- 外部 API の idempotency key を使う
  メール送信 provider に stable key を渡す

継続例では、`Analytics Consumer` は processed table か集計 upsert で対応しやすく、`Search Indexer` は document upsert が自然です。`Email Worker` は provider の API が許せば idempotency key を使い、なければ送信履歴を自前で持つ必要があります。

```go
func (h *EmailHandler) Handle(rec Record) error {
    event := decodeOrderCreated(rec.Value)
    if h.sentLog.Exists(event.EventID) {
        return nil
    }
    if err := h.mailer.SendConfirmation(event.OrderID, event.CustomerID); err != nil {
        return err
    }
    return h.sentLog.MarkSent(event.EventID)
}
```

この処理も、`SendConfirmation` は成功したが `MarkSent` が失敗した、というケースを考える必要があります。idempotency は小さな boolean ではなく、境界ごとの設計です。

=== ケース 1: Email Worker で二重送信が起きた

もっとも起きやすい事故の一つはこれです。メール provider への call は成功したが、そのあと process が落ち、offset commit も送信履歴更新もされなかった。その結果、再起動後に同じ record をもう一度処理し、ユーザへ 2 通送ってしまう、という流れです。

```text
offset 1532 polled
  -> provider send ok
  -> process crash
restart
offset 1532 reprocessed
  -> duplicate mail
```

この事故から分かるのは、`commit 後に side effect` が危険なだけではないということです。`side effect 後に commit` でも idempotency がなければ重複は起きます。だから Email Worker では `event_id` ベースの送信履歴か provider 側 idempotency が要ります。

=== ケース 2: Analytics lag と hot partition

analytics-group の lag だけが急増しているのに、instance 数を増やしても改善しないことがあります。典型的には `merchant_id` に偏りがあり、大規模店舗の event だけが 1 partition へ集中しているケースです。

このとき重要なのは、平均 lag ではなく partition ごとの差です。特定 partition だけが高いなら、単純な scale out より key 設計や batch 処理の見直しが効きます。consumer lag は運用数字ではなく、data model の問題を教えてくれることがあります。

=== ケース 3: Search Indexer の作り直し

検索 index の mapping 変更や bug 修正で、Search Indexer を全件作り直したくなることがあります。こういうとき replay が効く consumer 設計は強いです。

ただし実務では、`live traffic を処理しながら replay するのか`、`別 index を作って切り替えるのか`、`replay 中の lag alert をどう扱うか` を決める必要があります。単に `Kafka` に record が残っているだけでは足りません。rebuild 運用も consumer design の一部です。

== backpressure はどこでかけるか

consumer の世界でも backpressure は重要です。broker からいくらでも取り込んでしまうと、consumer process 内で queue が伸び、メモリと latency が悪化します。したがって「いま処理できる分だけ読む」という設計が必要です。

かける場所としては次が考えられます。

- poll batch size を絞る
- in-flight handler 数を制限する
- downstream `RPC` 呼び出しの concurrency を制限する
- lag が閾値を超えたときに一部機能を degraded にする

たとえば `Search Indexer` は batch update が効きやすいので、大きめ batch と bounded worker pool が有効かもしれません。一方 `Email Worker` は外部 provider rate limit が厳しいなら、poll 量より送信 concurrency を制御したほうが効果的です。

=== consumer observability

producer と違い、consumer の observability では「どこで止まっているか」を細かく見る必要があります。最低限ほしい指標は次です。

- lag per group / partition
- records consumed per second
- processing latency
- retry count
- DLQ count
- rebalance count
- handler error taxonomy

さらに、end-to-end で `order-created` から `email-sent` まで何分かかっているかを見ると、business impact を把握しやすくなります。`Kafka` の監視だけ green でも、実際には user 通知が 30 分遅れていることはあり得ます。

=== retry topic と delay queue

poison ではないが、その場ですぐ再実行するべきでもない失敗があります。たとえば一時的なメール provider rate limit や短時間の検索 cluster 過負荷です。この場合、即時 retry で同じ consumer loop を詰まらせるより、遅延 retry 用の topic や queue に逃がす構成が有効なことがあります。

考え方は単純です。

- すぐ retry したい短い障害
  in-memory retry や small backoff
- 数十秒〜数分待ちたい障害
  retry topic / delayed queue
- 永続的に失敗する障害
  DLQ

この分岐を持つだけで、正常 traffic と障害 traffic を分けやすくなります。

=== stuck partition を見分ける

lag が大きいだけでは、`全体的に遅い` のか `1 件で止まっている` のか分かりません。stuck partition を見分けるには、offset の進み方と error log を一緒に見る必要があります。

典型的には次の見え方になります。

- lag は増えているが offset は少しずつ進む
  throughput 不足や downstream 遅延を疑う
- lag は増えており、特定 offset で止まっている
  poison message や handler bug を疑う
- lag は上下に揺れ、rebalance count も増えている
  process instability や autoscaling を疑う

この切り分けを持っておくと、`worker を増やす` 以外の対処が見えやすくなります。

=== commit batch と重複窓

consumer throughput を上げるために、offset commit を batch 化することがあります。これはよくある最適化ですが、同時に `どこまで再処理され得るか` の窓を広げます。

たとえば 100 件まとめて commit する設計では、99 件目まで side effect が終わったあとに process が落ちると、かなり広い範囲が再処理対象になります。`Analytics Consumer` なら許容できるかもしれませんが、`Email Worker` では危険です。

つまり batch commit は単なる性能 tuning ではなく、`重複窓をどこまで許容するか` という設計判断でもあります。

=== handler 内の下流 `RPC` をどう守るか

consumer の実処理がさらに下流 `RPC` を呼ぶ場合、非同期設計だから安全だとは言えません。`Search Indexer` が検索 cluster を、`Email Worker` が provider API を呼ぶなら、そこにも timeout、retry、concurrency limit が要ります。

ここで重要なのは、consumer が lag を抱えているときほど無制限 retry をしたくなる誘惑が強いことです。しかしそれをやると、`consumer lag` が `downstream RPC の障害増幅器` になります。

したがって worker 側でも次を分けて考える必要があります。

- その場で少し retry するのか
- retry topic に逃がすのか
- DLQ に送るのか
- いったん consumer 自体を pause して downstream を守るのか

非同期 worker は同期 path の外にあるだけで、依存先保護の責務までは消えません。

=== pause/resume を運用に組み込む

`Kafka` consumer には、状況によって特定 partition や group の取り込みを一時的に弱めたい場面があります。たとえば replay 中だけ通常 traffic を優先したい、外部 provider 障害の間は Email Worker を抑えたい、といった場面です。

このとき `process を kill する` だけだと、rebalance が増えたり、復旧後の burst が大きくなったりします。そこで pause/resume や bounded intake を運用の選択肢として持っておくと、system 全体を壊しにくくなります。

重要なのは、pause する条件を事前に決めておくことです。lag、error rate、provider quota、warehouse load のどれを見て止めるのかが曖昧だと、結局は現場の即興になります。

=== ケース 4: replay と通常 traffic がぶつかる

Search Indexer を作り直すために replay を始めたところ、通常の注文更新まで遅くなったとします。これは replay 自体が悪いのではなく、`通常 traffic と backfill traffic を別物として扱っていない` ことが問題です。

対策としては次があります。

- replay rate を制限する
- replay を別 consumer group や別 index へ逃がす
- 通常 traffic 用の worker 枠を別に確保する
- freshness alert を replay 中だけ別評価にする

replay は便利ですが、本番 traffic と同じ資源を食う以上、通常系と分離して考えるほうが安全です。

=== ケース 5: Email provider が rate limit した日

Email Worker では、`Kafka` 自体は健康でも外部 provider の quota に当たって処理が詰まることがあります。このときにありがちな誤りは、lag を見て worker 数を増やすことです。実際には provider 側制限にさらに強く当たり、失敗率だけが上がります。

このケースで見るべきなのは次です。

- provider への 429 / quota error rate
- worker 側 retry が即時になっていないか
- 送信 concurrency が quota に対して高すぎないか
- retry topic へ逃がせているか

非同期 worker の遅さは、いつも `Kafka` の throughput 問題ではありません。外部依存の契約がボトルネックになっていることも多いです。

=== consumer ごとの redrive 方針を分ける

同じ `OrderCreated` を読む consumer でも、redrive のやり方は同じではありません。簡単な表にすると違いが見えます。

```text
Redrive policy sketch

Email Worker
  目的: 通知欠損の補完
  注意: 古い通知を大量送信しない

Analytics Consumer
  目的: 欠損集計の回復
  注意: warehouse への負荷を制御する

Search Indexer
  目的: projection の再構築
  注意: live traffic と rebuild を分ける
```

この表があるだけで、`DLQ からまとめて戻せばよい` という雑な発想を避けやすくなります。

=== lag を見たときの 5 分トリアージ

運用では、深い分析の前に `最初の 5 分で何を見るか` を固定しておくと強いです。consumer lag なら次の順が効きます。

1. どの group / partition が高いかを見る
2. offset が進んでいるか止まっているかを見る
3. rebalance count と process restart を見る
4. downstream `RPC` / DB / provider error を見る
5. すぐ止血が必要なら pause、retry topic、DLQ を選ぶ

この順序を持つと、`とりあえず台数を増やす` に流れにくくなります。

== 章末で見る consumer の責務

consumer は `topic を読む人` ではありません。offset、side effect、lag、retry、DLQ、redrive を束ねて、自分の責務を時間的に引き受ける component です。

producer が `どんな事実を残すか` を決めるなら、consumer は `その事実をどの速度で、どの失敗許容で、どこまで正確に反映するか` を決めます。非同期設計の本体は、ここにあります。

典型的には次のシグナルがあります。

- 同じ offset で同じ error が繰り返される
- CPU や network は低いのに lag だけ増える
- 他 partition は進んでいる

この状態では、worker を増やしても解決しません。record 内容、schema、外部依存の入力条件を見るべきです。

=== batch handler と partition-local state

consumer の throughput を上げるために batch handler を使うことがあります。analytics や search index 更新では、1 record ごとより 100 件まとめて処理したほうが効率的です。ただし batch 化すると、どこまで成功してどこで失敗したかが曖昧になりやすくなります。

また、一部の consumer は partition-local state を持ちたくなります。たとえば `merchant_id` ごとの集計 cache を partition 単位で持つと速いことがあります。しかし rebalance が起きると state の所有者が変わるため、warmup や flush の設計が要ります。

つまり batch と local state は性能を上げますが、rebalance と failure recovery の複雑さも上げます。性能最適化は consumer model の一部です。

=== redrive の実務手順

DLQ や retry topic を設けても、redrive 手順が曖昧だと本番では使えません。実務で最低限必要なのは次の順序です。

1. 隔離理由を確認する
2. 同じ失敗が live traffic でも続いていないか確認する
3. consumer code / schema /外部依存を修正する
4. 小さなサンプルで再投入し、重複や副作用を確認する
5. 問題なければ本体を段階的に redrive する

ここでいきなり大量 redrive すると、古い障害 traffic が live traffic を押し潰すことがあります。redrive も backpressure を持つべきです。

=== consumer 設計レビューの問い

consumer 側レビューでは、少なくとも次を確認すると抜け漏れが減ります。

1. side effect 完了と offset commit の順序は明示されているか
2. replay-safe か、そうでないかが決まっているか
3. lag がどの freshness budget を超えると障害か
4. retry topic、DLQ、pause の使い分けがあるか
5. redrive の owner と手順が runbook 化されているか

consumer は application loop に見えますが、実際には運用設計そのものです。

== 章末まとめ

consumer 設計の本質は、「何を 1 回に見せたいか」「何を replay 可能にしたいか」「どの lag まで耐えられるか」を consumer ごとに定義することです。同じ topic を読んでいても、Email、Analytics、Search は全く同じではありません。

非同期基盤は一見 generic に見えますが、実際の責務は極めて domain-specific です。だから consumer 章では常に `誰に何が起きるか` を考え続ける必要があります。

=== この章の設計判断の要点

非同期設計の中心は producer ではなく consumer です。なぜなら、実際の side effect は consumer 側で起きるからです。lag、rebalancing、poison message、DLQ、idempotency を扱えるようになって初めて、`Kafka` は本番で役に立ちます。

継続例に戻ると、`Email Worker`、`Analytics Consumer`、`Search Indexer` は同じ `order-created` を読んでいても、処理特性も失敗時挙動も違います。ここを全部同じテンプレートで扱わず、consumer ごとに責務を言語化するのが重要です。

#caution[
  `Kafka` 導入後の典型的な失敗は、「publish できたから終わり」と思って consumer 側を後回しにすることです。実務では、下流 consumer の設計不足がもっとも長く痛みます。
]

=== 演習

1. `Email Worker`、`Analytics Consumer`、`Search Indexer` で、それぞれ許容できる lag の大きさがなぜ違うか説明してください。
2. consumer lag が急増したとき、instance 数不足と hot partition をどう見分けるか整理してください。
3. あなたの system で poison message が 1 件出たとき、どの partition / job / user impact が止まるかを書き出してください。
4. `commit 前に side effect` と `side effect 前に commit` のどちらがどの semantics に寄るか、具体例で比較してください。
5. ある consumer を replay-safe にするために、payload と handler をどう変えるべきか設計してください。
6. あなたの system の DLQ について、redrive の owner と段階的手順を書き出してください。

=== この章の出口

consumer を side effect と lag を管理する本体として見ると、次に必要なのは hop をまたいだ見方です。次章では同期 `RPC` と consumer の振る舞いをつなぎ、end-to-end consistency を整理します。
