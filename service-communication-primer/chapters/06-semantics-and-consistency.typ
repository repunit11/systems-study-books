#import "../theme.typ": checkpoint, caution, editorial_note, diagram

= delivery semantics、ordering、整合性

前章までで、同期 `RPC` と `Kafka` consumer の設計を別々に見ました。しかし現実の system では、1 回の業務操作がその両方をまたぎます。注文 API が inventory と payment を同期的に呼び、DB に注文を書き、あとで `Kafka` に event を流し、consumer がメールや検索更新を行う。ここで問われるのは、「結局この注文は何回作られたことになるのか」「どの順序が守られるのか」「途中で落ちたらどこから回復するのか」です。この章では delivery semantics と consistency を end-to-end の視点で整理します。

#checkpoint[
  この章では次を押さえます。

  - at-most-once / at-least-once / exactly-once を end-to-end でどう読むか
  - ordering scope をどこで定義するか
  - dedup、processed table、upsert をどう使い分けるか
  - outbox pattern と saga の役割
  - replay / backfill を前提にした設計
]

== semantics は transport のラベルではない

at-most-once、at-least-once、exactly-once は有名な言葉ですが、transport の feature label として読むと危険です。本当に知りたいのは、「user や業務から見て、その操作が何回起きたように見えるか」です。

たとえば `Order Service -> Payment Service` の `Authorize` call は idempotency key なしだと、timeout 後 retry により二重オーソリが起きるかもしれません。`Kafka` で `order-created` を publish できても、consumer が 2 回処理すればメールは 2 通送られるかもしれません。つまり end-to-end semantics は、各 hop の組み合わせで決まります。

=== at-most-once の具体像

at-most-once は「失われる可能性はあるが、重複はしない」方向です。たとえば次のような設計です。

- timeout 後に retry しない `RPC`
- consumer が side effect 前に offset を commit する
- best-effort logging や metrics event

この設計が悪いとは限りません。たとえば low-value analytics や debug event なら、少し落としてもよいことがあります。しかし billing、inventory、user notification のような重要機能では危険です。重要なのは、「落ちてもよいもの」にだけ意識的に適用することです。

=== at-least-once の具体像

実務で最もよく見るのは at-least-once です。`失わないことを優先し、重複は application で吸収する` という立場です。

典型例は次です。

- timeout 後に retry する `RPC`
- side effect 完了後に offset を commit する consumer
- outbox relay が publish 成功まで同じ row を再送し得る構成

この世界では、重複は異常系ではなく通常系です。したがって「重複が起きるかもしれない」ではなく、「いつも起きる前提で吸収する」と考えるほうが安全です。

=== exactly-once をどう読むか

exactly-once は魅力的ですが、境界を限定せずに使うと会話が壊れます。多くの場合 exactly-once は、「ある storage / transaction の中で二重適用を見せない」ことを指します。system 全体のあらゆる外部 side effect まで魔法のように 1 回にしてくれるわけではありません。

たとえば `Kafka` transaction が有効でも、外部メール API や外部 payment gateway への call まで自動で exactly-once にはなりません。そこで重要なのは、「どの境界で何を 1 回に見せたいのか」を具体化することです。

#editorial_note[
  exactly-once を使いたくなったら、必ず「どの境界の中で」「何に対して」「どの観測者から見て」成立する主張なのかを書き下してください。そこが曖昧な exactly-once は設計文書として役に立ちません。
]

```text
Semantics comparison

at-most-once
  失う可能性: ある
  重複: 起きにくい
  向いている: low-value telemetry

at-least-once
  失う可能性: 減る
  重複: 起き得る
  向いている: 多くの業務処理

exactly-once (bounded)
  失う可能性: 境界内ではなくなる
  重複: 境界内では起きない
  向いている: 特定 storage / transaction の中
```

== ordering scope を決める

順序は強い制約です。だからこそ scope を絞る必要があります。システム全体で total order を守ろうとすると throughput も可用性も厳しくなります。多くの場合、本当に必要なのは次のような局所順序です。

- 同じ `order_id` に関する更新順序
- 同じ `customer_id` に関する会員状態更新順序
- 同じ `merchant_id` に関する売上締め処理順序

継続例では、注文ライフサイクルの遷移を見る consumer にとっては `order_id` 単位の順序が重要です。一方 analytics 集計では厳密な total order は不要で、event time に基づいて後で吸収できることも多いでしょう。用途によって順序要件は違います。

=== reorder は自然に起きる

順序が崩れる原因はたくさんあります。

- `RPC` retry が遅れて届く
- producer が別 partition へ送る
- consumer が内部で parallel 処理する
- rebalance で一時停止し、別 partition だけ先に進む
- outbox relay の再送で append 時刻がずれる

したがって「順序が大事」と言うだけでは足りません。受け手側で古い更新を見分ける仕組みが必要です。version number、state machine validation、monotonic sequence、event time watermark などがそのために使われます。

== dedup のやり方

重複吸収の方法は、対象によって変わります。代表的なのは次の 3 つです。

- processed table
  `event_id` や `idempotency_key` を保存し、2 回目以降を無視する
- upsert
  同じキーに対して最終状態を書き込む
- versioned update
  新しい version だけを受け付け、古い更新を拒否する

`Email Worker` なら processed table や送信履歴が効きやすく、`Search Indexer` なら upsert が自然です。注文 status の更新 consumer では versioned update が向いていることがあります。重要なのは、`consumer だから processed table` と決め打ちしないことです。

```go
func (p *ProcessedStore) Seen(eventID string) bool

func HandleOrderCreated(rec Record) error {
    event := decode(rec.Value)
    if processed.Seen(event.EventID) {
        return nil
    }
    if err := projector.UpsertOrder(event); err != nil {
        return err
    }
    return processed.MarkSeen(event.EventID)
}
```

この形でも、`UpsertOrder` 成功後に `MarkSeen` が失敗すれば再処理は起きます。だからこそ、projector 自体も idempotent であるほうが安全です。

=== idempotency key の寿命を決める

idempotency key は導入しただけでは不十分で、どのくらい保持するかを決める必要があります。短すぎると遅延 retry を吸収できず、長すぎると storage と lookup cost が増えます。

継続例では、payment authorization の key は `同じ注文に対する重複オーソリを防ぐ` ことが目的です。したがって保持期間は、network timeout 数秒ではなく、user の再送、mobile client の再試行、operator の手動再実行まで含めて考えるべきです。

ここでの問いは次です。

- 重複が最も遅れて再到達し得るのはいつか
- provider 側の idempotency window と整合しているか
- key と request body の対応を検証するか
- 期限切れ後の再送をどう扱うか

idempotency は `重複しない魔法の文字列` ではなく、寿命を持つ契約です。

=== end-to-end invariant を先に書く

整合性の議論で役立つのは、技術選択の前に `この業務操作で破ってはいけない条件` を短く書くことです。継続例なら、たとえば次のように書けます。

- 1 つの注文 intent から確定注文は高々 1 つ
- payment authorization は同じ intent で重複課金しない
- `accepted` を返した注文は、あとから追跡可能である
- 通知や検索反映は遅れてもよいが、欠損は検知できる

この invariant があると、`どこで idempotency を持つべきか`、`どこで replay を許すか`、`どこで manual recovery が必要か` が議論しやすくなります。整合性は抽象的な美しさではなく、破ってはいけない条件の集合です。

== outbox pattern

`Order Service` が同期 `RPC` で inventory と payment を済ませたあと、DB へ注文 row を書き、`Kafka` に `order-created` を publish したいとします。ここで最も危険なのは、`DB 書き込み成功 / publish 失敗` や `publish 成功 / DB 書き込み失敗` のズレです。

この問題に対して強いのが outbox pattern です。つまり、本来の state 変更と「あとで publish すべき event」を同じ DB transaction に書く方法です。

```text
DB transaction
  1. insert into orders(...)
  2. insert into outbox(event_id, topic, payload, status='pending')
commit

Outbox Relay
  3. read pending rows
  4. publish to Kafka
  5. mark outbox row as sent
```

この構成なら、「注文 row はあるが event が永遠に失われる」をかなり減らせます。relay が落ちても pending row は残るからです。

=== outbox が解決しないこと

outbox は強力ですが万能ではありません。解決するのは、主に `DB state` と `publish request` のずれです。consumer 側の side effect や外部 API 呼び出しまで自動で整合させてくれるわけではありません。

また relay は再送し得るので、`Kafka` 側や consumer 側では依然として重複を扱う必要があります。つまり outbox は exactly-once の魔法ではなく、「もっとも危険な境界の一つを整理する」道具です。

```text
Dual write vs outbox

Dual write
  1. write DB
  2. publish
  問題: 途中失敗でズレやすい

Outbox
  1. write DB + outbox in one tx
  2. relay later
  利点: publish request の欠落を減らせる
  注意: relay/consumer 側の重複処理は残る
```

== saga と補償

注文作成では、inventory reservation と payment authorization を別 service が持っている以上、単一 DB transaction のようには扱えません。そこで出てくるのが saga 的な考え方です。つまり、各 service がローカルに変更を行い、途中失敗時には補償 action を流すという設計です。

継続例では、たとえば次のような補償が考えられます。

- payment authorization に成功後、order DB 書き込みが失敗
  `CancelAuthorization` をベストエフォートで呼ぶ
- inventory reservation に成功後、payment が拒否
  `ReleaseReservation` を呼ぶ
- order created 後、fraud review で拒否
  `OrderCancelled` event を新たに流す

ここで大切なのは、補償は rollback と同じではないことです。外部 gateway の取消は完全に元へ戻す保証ではないかもしれませんし、遅延や手動介入が必要なこともあります。saga は「完全な巻き戻し」ではなく、「業務的に許容できる状態へ戻す」仕組みです。

=== 具体例: 注文の end-to-end timeline

継続例を end-to-end で書くと、次のような timeline になります。

#diagram("assets/consistency-timeline.svg", [同じ注文でも、client、DB、mail、search、analytics では見える時刻がずれる], width: 96%)

この timeline では、client が成功を観測するのは `T6` です。しかし全ての副作用が終わるのは `T10` 以降です。ここを切り分けて考えることが、サービス間通信の設計そのものです。

=== ケース: accepted だがメールはまだ送られていない

実務でよく起きる混乱は、この状態を `失敗` と呼ぶ人と `正常` と呼ぶ人が混在することです。

```text
T6 client sees accepted
T7 outbox relay is healthy
T8 email-group lag grows for 3 minutes
T9 order detail is visible, mail is not yet sent
```

本書の継続例では、これは `注文整合性の失敗` ではなく `通知 freshness の遅れ` として扱います。もちろん遅れが budget を超えれば障害ですが、注文成立そのものとは切り分けます。

このように `何が壊れたのか` を分類できると、システム全体を止めるべき障害と、degraded で耐えるべき障害を区別しやすくなります。

== replay と backfill

`Kafka` を使う大きな利点の一つは replay です。新しい consumer を追加したい、bug 修正後に再集計したい、検索 index を作り直したい、といったときに、過去 record を読み直せます。

しかし replay を有効にするには、最初からそれを意識した schema と consumer 設計が必要です。

- event に十分な snapshot を持たせる
- consumer を idempotent にする
- external side effect を無闇に再実行しない
- event time と processing time を区別する

`Search Indexer` は replay と相性がよい consumer ですが、`Email Worker` は相性が悪いことがあります。`再読可能である` と `再実行可能である` は違うのです。

=== read-your-own-writes と projection

非同期 projection を入れると、「注文を作った直後に一覧で見えない」問題が出てきます。これは read-your-own-writes の要求と projection lag の衝突です。

対策はいくつかあります。

- user-facing read は同期 DB を見に行く
- projection が追いつくまで pending 表示を出す
- 特定 user だけ write-side read model を優先する

ここで大事なのは、projection lag を隠そうとして全てを同期化しないことです。user に何を見せれば自然かを product と詰めるほうが、本質的です。

=== freshness budget を product requirement にする

projection lag を議論するとき、`eventual consistency` という抽象語だけでは弱すぎます。必要なのは、どの read model が何秒以内に追いつくべきかという freshness budget です。

たとえば継続例では次のように分けられます。

- 注文詳細画面
  ほぼ即時、もしくは write-side read で補う
- 注文確認メール
  数分以内なら許容
- analytics dashboard
  10 分遅延でも業務上許容
- search index
  数十秒〜数分の遅れを許容

この予算が明確だと、lag alert、replay 優先度、degraded mode の会話が具体的になります。整合性は storage の性質だけでなく、product の期待値でも決まります。

=== cancellation event をどう扱うか

注文システムでは `OrderCreated` だけで終わりません。後から `OrderCancelled`、`PaymentFailed`、`InventoryReleased` が流れるかもしれません。このとき consumer は「最新 event だけ見ればよい」のか、「履歴全体を state machine として見るべきか」を決める必要があります。

検索 indexer なら最新状態へ upsert すればよいかもしれませんが、analytics では `created` と `cancelled` の両方を別イベントとして数えたいことがあります。つまり同じ event stream でも consumer によって意味の切り取り方が違います。

=== inquiry path を consistency の一部として見る

分散システムでは、`最初の request で答え切れない` 状態がどうしても出ます。payment timeout、relay 遅延、consumer lag などです。このとき重要なのは、結果確認用の inquiry path を整合性設計の一部として扱うことです。

たとえば注文システムでは、次のような問い合わせがあり得ます。

- `client_request_id` から注文成立有無を確認する
- `order_id` から現在 state を確認する
- `event_id` から consumer 側反映状況を運用者が追える

この経路があると、`unknown なら再送` ではなく `unknown なら確認` という運用が可能になります。整合性は write path だけでなく inquiry path でも支えられます。

=== projection rebuild と snapshot

長く運用していると、projection を丸ごと作り直したくなることがあります。検索 index の mapping を変えた、analytics の定義を変えた、新しい read model を追加した、などです。このとき replay は強い武器ですが、log が長大になるほど時間もかかります。

そこで実務では snapshot や checkpoint を併用することがあります。たとえばある日付時点の集計 state を保存し、その後ろだけ replay する構成です。ただし snapshot を導入すると、snapshot 自体の整合性と version 管理という新しい課題も入ります。最初から必要とは限りませんが、長期運用では知っておく価値があります。

=== saga state をどこに持つか

補償を伴う saga を実装するとき、`いまどの段階まで進んでいるか` をどこで持つかが問題になります。in-memory だけでは再起動で失われるので、永続化された state machine が必要になることがあります。

注文システムなら、`pending_inventory`、`pending_payment`、`accepted`、`cancel_requested` のような状態を order row や workflow table に持つ設計があり得ます。重要なのは、補償もまた明示的な状態遷移だと理解することです。

=== manual recovery path を先に決める

整合性の設計では、自動回復だけでなく手動回復の道も決めておくべきです。実務では、provider 障害、schema 破壊、長時間 lag のように、完全自動では片付かない場面が必ず出ます。

継続例なら次のような手動回復が考えられます。

- payment status を provider 側で照会して注文状態を訂正する
- DLQ の `OrderCreated` を修復後に redrive する
- `OrderCancelled` を手動投入して補償フローを進める
- 検索 index を再構築して projection を追いつかせる

ここを設計に含める理由は、`自動化できないから設計対象外` ではないからです。むしろ人手介入が必要な境界こそ、事前に責務と証跡を決めておく価値があります。

=== unknown state を短く保つ

整合性の実務で厄介なのは、`成功か失敗かまだ断言できない` 状態です。payment timeout 直後や response loss 直後は、まさにこれに当たります。

この状態を完全になくすのは難しくても、短く保つ設計はできます。

- idempotency key で重複再送を吸収する
- inquiry path で後追い確認できるようにする
- provider status check を runbook 化する
- `accepted / rejected / unknown` の意味を product と共有する

unknown state を設計に入れないと、現場では結局 `多分失敗だろう` で再送され、重複実行が増えます。

=== 状態機械として見る

注文の整合性を議論するとき、`created`、`paid`、`cancelled` を単なる event 名として見るだけでは足りません。consumer や UI は、最終的に何らかの state machine を見ています。

```text
pending_submission
  -> reserved
  -> authorized
  -> accepted
  -> cancelled
  -> refunded
```

この状態機械を持つと、`OrderCancelled` が `OrderCreated` より先に見えたらどうするか、`PaymentFailed` が `accepted` 後に来たらどう扱うか、といった議論がしやすくなります。整合性の議論は、event 名より state transition で行うと整理しやすいです。

=== 補償が効きにくい操作

saga を入れると何でも元に戻せそうに見えますが、実際には補償が難しい操作があります。メール送信、外部通知、物理配送、外部パートナー連携などです。

こうした操作では、`完全 rollback` を期待するより、`後続の訂正イベント` や `運用フロー` を前提にしたほうが現実的です。だからこそ side effect の順序と user-facing meaning を慎重に決める必要があります。

== consistency budget を言葉にする

最後に重要なのは、整合性もまた予算の問題だと捉えることです。完全同期、完全順序、完全 1 回実行を全部同時に求めると、可用性と複雑性のコストが急激に上がります。

したがって設計では、少なくとも次を言葉にする必要があります。

- どの操作だけは二重実行が許されないか
- どの read model は遅れてもよいか
- どの補償は自動で、どこから人手か
- どの境界で exactly-once 風の性質を求めるか

この会話ができると、`整合性が大事` という抽象論から一歩出て、実際の system 制約へ落とし込めます。

=== consistency レビューの問い

章の最後に、整合性レビュー向けの短い問いを置いておきます。

1. この操作で破ってはいけない invariant は何か
2. unknown state が起きたとき、誰がどう確認するか
3. replay-safe な consumer と unsafe な consumer はどれか
4. manual recovery が必要な境界はどこか
5. freshness budget を超えたとき、どの user impact が出るか

整合性の議論は抽象化しやすいので、このくらい具体的な問いへ落とすと設計レビューが進みやすくなります。

== 章末まとめ

consistency は、`Kafka` や database の専門用語だけではありません。注文という業務操作が `何回起きたことになるか`、`何がいつ user に見えるか` を決める設計です。outbox、dedup、replay、saga はそのための道具です。

大切なのは `どこか一箇所で exactly-once っぽい` ことではなく、hop をまたいだときにどの性質が残るかを把握することです。

=== consistency を product と共有する

backend だけで整合性を議論すると、「eventual consistency だから」で片付けがちです。しかし product と共有すべきなのは、いつ何が user に見えるかです。

たとえば注文直後に検索結果へ反映されなくてもよいのか。confirmation email が 5 分遅れるのは許容か。analytics dashboard が 10 分遅れても問題ないか。こうした要件が分かって初めて、どこで synchronous にし、どこで asynchronous にし、何を replay 可能にするかが決まります。

#caution[
  consistency は storage の専門用語であるだけでなく、user-visible state の約束でもあります。`eventual consistency` と書くだけでは設計になりません。
]

=== この章の設計判断の要点

delivery semantics と consistency は、`Kafka` の章だけで完結する話ではありません。`RPC` retry、idempotency key、outbox、consumer dedup、replay が全部つながって初めて、end-to-end の性質が決まります。

注文システムでは、「注文を 1 回だけ作り、必要な副作用を重複許容で進める」ことが実際の設計目標です。そのために critical path では response の意味を固定し、境界では outbox を置き、consumer 側では idempotency を持たせます。

#editorial_note[
  分散システムで最も避けたいのは、「どこかが exactly-once らしいから全体も安全だろう」という推論です。全体の性質は hop の合成で決まります。
]

=== 演習

1. あなたの system で at-least-once を許容できる処理と、できない処理を分類してください。
2. `order-created` を replay したとき、`Email Worker` と `Search Indexer` のどちらが危険か、その理由を書いてください。
3. outbox pattern が解決するズレと、解決しないズレを 2 つずつ挙げてください。
4. `order_id` 単位の順序が崩れたとき、consumer 側でどう検出・吸収するかを設計してください。
5. あなたの system の中で、state machine として定義したほうがよいイベント列を 1 つ選んでください。
6. 補償が効きにくい side effect を 3 つ挙げ、それぞれ rollback 以外の回復策を考えてください。

=== この章の出口

end-to-end consistency の骨格が見えたら、最後に必要なのは障害時の判断順です。最終章では observability、ownership、使い分け、回復手順を playbook としてまとめます。
