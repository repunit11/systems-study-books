#import "../theme.typ": checkpoint, caution, editorial_note, terminal

= nonblocking I/O と readiness

blocking socket は分かりやすい反面、1 本の実行線を簡単に止めてしまいます。少数 connection ならそれでも動きますが、大量 connection を 1 thread で扱いたくなると、blocking の素朴さが重荷になります。この章では、その重荷を外すために nonblocking I/O と readiness の意味を整理します。

#checkpoint[
  この章では次を押さえます。

  - `O_NONBLOCK` を付けると何が変わるか
  - `EAGAIN` / `EWOULDBLOCK` をどう読むか
  - partial read / partial write がなぜ普通に起きるか
  - `readable` / `writable` が何を保証し、何を保証しないか
  - backpressure と timeout をどう考えるか
]

== なぜ nonblocking が必要か

1 本の thread で大量の socket を扱いたいとき、最も困るのは「どの socket が先に進むかを自分で選べない」ことです。blocking `read` を 1 本呼ぶと、その socket に data が来るまで thread 全体が止まります。他の socket が ready でも、その thread は見に行けません。

ここで欲しいのは、「今すぐ進める socket だけを少しずつ進めたい」という制御です。そのための前提が nonblocking I/O です。socket を nonblocking にすると、`read` や `write` は「待てないなら今は返る」ようになります。thread を眠らせる代わりに、caller へ「今は無理」という結果を返して制御を戻すわけです。

== `O_NONBLOCK`

Linux では `fcntl` で `O_NONBLOCK` を付けるのが典型です。

```c
int flags = fcntl(fd, F_GETFL, 0);
fcntl(fd, F_SETFL, flags | O_NONBLOCK);
```

これ以後、その fd に対する `read`、`write`、`accept`、`connect` などは、待てないときに sleep しません。代わりに `-1` を返し、`errno` に `EAGAIN` あるいは `EWOULDBLOCK` を入れます。実装上は両者を同じ意味で扱うことが多いです。

ここで重要なのは、`EAGAIN` を「壊れた error」だと思わないことです。これは多くの場合、「今は条件が足りないので、待てる仕組みに戻してほしい」という合図です。つまり nonblocking I/O の世界では、`EAGAIN` は失敗というより制御フローの一部です。

#editorial_note[
  blocking I/O では kernel が caller の代わりに wait してくれます。nonblocking I/O ではその wait を user space へ戻します。どちらが偉いという話ではなく、「どこで待ち合わせを組み立てるか」が違うだけです。
]

== `read` が返す「今は無理」

nonblocking socket で `read` すると、少なくとも次の 4 通りを意識します。

- `n > 0`
  読めた data がある
- `n == 0`
  peer が close し、EOF が見えた
- `n == -1 && errno == EAGAIN`
  今は読める data がない
- `n == -1 && errno` がそれ以外
  実際の error

blocking I/O と違い、`EAGAIN` が普通に出てきます。ここで「何度も `read` を呼び続ける」のは良くありません。data が来るまで busy loop してしまうからです。正しい流れは、「今は無理」と分かったら poller へ登録し、readable になるまで別の仕事をする、です。

== `write` と partial write

`write` でも同じことが起きます。nonblocking socket に大量の data を書こうとしても、送信 buffer に空きがなければ全部は入りません。すると `write` は短く返るか、あるいは `EAGAIN` を返します。したがって nonblocking の送信処理は「1 回 `write` して終わり」ではなく、送れた分だけ進め、残りを保持し、writable 通知で再開する構造になります。

典型的には次のような loop です。

```c
while (off < len) {
    ssize_t n = write(fd, buf + off, len - off);
    if (n > 0) {
        off += (size_t)n;
        continue;
    }
    if (n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        remember_unsent_bytes(fd, buf + off, len - off);
        arm_writable_interest(fd);
        break;
    }
    handle_fatal_write_error(fd);
    break;
}
```

この pattern が必要なのは、TCP が byte stream であり、kernel が「どこまで送れたか」しか保証しないからです。message 境界は application 側で管理する必要があります。

== `readable` と `writable` の意味

ここで readiness という言葉を導入します。`readable` は「今 `read` を試せば、少なくとも 1 回は block せずに進めそう」という意味です。`writable` は「今 `write` を試せば、少なくとも少しは block せずに進めそう」という意味です。

この定義には含意があります。

- `readable` は「1 message 全体が揃った」を保証しない
- `writable` は「送りたい data を全部出せる」を保証しない
- readiness は completion ではなく、try する権利に近い

この感覚が非常に重要です。たとえば HTTP request 全体を 1 回の `read` で取り切れるとは限りません。逆に `readable` なのに `read` してみたら EOF だった、ということもあります。kernel が知らせているのは、socket buffer の状態変化です。

== receive buffer / send buffer と backpressure

socket には送受信 buffer があります。受信側では、network から届いた data が一時的に receive buffer へ入り、user space の `read` で取り出されます。送信側では、user space が `write` した data が send buffer へ入り、network へ送り出されます。

ここで backpressure という現象が起きます。相手がゆっくり読むと、こちらの send buffer はなかなか空きません。すると `write` は進みにくくなります。逆にこちらが読まないと receive buffer が詰まり、相手側の送信も進みにくくなります。つまり network I/O では、読む速さと書く速さが連鎖します。

backpressure を理解すると、「なぜ writable notification が必要なのか」「なぜ送信 queue を user space に持つ必要があるのか」が見えてきます。server は単に socket が readable かどうかだけでなく、未送信 data の有無も管理しなければいけません。

== timeout をどう考えるか

blocking I/O では、単純に長く待つ code を書きやすいです。しかし nonblocking I/O では、待ちそのものを user space が組み立てます。したがって timeout も user space 側の責務へ寄ってきます。

最も単純なのは poll 系 API の timeout を使うことです。`poll` や `epoll_wait` は待ち時間を指定できます。ただし本当に欲しいのは、API 呼び出し 1 回の timeout ではなく、「この connection は 30 秒 idle なら切る」「この request は 5 秒以内に header を読みたい」といった higher-level な timeout です。したがって event loop を書くときは、fd readiness と timer を一緒に管理することが多くなります。

== nonblocking は busy loop のことではない

ここで誤解しやすい点を強調します。nonblocking にしたからといって、「ひたすら `read` を叩き続ける」のは正しくありません。それでは CPU を無駄に回すだけです。nonblocking I/O の本質は、「待ちを kernel から user space に戻し、その待ちをまとめて管理する」ことです。実際に待つ場所は消えません。ただ位置が変わるだけです。

したがって典型的な流れは次です。

1. socket を nonblocking にする
2. `read` / `write` / `accept` を試す
3. `EAGAIN` なら poller へ関心を登録する
4. readiness 通知が来たら再開する

この流れが、そのまま `select` / `poll` / `epoll` の世界へ続きます。

#caution[
  `readable` や `writable` は level で変化します。通知を 1 回受け取ったからといって、後続の `read` / `write` が何度でも成功するわけではありません。1 回進んだあとすぐ `EAGAIN` へ戻ることも普通にあります。
]

== Go から見ると何が起きているか

Go の `net.Conn` は user code からは blocking API に見えます。`Read` を呼べば data が来るまで待ってくれますし、`Write` も普通の関数のように見えます。しかし Go runtime は多数 connection を少数 thread で扱うため、内部では nonblocking socket と poller を使います。

つまり Go は、「nonblocking と poller の面倒を runtime が肩代わりし、その上へ goroutine ごとの blocking 風 API を載せる」設計です。この構造を知っておくと、goroutine ごとの code が簡単に見える理由が分かります。下の層で readiness をまとめて待っているからこそ、上の層では connection ごとに素直な code が書けます。

== この章で作りたい感覚

この章の到達点は、次の 3 つの感覚です。

- `EAGAIN` は制御フローの一部である
- readiness は completion ではなく、「今なら少し進める」の通知である
- nonblocking I/O は busy loop ではなく、poller と組み合わせて初めて意味を持つ

次章では、その poller を具体的に見ます。`select` は何がつらいのか。`poll` は何を改善するのか。`epoll` は何を一度登録し、何を返してくるのか。event loop の最小形と一緒に整理します。
