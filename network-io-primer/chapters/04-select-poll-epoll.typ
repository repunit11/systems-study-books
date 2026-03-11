#import "../theme.typ": checkpoint, caution, editorial_note, terminal

= `select` / `poll` / `epoll`

nonblocking I/O を導入すると、次に必要になるのは「複数 fd の readiness をまとめて待つ仕組み」です。1 本の socket に対して `EAGAIN` を見ただけでは進みません。どの fd がいつ readable / writable になったかを、1 箇所で待って dispatch する必要があります。この章では、そのための代表的な API である `select`、`poll`、`epoll` を整理します。

#checkpoint[
  この章では次を押さえます。

  - `select`、`poll`、`epoll` の基本的な違い
  - `epoll` が interest list と ready list をどう扱うか
  - level-triggered と edge-triggered の考え方
  - event loop が「状態機械」になる理由
]

== 1 本ずつ見るのではなく、まとめて待つ

nonblocking socket を 1000 本持っているとします。各 socket に対して毎回 `read` を試し、`EAGAIN` なら次へ進む、を愚直に回すだけでは、ほとんどの時間を空振りに使ってしまいます。欲しいのは、「変化があった fd だけ教えてほしい」という仕組みです。

その発想が multiplexing API です。user space は「この fd が readable になるのを待ちたい」「この fd が writable になるのを待ちたい」と登録し、kernel は ready になった fd をまとめて返します。これにより 1 thread でも多くの connection を扱えるようになります。

== `select`

`select` は古典的な API です。`fd_set` に監視したい fd を詰め、read / write / exception ごとに集合を渡し、ready になったものだけが返ります。概念は分かりやすいですが、次の弱点があります。

- `fd_set` を毎回作り直す必要がある
- 最大 fd 数に上限がある
- ready でない fd も毎回 scan する

そのため、小さな program の導入としてはよくても、大量 connection を扱う場面では窮屈です。

== `poll`

`poll` は `struct pollfd` の配列を渡します。`select` より API は素直で、fd 上限の扱いも改善されます。ただし本質的には「毎回 user space から監視対象を全部渡し、kernel も全部見て、user space も返ってきた配列を全部なめる」構造です。つまり fd 数が多いと scan コストが効いてきます。

`poll` は `select` より書きやすいことが多いですが、監視対象が大きくなったときの構造的な負担はまだ残ります。

== `epoll`

Linux で大量 fd を扱うときの中心が `epoll` です。`epoll` の発想は、「毎回全部渡すのではなく、監視対象を kernel 側に保持してもらう」ことです。

典型的な流れは次です。

1. `epoll_create1` で epoll instance を作る
2. `epoll_ctl(ADD)` で fd と監視したい event を登録する
3. `epoll_wait` で ready event を待つ
4. 必要なら `epoll_ctl(MOD/DEL)` で登録内容を更新する

ここで user space は、毎回 1000 本の fd 全部を渡し直しません。kernel 側が interest list を持ち、状態変化があったものを ready list へ載せ、`epoll_wait` で user space に返します。この構造が `epoll` の強みです。

#editorial_note[
  `epoll` は「速い魔法」ではありません。毎回全部をなめる構造を減らし、ready になった fd を中心に扱えるようにする設計です。結局 user space は、返ってきた event に対して state machine を回す必要があります。
]

== 最小の `epoll` event loop

C で最小限の骨格だけ書くと、次のようになります。

```c
int ep = epoll_create1(0);
set_nonblock(lfd);

struct epoll_event lev = {
    .events = EPOLLIN,
    .data.fd = lfd,
};
epoll_ctl(ep, EPOLL_CTL_ADD, lfd, &lev);

for (;;) {
    struct epoll_event events[128];
    int n = epoll_wait(ep, events, 128, -1);

    for (int i = 0; i < n; i++) {
        int fd = events[i].data.fd;

        if (fd == lfd) {
            int cfd = accept(lfd, NULL, NULL);
            set_nonblock(cfd);

            struct epoll_event cev = {
                .events = EPOLLIN,
                .data.fd = cfd,
            };
            epoll_ctl(ep, EPOLL_CTL_ADD, cfd, &cev);
            continue;
        }

        ssize_t nr = read(fd, buf, sizeof(buf));
        if (nr > 0) {
            queue_response(fd, buf, (size_t)nr);
        } else if (nr == 0) {
            close(fd);
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            close(fd);
        }
    }
}
```

この code では細かい error handling や write 側の管理を省いていますが、骨格は見えます。`epoll_wait` が ready fd の集合を返し、listening socket なら `accept`、client socket なら `read` を進めます。つまり event loop は「どの fd で、どの状態を、どこまで進めるか」を管理する dispatcher です。

== 1 event = 1 request 完了ではない

ここで初心者が最も引っかかりやすい点を強調します。`epoll_wait` が 1 回 event を返したからといって、1 request 全体が処理し終わるわけではありません。返ってくるのは readiness です。たとえば `EPOLLIN` が来ても、1 回 `read` しただけでは HTTP header の途中までしか読めないかもしれません。逆に `EPOLLOUT` が来ても、送信 queue を全部出し切れるとは限りません。

そのため event loop は、protocol parser と送信 queue を持つ state machine になります。fd ごとに「header 読み中」「body 読み中」「返信待ち」「送信中」といった application state を持ち、その state に応じて `EPOLLIN` / `EPOLLOUT` の扱いを変えます。ここが thread-per-connection の code より少し難しい点です。

== level-triggered と edge-triggered

`epoll` には大きく 2 つの通知モデルがあります。

- level-triggered
  条件が満たされている間、待つたびに event が返り得る
- edge-triggered
  状態が「変化した瞬間」を中心に event が返る

level-triggered は素直です。まだ読める data が残っているなら、次の `epoll_wait` でも再び `EPOLLIN` が返る可能性があります。したがって導入としては理解しやすいです。

edge-triggered は通知回数を減らせますが、使う側の責務が増えます。event を受け取ったら `read` や `accept` を `EAGAIN` になるまで draining しないと、残っている data に再度気付けない可能性があるからです。したがって ET を使うなら、nonblocking と drain loop を必ずセットで考えます。

```c
for (;;) {
    ssize_t nr = read(fd, buf, sizeof(buf));
    if (nr > 0) {
        consume(buf, (size_t)nr);
        continue;
    }
    if (nr == 0) {
        close(fd);
        break;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        break;
    }
    close(fd);
    break;
}
```

== `accept` loop も drain する

ET のときは client socket だけでなく listening socket も同じです。`EPOLLIN` が 1 回来たからといって、新規 connection が 1 本だけとは限りません。複数 connection が queue に積まれているかもしれないので、`accept` も `EAGAIN` まで回します。

この点は見落とされやすいですが非常に重要です。ET で `accept` を 1 回だけ呼んで満足すると、queue に残った接続に気付きにくくなります。

== `EPOLLOUT` は必要なときだけ

write interest の扱いも event loop の定石があります。常に `EPOLLOUT` を監視していると、多くの socket が「今は少し書ける」状態なので、不要な wakeup が増えます。通常は、未送信 data がある socket にだけ `EPOLLOUT` を付け、全部送り切ったら外します。

この pattern は server の効率に直結します。readable event だけを見ている段階より、ここで初めて user-space buffer 管理が前面に出てきます。

== `select` / `poll` / `epoll` の使い分けの感覚

実務では Linux なら `epoll` が中心ですが、学習上は次の感覚が大切です。

- `select`
  概念の導入として分かりやすい
- `poll`
  API は素直だが、毎回全件 scan の構造は残る
- `epoll`
  Linux で大規模 fd を扱う中心。interest を kernel 側へ保持する

つまり、「新しい API ほど偉い」というより、「監視対象をどこで保持し、毎回何を scan するか」の違いで見ると整理しやすいです。

#caution[
  `epoll` は readiness API であって completion API ではありません。`epoll_wait` が返したこと自体は、送信完了や message 完結を保証しません。この区別を曖昧にすると、short read/write や protocol parser の実装で混乱しやすくなります。
]

== Go runtime への前振り

Go runtime は Linux 上では `epoll` 系の backend を使って network I/O を待ちます。ただし user code へは event loop を直接見せません。goroutine ごとに blocking 風の code を書けるようにしつつ、裏では nonblocking fd と poller を使って待ち合わせを共有します。

したがって C で `epoll` event loop を書くことと、Go で connection ごとに goroutine を立てることは、見た目ほど遠くありません。前者では application が state machine を明示的に持ち、後者では runtime が待ち合わせの一部を肩代わりしています。次章では、その橋をもっと具体的に見ます。
