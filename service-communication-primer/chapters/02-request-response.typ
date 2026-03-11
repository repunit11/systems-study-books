#import "../theme.typ": checkpoint, caution, editorial_note, diagram

= request/response と critical path

多くの system は、最初の一歩として request/response から始まります。user はボタンを押し、API server は依存先へ call し、結果を返します。構図としては単純です。しかし実務で本当に難しいのは、request/response そのものより、「どこまでを user-facing critical path に置くか」「そこで起きる失敗をどう user へ見せるか」です。この章では、注文作成フローを題材に、同期通信を設計するときの最初の判断軸を整理します。

#checkpoint[
  この章では次を押さえます。

  - user-facing critical path をどう切り出すか
  - data / temporal / failure contract をどう揃えるか
  - timeout、deadline、retry をどこで決めるか
  - idempotency key が必要になる理由
  - response を返した時点で何を保証したと見なすか
]

== critical path を先に決める

注文 API を設計するとき、多くの人は最初に「どの service を呼ぶ必要があるか」を考えます。しかしその前に決めるべきなのは、「何を今すぐ完了したことにしたいか」です。たとえば `注文を受け付けた` と `メール送信が終わった` では、user にとっての重要度と時間制約が違います。これを区別しないと、なんでも同期 `RPC` でつないでしまい、遅延と failure surface だけが増えます。

注文作成フローを分解すると、典型的には次の 3 層があります。

- 今すぐ答えが必要なもの
  在庫があるか、支払い方法が受け付けられるか、注文番号を返せるか
- 少し遅れてもよいが、確実にやりたいもの
  確認メール、分析イベント、検索 index 更新
- 後で再実行してもよいもの
  BI への集計反映、recommendation feature の学習入力

この 3 層を混ぜると、checkout 画面の 1 request が不必要に長くなります。critical path の設計は、単なる performance tuning ではなく、user-visible state の定義です。

=== 継続例: 注文作成の同期部分

本書では、次のような注文作成フローを最小モデルとして使います。

```text
Client
  -> API Gateway
    -> Order Service
      -> Inventory Service: reserve stock
      -> Payment Service: authorize payment
      -> Order DB: create order row
      -> Outbox Table: enqueue order-created event
  <- order accepted / failed
```

ここで critical path に入っているのは、少なくとも次の 4 つです。

1. request validation
2. 在庫確保
3. 支払いオーソリ
4. 注文 row の永続化

一方、メール送信や検索更新は入りません。これらは重要ですが、注文受理の瞬間に user が同期的に待つ理由は薄いからです。

#diagram("assets/submit-order-boundary.svg", [`SubmitOrder` の同期 boundary と、response のあとに残る非同期処理], width: 96%)

=== response が意味するものを固定する

注文 API が `200 OK` や `OrderAccepted` を返したとき、それは何を意味するのでしょうか。ここを曖昧にしたままでは、後続設計も曖昧になります。

最低でも次のどれかに落とす必要があります。

- 注文は確定し、在庫も支払いも押さえられた
- 注文は受け付けたが、後段処理はまだ進行中
- 注文リクエストは受理しただけで、確定可否は後で決まる

どれを選ぶかで同期部分の設計は変わります。EC の checkout なら、多くの場面では「支払いオーソリと在庫確保が済み、注文番号が発行された」ことまでを同期で保証したほうが自然です。逆に高トラフィックの業務システムでは、「受理のみ」で返して後段で審査する構成もあり得ます。大切なのは、response の意味を product と backend の両方で共有することです。

```text
Response meaning comparison

1. accepted = order row + inventory reserved + payment authorized
   長所: user に説明しやすい
   短所: 同期 path が重い

2. accepted = order row only, downstream continues later
   長所: 速い
   短所: user-visible state が曖昧になりやすい

3. received = request was queued, final result later
   長所: 極端な負荷に強い
   短所: product 側の状態設計が難しい
```

継続例では 1 を採ります。理由は、注文直後に `在庫は押さえられているのか`、`支払いは通ったのか` を user へ明確に返したいからです。副作用だけを非同期へ逃がし、注文確定そのものは同期 path に残します。

=== contract は 3 層ある

request/response を設計するとき、schema だけに注意が向きがちです。しかし同期通信の contract は少なくとも 3 層あります。

- data contract
  field 名、型、必須性、versioning
- temporal contract
  期待される latency、deadline、stream の寿命
- failure contract
  retry 可否、idempotency、部分成功の扱い、error taxonomy

たとえば `ReserveStock(order_id, items)` という `RPC` を考えます。field が合っていても、temporal contract が不明なら caller は何秒待つべきか分かりません。failure contract が不明なら、timeout 時に再送してよいのか分かりません。分散設計の難しさは、多くの場合 data contract 以外にあります。

==== data contract

注文システムでは、識別子の扱いがとくに重要です。`order_id`、`customer_id`、`payment_attempt_id`、`idempotency_key` の役割が混ざると、あとで重複や整合性で苦しくなります。`order_id` は業務上の注文を表し、`payment_attempt_id` は支払い試行を表し、`idempotency_key` は重複 request の吸収に使う、といった責務分離を最初からしておくと後が楽です。

==== temporal contract

checkout API 全体に 1.5 秒の deadline を持たせるなら、`Inventory Service` と `Payment Service` に同じ 1.5 秒をそのまま配るべきではありません。validation、DB 書き込み、serialization、network jitter にも時間が要るからです。したがって、親 request の budget を子 call に配分する設計が必要です。

==== failure contract

`Inventory Service` が `OUT_OF_STOCK` を返したときと、`UNAVAILABLE` を返したときでは意味が違います。前者は user に在庫切れを見せるべき失敗であり、後者は一時的障害かもしれません。同じ `error` でも retry 可否が違う以上、failure contract を型や status として明示する必要があります。

== timeout と deadline を予算として扱う

分散システムで timeout を設計するとき、「何秒にするか」を 1 つ決めれば終わりではありません。重要なのは、request 全体の budget をどの段にどう割り当てるかです。

たとえば checkout API 全体の SLO を 1.5 秒とします。おおまかに次のような配分が考えられます。

- request validation と認証: 100ms
- Inventory Service 呼び出し: 250ms
- Payment Service 呼び出し: 400ms
- DB transaction: 250ms
- serialization と network 余裕: 200ms
- retry / jitter / buffer: 300ms

この配分は固定値そのものが大事なのではなく、`無限に待たない` ことと `子 call が親 deadline を尊重する` ことが大切です。親 request がすでに失敗扱いになったあとも downstream が作業を続けると、resource を浪費し、結果の意味も曖昧になります。

```go
func (h *CheckoutHandler) SubmitOrder(ctx context.Context, req *SubmitOrderRequest) (*SubmitOrderResponse, error) {
    ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
    defer cancel()

    invCtx, invCancel := context.WithTimeout(ctx, 250*time.Millisecond)
    defer invCancel()
    reservation, err := h.inventory.Reserve(invCtx, ReserveStockRequest{
        OrderID: req.OrderID,
        Items:   req.Items,
    })
    if err != nil {
        return nil, mapInventoryError(err)
    }

    payCtx, payCancel := context.WithTimeout(ctx, 400*time.Millisecond)
    defer payCancel()
    payment, err := h.payment.Authorize(payCtx, AuthorizeRequest{
        OrderID:        req.OrderID,
        Amount:         req.TotalAmount,
        IdempotencyKey: req.IdempotencyKey,
    })
    if err != nil {
        _ = h.inventory.ReleaseBestEffort(ctx, reservation.ReservationID)
        return nil, mapPaymentError(err)
    }

    order, err := h.repo.CreateOrderWithOutbox(ctx, req, reservation, payment)
    if err != nil {
        _ = h.payment.CancelBestEffort(ctx, payment.AuthorizationID)
        _ = h.inventory.ReleaseBestEffort(ctx, reservation.ReservationID)
        return nil, err
    }
    return &SubmitOrderResponse{OrderID: order.ID, Status: "accepted"}, nil
}
```

この擬似コードで重要なのは、Go の細部ではありません。`親 deadline がある`、`子 call へ budget を切る`、`失敗時に次の挙動を決めている` という設計意図です。

== 4 つの通しケース

ここまでの議論を、同じ `SubmitOrder` API の 4 つの結果として並べると違いが見えやすくなります。

=== ケース 1: 正常系

```text
Client -> Order Service
  -> Inventory reserve ok
  -> Payment authorize ok
  -> DB tx ok
<- accepted(order_id=O1)
```

このケースでは、response の意味は比較的明快です。問題は、ここだけを見て設計してしまうことです。本当に難しいのは次の 3 ケースです。

=== ケース 2: 在庫切れ

```text
Client -> Order Service
  -> Inventory reserve => OUT_OF_STOCK
<- rejected(out_of_stock)
```

これは business failure です。retry や circuit breaker の対象ではなく、user-facing な結果として返すべきです。だから `500` や `INTERNAL` にしてはいけません。

=== ケース 3: 支払い timeout

```text
Client -> Order Service
  -> Inventory reserve ok
  -> Payment authorize => timeout
  -> Inventory release best effort
<- temporary_failure
```

ここで caller が知っているのは `timeout` だけです。payment が未実行か、実行済みだが response を失ったのかは分かりません。したがって automatic retry を入れるなら idempotency key が必須ですし、補償や後追い確認の設計も必要になります。

=== ケース 4: response loss 後の client retry

```text
Client -> Order Service
  -> Inventory reserve ok
  -> Payment authorize ok
  -> DB tx ok
  X response lost
Client retries same request
  -> Order Service sees same request identity
  -> returns prior result
```

このケースは実務で頻出です。backend 側から見ると最初の注文は成功しているのに、client は失敗したと思って再送します。ここで stable request identity がないと二重注文になります。

=== ケース 5: caller は諦めたが backend は遅れて成功した

```text
Client -> Order Service
  -> Inventory reserve ok
  -> Payment authorize slow but eventually ok
Client timeout / user leaves page
  -> DB tx ok
  -> response cannot be delivered
```

このケースでは、user は `失敗したかもしれない` と感じていますが、backend では注文が既に成立しているかもしれません。だから request/response 設計では、`失敗したかもしれない request の後追い確認をどうするか` まで含める必要があります。

単に client へ `もう一度送ってください` と案内すると、二重注文や二重課金の危険を広げます。分散環境では `caller が失敗を観測した` と `業務操作が失敗した` は同じではありません。

== stable request identity をどこで作るか

二重送信や response loss を吸収するには、request identity が stable でなければなりません。重要なのは、`同じ intent の再送` を同じ request と認識できることです。

選択肢は大きく 2 つあります。

- client が生成する
  network retry や page reload をまたいで同じ key を再利用しやすい
- server が最初の request で発行する
  初回送信前の再試行には弱い

注文のように user の再送が起こりやすい操作では、client もしくは gateway 境界で stable key を持つ設計のほうが強いです。大切なのは `order_id` と混同しないことです。`order_id` は成功後の業務 ID であり、request identity は成功前から存在しなければ再送吸収に使えません。

```text
Request identity choices

client_request_id
  用途: 同じ intent の再送吸収
  生存期間: 送信前から response 確認まで

order_id
  用途: 成立した注文の業務識別
  生存期間: 成功後

payment_idempotency_key
  用途: payment attempt の重複吸収
  生存期間: provider の idempotency window に依存
```

=== status inquiry を設計に含める

同期 API を設計するとき、意外に重要なのが `結果をあとから問い合わせる道` です。timeout や response loss が起きる以上、caller が `この request は最終的にどうなったか` を確認できるほうが安全です。

継続例なら、たとえば `client_request_id` で注文状態を引ける read API があると運用しやすくなります。

- `accepted`
  注文は成立している
- `rejected`
  業務的に成立していない
- `unknown / still processing`
  timeout 直後など、まだ確定していない

この問い合わせ経路があると、client 側も `失敗したら再送` 一択ではなくなります。結果確認と再送を分けられるからです。request/response の設計は、最初の 1 回の response だけでは閉じません。

=== retry してよい call と、してはいけない call

retry は availability を上げるための道具ですが、何でも retry してよいわけではありません。分類の基本は次の通りです。

- 同じ request を再送しても安全な call
  読み取り、自然に冪等な更新、idempotency key つきの create
- retry する前に影響範囲を考える call
  inventory reservation、payment authorization のように外部 state を変える call
- 原則として自動 retry を避ける call
  明示的な side effect が大きく、重複時の影響が高い call

ここでよくある失敗は、「timeout したから未実行だろう」と思い込むことです。実際には callee が成功し、response だけが失われた可能性があります。したがって timeout 後 retry を許すなら、callee 側で idempotency を受け止める設計が必要です。

=== idempotency key は誰のためにあるのか

idempotency key は transport の都合ではなく、業務の正しさのためにあります。checkout 画面で user が二度押しした、mobile app が切断後に再送した、API gateway が upstream timeout を見て再試行した、といったときに、`Payment Service` が毎回新しいオーソリを切ってしまうと被害が大きいからです。

典型的には、`Order Service` が注文 request ごとに stable な idempotency key を持ち、それを `Payment Service` へ渡します。`Payment Service` はその key を見て、同じ key の過去結果を返すか、新規処理を 1 回だけ実行します。

```go
type AuthorizeRequest struct {
    OrderID        string
    Amount         int64
    CustomerID     string
    IdempotencyKey string
}

func (s *PaymentService) Authorize(ctx context.Context, req AuthorizeRequest) (Authorization, error) {
    if prev, ok := s.store.LookupByIdempotencyKey(req.IdempotencyKey); ok {
        return prev, nil
    }
    auth, err := s.gateway.Authorize(ctx, req)
    if err != nil {
        return Authorization{}, err
    }
    s.store.Save(req.IdempotencyKey, auth)
    return auth, nil
}
```

ここで重要なのは、`IdempotencyKey` が request の identity を表し、`OrderID` とは別の責務を持っていることです。Order 自体はまだ作れていなくても、支払い試行の重複吸収には stable な key が必要になります。

== user-facing state は 3 種類に寄せる

注文 API の response を設計するとき、user-facing state を増やしすぎると product と client 実装が苦しくなります。同期 path の初期段階では、次の 3 種類に寄せると整理しやすいです。

- `accepted`
  注文は成立した
- `rejected`
  在庫切れや支払い拒否など、業務的に成立しない
- `temporary_failure`
  技術的理由でいまは確定できない

もちろん内部ではもっと多くの error taxonomy を持ってよいですが、user-facing にはこの 3 つ程度に畳むと説明しやすくなります。大切なのは、`temporary_failure` を `unknown` に近い状態として扱い、安易に再送だけを促さないことです。

=== user に見せる失敗を設計する

同期 API では、技術的な失敗をそのまま user-facing error にしてはいけません。たとえば `Inventory Service` の `DEADLINE_EXCEEDED` は、user から見れば「いま在庫がない」ではなく、「一時的に注文処理に失敗した」に近いはずです。逆に `OUT_OF_STOCK` は明確な業務失敗なので、ただの `500` として返すべきではありません。

設計上のコツは、technical error と business error を分けることです。

- business error
  在庫切れ、支払い拒否、入力不正
- transient technical error
  timeout、一時的な network failure、rate limit
- persistent technical error
  schema 不整合、プログラムバグ、誤設定

この区別を API 設計に入れておくと、retry policy と user メッセージを分けやすくなります。読者が実務で迷いやすいのは、ここを全部 `INTERNAL` や `500` にしてしまうことです。

#editorial_note[
  分散システムでは、`error code` は transport detail であると同時に設計文書でもあります。retry 可否や user-facing state を左右するので、status 設計を「あとで決める」にしてはいけません。
]

== 支払いと在庫の順序をどうするか

注文作成の同期パスでは、`在庫確保を先にするか` と `支払いオーソリを先にするか` で議論が分かれます。どちらが絶対に正しいわけではありませんが、違いはあります。

- 在庫先行
  品切れ時に無駄な payment call を減らせる
- 支払い先行
  支払い拒否が多い業務なら inventory load を減らせる

どちらを選んでも、片方成功後にもう片方が失敗する可能性は残ります。したがって重要なのは「順序」そのものより、「失敗したときにどう解放・取消するか」を決めることです。同期 request の設計は、成功パスより失敗パスのほうが難しいのです。

```text
Ordering comparison

Inventory first
  + 品切れ時に payment 呼び出しを避けやすい
  - payment timeout 時に reservation 解放が必要

Payment first
  + 支払い拒否が多い業務では inventory load を減らせる
  - inventory 失敗時に payment 取消が必要
```

継続例では inventory first を基本線にします。理由は `在庫がない注文に支払いオーソリを掛けない` ほうが product 的に自然だからです。ただし業務によっては逆もあり得るので、ここは本質的に business choice です。

== response を返したあとに何が残るか

`SubmitOrder` が成功 response を返した時点でも、system 全体ではまだやるべきことが残っています。メール送信、analytics、検索更新、fraud scoring などです。ここで誤解してはいけないのは、`response を返した` と `全ての副作用が終わった` は別だということです。

逆に言うと、同期 path では「どこまで終わっていれば user に返してよいか」を厳密に決める必要があります。本書の継続例では、少なくとも次を同期で保証したことにします。

- 注文 row は永続化された
- 在庫確保または在庫切れ判定が済んだ
- 支払いオーソリまたは支払い拒否判定が済んだ
- 後続 event の発行要求は outbox に記録された

この最後の項目が重要です。`Kafka` に publish し終わっている必要まではありませんが、少なくとも「publish すべき事実」は失われない形で記録しておく必要があります。

=== API 名と状態名をずらさない

同期 API を設計するとき、request 名と業務状態名がずれていると混乱しやすくなります。たとえば API 名は `CreateOrder` なのに、実際の意味は `AcceptOrderRequest` に近い、ということがあります。これは product と backend の会話を崩します。

継続例では、次のような naming が自然です。

- `SubmitOrder`
  user からの注文要求を受ける API
- `OrderAccepted`
  同期 path が成功し、注文番号が確定した状態
- `OrderCreated`
  `Kafka` に流す事実としての event 名

この 3 つは似ていますが同じではありません。`SubmitOrder` は request、`OrderAccepted` は synchronous response の意味、`OrderCreated` は後続 consumer が読む log 上の事実です。名前を揃えることは、状態境界を揃えることでもあります。

=== read-your-own-writes をどこまで求めるか

注文作成 API のあとに user がすぐ注文一覧画面を開くとします。このとき user は「さっきの注文が見えるはずだ」と期待します。これは read-your-own-writes の要件です。

同期 path で orders table への書き込みが終わっていれば、少なくとも Order Service の read model では見えるようにできます。しかし検索 index や analytics dashboard まで即時に見える必要があるかは別問題です。ここを分けて説明できないと、全 projection を同期化したくなってしまいます。

継続例なら、次の整理が自然です。

- 注文詳細画面
  同期 DB 書き込みに基づくので、すぐ見えるべき
- 検索結果
  数秒遅れても許容できるなら非同期 index 更新でよい
- 管理画面の売上集計
  数分遅れでもよいなら analytics consumer でよい

つまり read-your-own-writes もスコープを切る必要があります。

=== failure mapping の小さな表

設計時に便利なのは、「どの失敗を user にどう見せるか」を表にしてしまうことです。文章だけで持つと、後から retry policy と食い違いやすくなります。

```text
Inventory: OUT_OF_STOCK
  -> user-facing: 在庫切れ
  -> retry: no

Inventory: DEADLINE_EXCEEDED
  -> user-facing: 一時的に処理できません
  -> retry: caller may retry once

Payment: CARD_DECLINED
  -> user-facing: 支払い方法を確認してください
  -> retry: no automatic retry

Payment: UNAVAILABLE
  -> user-facing: 一時的に処理できません
  -> retry: only with idempotency key
```

このレベルの表があるだけで、実装時に `全部 INTERNAL` に倒す事故が減ります。

=== caller cancellation を無視しない

mobile app や browser では、user が画面を閉じたり、通信が切断されたりすることがあります。すると upstream は request を諦めます。ここで downstream がその事実を知らず、inventory や payment を延々と続けると、user が既に離脱した request のために資源を使い続けることになります。

したがって同期 path では、caller cancellation を子 call へ伝播させることが重要です。Go の `context` はそのための道具ですし、他言語でも cancellation token や deadline propagation の仕組みがあります。

ただし cancellation を伝えれば全て安全になるわけではありません。`Payment Service` が既に外部 gateway へ request を投げているなら、途中で caller が諦めても処理は止まらないかもしれません。この場合も、あとで問い合わせ・取消・重複吸収が必要です。だから cancellation は「節約」の仕組みであり、「実行されなかった保証」ではありません。

=== 小さな通しシナリオ: 二重押しからの回復

最後に、実務でかなり多い `二重押し` を短く通しておきます。

```text
T0 user clicks "Place order"
T1 client sends SubmitOrder(client_request_id=R1)
T2 payment is slow, page spinner continues
T3 user clicks again or app retries
T4 client sends SubmitOrder(client_request_id=R1) again
T5 Order Service recognizes same request identity
T6 returns prior accepted result or current processing status
```

この流れで守りたいのは、`同じ意図を複数回実行しない` ことです。request identity、payment idempotency、status inquiry が揃っていると、user の再送を事故ではなく通常系として扱えます。同期設計の成熟度は、このような地味なケースにどれだけ耐えられるかで分かります。

=== critical path から外す基準

設計レビューで迷いやすいのは、「この処理は同期 path に残すべきか」です。継続例なら次の基準が使えます。

- 注文確定の意味を作る処理
  同期に残す
- user-facing response に即座に影響しない副作用
  非同期へ逃がす
- 再実行や replay が自然な処理
  非同期へ逃がしやすい
- その場で user に見せる必要がある validation
  同期に残す

これを箇条書きの感覚で終わらせず、実際の処理を棚卸しするのが重要です。たとえば fraud scoring は business によって分かれます。注文を即確定したいなら非同期 review が自然ですし、高リスク商材なら同期 path に残すかもしれません。

== 章末まとめ

この章の本質は、request/response を `関数呼び出しの分散版` として見るのをやめることです。同期通信は、critical path と response meaning を定義するための契約です。その契約を支えるのが timeout budget、failure mapping、idempotency、cancellation propagation です。

注文システムで見れば、`SubmitOrder` が成功した瞬間に何を保証するかを決めることが、後続の `Kafka` 設計や consumer 設計の前提になります。ここが曖昧だと、後ろの章をどれだけ丁寧に書いても全体がぶれます。

=== この章の設計判断の要点

同期通信の設計で最初に見るべきなのは、HTTP method や `proto` の形ではありません。critical path、response の意味、timeout budget、failure contract です。これが決まっていれば、実装技術が `gRPC` でも HTTP/JSON でも本質はあまり変わりません。

言い換えると、request/response は「相手を呼ぶ技術」ではなく、「いま結果が必要な仕事を扱う契約」です。だからこそ retry、idempotency、error mapping を最初から同時に考える必要があります。

#caution[
  `同期通信だから簡単` という感覚は危険です。実務で壊れやすいのは、たいてい成功パスではなく、timeout、再送、部分失敗、重複実行が絡む場面です。
]

=== 演習

1. あなたの system で、user-facing critical path に入っている処理を 5 つ挙げ、それぞれを「本当に今すぐ必要か」で見直してください。
2. `SubmitOrder` API が `accepted` を返した時点で、何を保証し、何はまだ保証していないかを 3 行で定義してください。
3. inventory timeout 時に caller が自動 retry してよい条件を整理してください。
4. payment authorization に idempotency key がない場合、どの failure で二重課金が起き得るかを書き出してください。
5. 画面リロードや mobile app 再送を前提にしたとき、stable request identity をどこで生成すべきかを設計してください。
6. あなたの system で、同期 path に残っているが実は非同期へ逃がせそうな処理を 3 つ挙げてください。

=== この章の出口

request/response を critical path と user-facing state の契約として読めるようになると、次に必要なのは「その契約を本番でどう維持するか」です。次章では load balancing、connection 管理、streaming、observability を加えて、同期通信を運用対象として見ます。
