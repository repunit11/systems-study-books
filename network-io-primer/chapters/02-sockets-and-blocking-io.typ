#import "../theme.typ": checkpoint, caution, editorial_note, terminal

= `socket` と blocking I/O

この章では、まず network I/O を最も素朴な形で見ます。1 本の listening socket を作り、client が来るまで `accept` で待ち、接続後は `read` / `write` でやり取りする、という基本形です。最初から nonblocking や `epoll` を出さない理由は、何が block するのかを自分の目で確認したほうが、後の抽象化がずっと楽になるからです。

#checkpoint[
  この章では次を押さえます。

  - socket が file descriptor として見えること
  - listening socket と connected socket の役割の違い
  - blocking `accept` / `read` / `write` が何を待っているか
  - 1 client ずつ処理する server の限界
]

== `socket` は何者か

user space から見ると、socket は file descriptor を返す特別な open 操作です。`open` の代わりに `socket(domain, type, protocol)` を呼び、その返り値として整数 fd を受け取ります。以後、その fd に対して `read`、`write`、`close`、`fcntl`、`poll` などを使えます。つまり、program の入口では「I/O 対象が file か socket か」はかなり統一された形に見えます。

もちろん内部実装は違います。通常のファイルなら page cache や inode が中心ですし、socket なら protocol の状態、送受信 buffer、接続待ち queue が中心です。ただ、fd という共通のハンドルを介して見えるため、kernel は「待てるもの」「読めるもの」「書けるもの」をある程度統一的に扱えます。後で `select` や `epoll` が socket だけでなく pipe や eventfd と一緒に扱えるのも、この統一のおかげです。

== listening socket と connected socket

TCP server を考えると、最初に作るのは listening socket です。これは「接続要求を受け取る入口」であり、data 本体をやり取りする socket ではありません。典型的には次の順で準備します。

1. `socket(AF_INET, SOCK_STREAM, 0)` で TCP socket を作る
2. `bind` で local address と port を結び付ける
3. `listen` で passive open の状態へ入る
4. `accept` で新しい接続を取り出す

ここで重要なのは、`accept` が返す fd は listening socket とは別物だということです。listening socket は引き続き新しい接続要求を受けるために残り、実際の送受信は `accept` が返した connected socket で行います。この二段構えを最初に理解しておくと、server の構造がかなり見やすくなります。

== 最小の blocking echo server

まずは C で最小の blocking TCP echo server を見ます。実際の production code なら error handling、`setsockopt(SO_REUSEADDR)`、signal 対応などが必要ですが、ここでは主線だけに絞ります。

```c
int lfd = socket(AF_INET, SOCK_STREAM, 0);

struct sockaddr_in addr = {
    .sin_family = AF_INET,
    .sin_port = htons(8080),
    .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
};

bind(lfd, (struct sockaddr *)&addr, sizeof(addr));
listen(lfd, 128);

for (;;) {
    int cfd = accept(lfd, NULL, NULL);
    char buf[4096];
    ssize_t n = read(cfd, buf, sizeof(buf));
    if (n > 0) {
        write(cfd, buf, (size_t)n);
    }
    close(cfd);
}
```

この code はかなり単純ですが、network I/O の骨格が全部入っています。`accept` は新しい client が来るまで待ちます。接続が成立すると connected socket `cfd` が返り、その socket から `read` で data を受け、`write` で返します。client が何も送ってこなければ `read` は待ちます。つまり、block する地点が 2 箇所あります。

- 接続待ちの `accept`
- data 待ちの `read`

`write` も状況によっては block します。相手の受信側が遅かったり、送信 buffer に空きがなかったりすると、今すぐ全部は書けません。blocking socket では、その空きが出るまで caller を眠らせることがあります。

#editorial_note[
  「blocking」と聞くと CPU が忙しく回り続ける印象を持つことがありますが、普通は逆です。kernel はその thread を wait queue へ置き、条件が満たされるまで sleep させます。busy loop と blocking wait は全く別物です。
]

== 何が block しているのか

`accept` が block しているとき、server は「新しい接続を受け取れる状態になるまで待っている」と言えます。TCP の細部まで踏み込まなくても、少なくとも user space からは「いまは取り出すべき新規接続がない」状態として見えます。新しい接続が queue へ入り、`accept` 可能になると kernel は sleeping thread を起こし、`accept` が connected socket を返します。

`read` が block しているときは、「その socket の受信 buffer に返せる data がまだない」という理解で十分です。相手が 1 byte 送ってきただけでも `read` は返るかもしれませんし、相手が close したなら 0 を返します。つまり `read` は「完全な application message」を待っているのではなく、「今返せる kernel buffer の状態変化」を待っています。

`write` も同様です。相手がまだ読んでいないため送信 buffer が詰まっているなら、今すぐには進めません。blocking socket では、その空きが出るまで caller が眠ります。ここに network I/O の相手都合が見えます。file への `write` よりも、「向こうの速度」が前面に出てくるわけです。

== `read` の戻り値の見方

socket の `read` は少なくとも次の 3 パターンで見ます。

- `n > 0`
  data が `n` byte 読めた
- `n == 0`
  peer が orderly shutdown し、EOF が見えた
- `n == -1`
  error。blocking socket なら通常は即時 error、nonblocking なら後で見る `EAGAIN` もここに入る

ここで重要なのは、`n > 0` が「要求した長さを全部読めた」を意味しないことです。たとえば 4096 byte 読みたくても、今 buffer に 100 byte しかなければ 100 だけ返ることがあります。TCP は byte stream なので、message 境界を守ってくれません。application protocol 側で長さや区切りを決める必要があります。

== client 側はどう見えるか

client は `connect` を使います。最小形は次のようなものです。

```c
int fd = socket(AF_INET, SOCK_STREAM, 0);
connect(fd, (struct sockaddr *)&addr, sizeof(addr));
write(fd, "hello\n", 6);
read(fd, buf, sizeof(buf));
close(fd);
```

blocking `connect` も待つ可能性があります。相手に届くまで、あるいは失敗が確定するまで caller は返ってきません。つまり TCP client でも、接続確立の時点からすでに「相手都合の待ち合わせ」が始まっています。

== shell から動かしてみる最小例

動作確認の雰囲気だけなら、`nc` と組み合わせると掴みやすいです。

```text
$ gcc -O2 server.c -o server
$ ./server

別 terminal:
$ nc 127.0.0.1 8080
hello
hello
```

この段階では、1 client がつながって何も送らないだけで server 側の `read` は止まります。code が 1 本の実行線しか持っていないため、別の client を同時に扱えません。ここが blocking server の最初の限界です。

== Go で見ると何が同じか

Go で同じことを書くと、見た目は少し変わります。

```go
ln, _ := net.Listen("tcp", "127.0.0.1:8080")
for {
    conn, _ := ln.Accept()
    go func(c net.Conn) {
        defer c.Close()
        io.Copy(c, c)
    }(conn)
}
```

この code は goroutine を使っているので C の最小例より柔らかく見えます。しかし骨格は同じです。`Listen` は listening socket を作り、`Accept` は新しい connected socket を受け取り、`Read` / `Write` 相当を通じて data をやり取りします。違うのは、「複数 connection をどう同時にさばくか」の部分を runtime がかなり肩代わりしてくれることです。

本章の段階では、Go の見た目に引っ張られ過ぎないことが大切です。下にある kernel 側の待ち合わせは消えていません。user code が blocking API に見えていても、その裏では nonblocking 化や poller 連携が使われます。この話は後半で戻ります。

== 1 client ずつ処理する構造の限界

最初の C echo server は、理解の入口としては優れていますが、server としてはすぐ限界にぶつかります。1 client が接続したまま黙っていると、その `read` が返るまで次の接続処理へ進めません。1 thread あたり 1 本の blocking 実行線しか持っていないからです。

もちろん対処法はあります。connection ごとに thread や process を作る、あるいは先に socket を nonblocking にし、複数 fd をまとめて待つ、といった方向です。前者は分かりやすいですが、connection 数が増えると thread 数や memory 使用量が重くなります。後者が `select` / `poll` / `epoll` へつながる道です。

#caution[
  `accept` が 1 回返ったからといって、その connection で大量の data をすぐ読めるとは限りません。また `write` が 1 回成功したからといって、application が送りたい全 message を出し切れたとは限りません。network I/O は「少し進む」を積み重ねる世界です。
]

== この章で作りたい感覚

この章で大事なのは、socket の全 API を暗記することではありません。むしろ次の感覚を持つことです。

- listening socket と connected socket は別の役割を持つ
- blocking call は「条件が整うまで sleep する」
- network I/O は相手都合で止まりやすい
- `read` / `write` の 1 回の成功は、完全な application-level 進捗を保証しない

この感覚があれば、次章の nonblocking I/O と readiness はかなり自然に見えます。`block しない` とは何か。`今は無理` をどう受け取るのか。`readable` / `writable` は何を知らせるのか。そこを次に整理します。
