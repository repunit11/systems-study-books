#import "../theme.typ": checkpoint, caution

= rings、trap、user mode

process を作る前に、まず CPU がどのように権限境界を持っているかを整理する必要があります。もし user code が kernel と同じ権限で動くなら、syscall という概念自体が不要です。逆に user mode があるからこそ、「普通の命令ではできないことを kernel に頼む」という形が必要になります。本章では x86-64 の privilege level、trap、user mode への移行を扱います。

#checkpoint[
  この章の到達点は次の通りです。

  - user mode / kernel mode を分ける理由を説明できる
  - trap と interrupt が kernel entry の一般形だと分かる
  - trap frame が何を保存するのかを説明できる
  - `iretq` が user mode へ戻るための出口だと理解する
]

== なぜ権限境界が必要なのか

user program は信用しません。少なくとも OS 設計では、その前提が出発点になります。もし任意の program が page table を書き換えたり、デバイスレジスタを触ったり、他 process の memory を直接読めたりしたら、保護も隔離も成立しません。したがって CPU は、実行主体ごとに許される操作を分ける必要があります。

x86-64 では ring 0 と ring 3 が主役です。ざっくり言えば、ring 0 が kernel、ring 3 が user です。この区別があるから、普通の user code は privileged instruction を実行できず、kernel へ入るには決められた入口を通る必要があります。

== page table 上の user / kernel 境界

権限境界は CPU mode だけでなく、page table にも現れます。x86-64 の page table entry には user/supervisor bit があり、user mode から触れてよい page と kernel 専用 page を分けられます。つまり「どの命令が privileged か」だけでなく、「どの address range が見えるか」も OS が決めます。

この観点を持つと、process は単なる register 集合ではなく、独自の address space を持つ実行主体だと見えてきます。後の `exec` や `fork` で address space が主役になる理由もここにあります。

== trap は kernel entry の一般形

user code が kernel へ入る経路はひとつではありません。例外、ハードウェア割り込み、そして syscall がいずれも制御移動を起こします。しかし CPU 側から見れば、いずれも「今の実行文脈を保存し、特権側の handler へ飛ぶ」経路です。この共通枠が trap です。

ここで trap frame という考え方が便利になります。user 側の `rip`, `rsp`, `rflags`、必要な general-purpose register などをまとめて保存しておけば、後で「どこへ戻るか」を再構成できます。つまり trap frame は、user 文脈のスナップショットです。

== kernel stack が必要な理由

user stack は user process 自身の所有物です。そこへ kernel の内部処理を積み重ねるのは危険です。user memory が壊れているかもしれませんし、権限分離の意味も薄れます。そこで process ごとに kernel stack を持ち、kernel entry 後の処理はそちらで進めるのが自然です。

この設計は後の context switch でも効きます。process ごとに kernel stack と trap frame を持っていれば、どの process がどの状態で kernel に入っていたかを整理しやすくなるからです。

== user mode へ「降りる」とは何か

kernel が user process を初めて走らせるとき、やるべきことは単純ではありません。単に `jmp` で user entry へ飛ぶだけでは足りません。user 用 page table、user stack pointer、user `rip`、適切な `rflags`、segment まわりの前提を揃えたうえで、特権レベルを下げて戻る必要があります。

教育用として分かりやすいのは、「trap から戻る形を人工的に作る」と考えることです。つまり kernel が user 用 trap frame を事前に作り、それを `iretq` で消費して user mode へ戻すイメージです。これで「初回起動」と「通常の trap return」を同じ枠で説明しやすくなります。

== `iretq` と `syscall/sysret`

x86-64 には一般的な trap return として `iretq` があり、専用の syscall fast path として `syscall/sysret` があります。本書ではまず `iretq` 的な一般像で理解し、そのあとで「実際の syscall はもっと専用の経路を使うことがある」と見る方針を取ります。

この順序には意味があります。`syscall/sysret` は速いですが、前提も専用です。最初に専用経路だけを見せると、「なぜ user 文脈を別 stack に退避するのか」「なぜ trap frame という考え方が必要か」が見えにくくなります。

== TSS と stack 切り替え

x86-64 では、特権遷移時の stack 切り替えや例外時の特別 stack に TSS が関わります。`rust-os-book` では主に例外と IST の文脈で見ましたが、user mode を導入すると「ring 3 から ring 0 に入るときの kernel stack」をどこから取るかが重要になります。

つまり TSS は古い segmentation の名残として覚えるより、「特権遷移の足場を渡すための構造」と見るほうが実用的です。

#caution[
  user mode を導入するとき、最初に壊れやすいのは user `rip` そのものより stack と page table の整合です。user stack がまだ map されていない、kernel stack を切り替える前に push してしまう、といった順序ミスが典型です。
]

== この章の出口

ここまでで、「なぜ syscall が必要か」「kernel entry は何を保存するか」「どうやって user mode へ戻るか」という土台はできました。次章ではその上に、実際の syscall path を entry、dispatch、return に分けて載せます。
