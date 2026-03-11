#import "../theme.typ": checkpoint, caution, editorial_note, terminal

= kernel 側の待ち合わせと runtime への橋

ここまでで user space の API はだいぶ見えました。この章では少し視点を下げ、`listen` backlog、socket buffer、sleep/wakeup、TCP/UDP の違いを最小限だけ押さえたうえで、Go runtime の `netpoll` へ戻ります。狙いは kernel source の完全読解ではありません。user space の `read` / `write` / `epoll_wait` が、kernel 側のどの状態変化と対応しているかを結び付けることです。

#checkpoint[
  この章では次を押さえます。

  - `listen` backlog をどう理解するとよいか
  - send buffer / receive buffer と backpressure のつながり
  - loopback と TCP/UDP の違いを最小限どう捉えるか
  - readiness 通知が goroutine の park/unpark とどうつながるか
]

== `listen` backlog の最小像

`listen(fd, backlog)` を呼ぶと、server socket は passive open の状態へ入り、新しい接続を受ける入口になります。学習の最初の理解としては、「`accept` 待ちの接続をためる queue の大きさに関わる」と捉えるのがよいです。つまり application が `accept` で取り出すより速く接続要求が来ると、その queue に積まれ、あふれると失敗や再試行が起こり得ます。

実際の Linux TCP stack はもう少し複雑です。handshake の途中段階と、`accept` 可能になった接続の扱いは分かれており、sysctl tuning も関わります。しかし user space の server 設計として最初に大事なのは、「`accept` を遅らせると queue が詰まる」「backlog は無限ではない」という感覚です。

つまり `accept` loop の設計は単なる書き方の違いではありません。遅い `accept` は新規接続の入口そのものに影響します。event loop で listening socket を優先的にさばく理由の 1 つはここにあります。

== socket buffer と data の流れ

connected TCP socket には送受信 buffer があります。大まかには次のように見れば十分です。

1. 相手から届いた byte 列は receive buffer へ入る
2. user space の `read` が receive buffer から取り出す
3. user space の `write` は send buffer へ byte 列を積む
4. kernel が send buffer から network へ送り出す

このモデルを持つと、`readable` / `writable` の意味が分かりやすくなります。receive buffer に data があれば readable です。send buffer に空きがあれば writable です。逆に receive buffer が空なら `read` は進まず、send buffer が詰まっていれば `write` は進みにくくなります。

== backpressure はどこから来るか

backpressure は、要するに「下流が遅いので上流も進みにくくなる」現象です。network I/O では、peer が読まない、回線が遅い、receiver 側 application が詰まる、といった理由で発生します。user space から見ると、その結果は short write や `EAGAIN` として現れます。

このとき重要なのは、`write` が詰まった理由を「kernel が意地悪している」ように見ないことです。実際には、相手がまだ受け取れていないから先へ進めないだけです。network I/O は local な function call に見えても、本質的には遠隔の相手との同期です。backpressure を理解すると、送信 queue と timeout の必要性が腹落ちしやすくなります。

== loopback は特別か

手元の学習では `127.0.0.1` や `::1` をよく使います。loopback は NIC を経由しないので、外の network よりずっと単純で速いです。ただし socket としての意味が変わるわけではありません。listening socket を作り、connect し、send/receive buffer を使い、`epoll` で readiness を待つ、という大きな構造は同じです。

したがって学習初期には loopback で十分です。packet loss や MTU や実 NIC の細部を無視しやすく、I/O 待ちの骨格だけに集中できます。本書もその前提で話を進めます。

== TCP と UDP の違いを最小限だけ

本書の主線は TCP ですが、UDP との違いを最小限だけ押さえておくと整理しやすいです。

- TCP
  connection 指向。順序があり、byte stream として見える。message 境界は保持しない
- UDP
  connectionless。datagram 単位で見え、message 境界が残る。到達保証や順序保証はない

ただし readiness という観点では共通点もあります。どちらも「今なら `recv` 系が進みそう」「今なら `send` 系が進みそう」を待ちます。違うのは data の見え方です。TCP は stream なので parser が境界を復元しなければいけません。UDP は 1 datagram が 1 単位として見えます。

== data 到着から wakeup までの最小像

細部をかなり省略して、data 到着から user space 再開までを最小限の段階で書くと次のようになります。

1. peer から packet が届く
2. kernel network stack がそれを該当 socket へ結び付ける
3. socket receive buffer に読める data が載る
4. その socket を待っている thread や poller が wakeup 対象になる
5. `epoll_wait` あるいは blocked な読み手が再開する
6. user space が `read` して data を取り出す

この流れで大事なのは、wake up の基準が「application message 完成」ではなく、socket の状態変化だということです。たとえば 1 byte だけ届いても wakeup され得ます。逆に protocol 的には 1 request ぶん揃っていても、user space が parser を回さない限りそれは単なる byte 列です。

#editorial_note[
  readiness と protocol completion を分けて考える癖はとても重要です。kernel が知っているのは通常、socket buffer と error/EOF の状態までです。HTTP request が完成したか、独自 protocol の frame が揃ったかは、多くの場合 user space parser の責務です。
]

== sleep/wakeup と scheduler

`syscalls-process-primer` で見た sleep/wakeup の感覚は、ここでもそのまま使えます。blocking `read` は「この socket が readable になるまで寝る」ですし、`epoll_wait` は「登録した fd のどれかに興味ある event が起きるまで寝る」です。違うのは待ち対象の粒度だけです。

この観点で見ると、event loop も結局は scheduler の 1 種に見えます。ready になった fd を取り出し、どの connection state をどこまで進めるかを決めるからです。thread scheduler が runnable thread を選ぶのに対し、event loop は ready fd とその state を選びます。Go runtime の `netpoll` を理解しやすくする鍵もここにあります。

== Go runtime の `netpoll`

Go では `net.Conn.Read` や `net.Conn.Write` が blocking API のように見えます。しかし runtime は多数 goroutine を少数 thread で回したいので、内部では nonblocking fd と poller を使います。Linux ではその backend の中心が `epoll` です。

概念的には、次のような流れだと考えると分かりやすいです。

1. network fd は nonblocking として扱われる
2. goroutine が `Read` / `Write` を試す
3. すぐ進めないなら runtime はその goroutine を park する
4. runtime の poller は fd readiness を待つ
5. ready になったら対応する goroutine を runnable に戻す
6. その goroutine が再び CPU を得て処理を続ける

ここで重要なのは、「goroutine が待っている」と「OS thread がそのまま塞がっている」を分けることです。runtime は goroutine を park/unpark するので、I/O 待ちの間も他の goroutine を進められます。これが goroutine-per-connection が比較的自然に書ける理由です。

== C の event loop と Go の goroutine-per-connection

C で `epoll` を直接使うと、application 自身が fd ごとの state machine をはっきり書くことになります。どの fd が readable か、どこまで parse したか、未送信 data がどれだけ残っているかを明示的に管理します。

Go では見た目がかなり違います。connection ごとに goroutine を作り、`Read` が返るまでその goroutine の実行を止めればよいので、application code は直線的です。ただし state machine が消えたわけではありません。待ち合わせの一部を runtime が肩代わりし、goroutine scheduler と `netpoll` の協調で隠れているだけです。

この比較を持っておくと、Go の code が「簡単だから kernel の都合を無視できる」のではなく、「kernel の readiness を runtime が受け止める設計になっている」から簡単に見えるのだと分かります。

== Go の最小 echo server をもう一度見る

たとえば次のような Go code はとても素直です。

```go
ln, err := net.Listen("tcp", ":8080")
if err != nil {
    log.Fatal(err)
}
for {
    conn, err := ln.Accept()
    if err != nil {
        continue
    }
    go func(c net.Conn) {
        defer c.Close()
        buf := make([]byte, 4096)
        for {
            n, err := c.Read(buf)
            if n > 0 {
                if _, werr := c.Write(buf[:n]); werr != nil {
                    return
                }
            }
            if err != nil {
                return
            }
        }
    }(conn)
}
```

application 側は connection ごとに素直な loop を書けます。しかし runtime の下では、I/O 待ちの goroutine を park し、fd readiness で再開させる仕組みが動いています。つまり user code の見た目は thread-per-connection に近いのに、実際の待ち合わせは readiness-based multiplexing に支えられているわけです。

== readiness ベースの待ち合わせの限界と次の話題

ここまでのモデルは非常に強力ですが、万能ではありません。大量の状態管理、送信 queue、timer 管理、protocol parser、fairness といった問題は依然として残ります。また Linux には completion-based の色が強い `io_uring` もあります。ただし、それらへ進む前に readiness ベースの待ち合わせをしっかり理解しておく価値は大きいです。

なぜなら、`epoll` と `netpoll` の世界を理解しておくと、「completion とは何が違うのか」を比較できるからです。基準点がないまま新しい API を見るより、既存の待ち合わせモデルを一度手に入れたほうが学習しやすいです。

#caution[
  Go の network I/O を「goroutine だから thread を使わない」と表現するのは正確ではありません。実際には OS thread も poller thread も使います。重要なのは、goroutine の待ちと thread の占有を runtime がうまく分離していることです。
]

== この章で作りたい感覚

この章の到達点は次です。

- backlog は接続待ちの入口に関わる
- send/receive buffer は readable / writable と backpressure の基礎である
- wakeup は socket 状態変化に基づく
- Go の `netpoll` は kernel readiness と goroutine scheduler の橋である

ここまで来ると、`syscalls-process-primer` の sleep/wakeup と `go-runtime-primer` の `netpoll` がかなり近い話に見えてきます。最後の章では、復習、観測コマンド、よくあるつまずき、演習、次に読む source をまとめます。
