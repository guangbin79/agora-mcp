# kill-anchor-contract — kill 能力锚点契约（gt-0a34）

> 进程面 kill 的锚点、旗标解析、竞态与账本字段四道闸；来源 gt-0a34 评审环 B1/C1＋实钉教训。

## 契约

1. **cmdline 锚点须进目标进程自身 argv**：`setsid env A=B cmd` 的赋值参数只在 env 进程存活期可见——env exec 目标命令后 `/proc/PID/cmdline` 变为目标 argv，赋值消失。pid 复用防线（kill 前 cmdline 校验含任务标识）的锚点必须显式送进目标 argv：`bash -c 'script' "$TASK"`（尾随 $0）。实测：仅加 AGORA_TASK= 进 env 时 K1 断言红（cmdline 无任务标识），$0 方案绿。
2. **单参旗标禁落尾随 shift N**：`while case…esac; shift 2` 循环里加单参旗标（`--kill`），末参命中旗标时 shift 2 越界 rc1——set -e 下脚本裸死、零输出。分流：旗标分支 `shift 1`。症状指纹：新旗标一传，整个工具 rc1 且无任何输出（连错误 JSON 都没有）。
3. **标记文件读写双向设防**：dispatch 子进程退出序列 `echo EXIT → rm .live`，与父进程写 pgid（写侧）、cancel 读 pgid（读侧）构成双向竞态窗。写侧：写入后 grep EXIT 行已在则补删（秒死竞态不复活陈旧标记）；读侧：`head -1` 管道必须 `|| true`（pipefail 下 -f 与 head 之间文件消失＝整管道 rc1＝set -e 裸死，cancelled 落账与 JSON 全不执行）。
4. **账本字段进文件/网络操作前形状闸**：账本行字段（`run:`/`session:` 等）是外部可写输入（post.sh 对多数字段零校验、任意 actor 可直发事件）——拼路径 rm 或插 URL 前白名单：run `^raw/dispatches/d-[0-9a-f]+\.log$`（防路径穿越删任意 `.live`/`.pid`）、sid `^[-A-Za-z0-9_]+$`。防线位置须覆盖全部消费分支（rm 在不杀分支也执行时，cmdline 校验不构成覆盖）。
5. **smoke 假 runtime 的 ctrl 态是批次间全局态**：active_dir 等 stub 状态文件跨批残留会改变后续批次行为（在场检测命中 → dispatch 降级 notified → 无 spawn → pgid 断言假红）。需要「无在场」语义的批次批前显式复位（echo /nonexist）。

## 事故教训
- K 批七红两根因（R1）：cmdline 锚点丢失（契约 1）＋shift 越界（契约 2）——先单点复现取证再改，勿对着断言猜。
- K5 假红两轮（R3/R4）：第一轮误判为时序窗加长循环，第二轮 k5.out 的 `mode=notified` 才现形真因（契约 5）——fail 信息里带上原始输出（k5.out）是二轮定位的关键。
