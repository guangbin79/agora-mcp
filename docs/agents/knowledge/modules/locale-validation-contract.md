# locale-validation-contract

> 拒绝式输入校验的 locale 陷阱与单源注册表原子写契约。来源：gt-e96d 评审环 R1（三分册终闸 B/C＋ocr 收敛）。

## 结论
- bash `[[ =~ ]]` 的 `[[:space:]]`/`[[:cntrl:]]` 字符类按**调用方 locale** 解释：C/POSIX locale 退化为单字节语义，UTF-8 多字节分隔符（U+2028/U+0085/U+3000）与无效字节（0xFF）全部放行；而 python 消费端（`splitlines()`/`str.split()`）locale 无关地认它们为行/字段分隔。校验层与消费层解析语义不一致＝假门：拒绝式校验必须落在消费端语义层复核（`isprintable() and v.split()==[v] and 1<=len(v)<=128` 一个条件覆盖控制符/代理字符/零宽/Zs/Zl 全类）。
- U+00A0（NBSP）在 glibc 三 locale（C.UTF-8/en_US.UTF-8/C）下均不过 `[[:space:]]`，但 python `str.split()` 认其为空白——「bash 放行、python 撕裂」在缺省桌面环境即可达，非仅 C locale。
- `open(path,"w").write(...)` 先截断后写：write 阶段任何异常（如 surrogateescape 字符编码失败）都把单条坏输入放大为**全表清零**。单源注册表类文件一律 tmp＋`os.replace` 原子写——异常只留旧表。
- 伪造行的完成态验证要打到消费端：写进去只是一半，须再以正常路径 `--check-only`/解析读回，确认伪行被当真（C 册 W1 实测 `{"registered":true,"entity":"fake-ent"}`）——只看「rc=0 落盘」会低估危害。

## 逐字证据
- C locale 端到端伪造（修复前，LC_ALL=C）：`--sid $'x\u2028fake-ent\u3000fake-sid\u30002099-01-01T00:00:00+08:00' --entity tester` → rc=0 落盘（bash 眼里一行）；随后缺省 locale `--sid fake-sid --entity fake-ent --check-only` → `rc=0 {"registered": true, "fresh": true, "entity": "fake-ent"}`——伪行被 dispatch 准入门/poll 保洁全部消费方认账，ts=2099 永不超龄＝免心跳永生条目。
- NBSP 列错位（修复前，缺省 UTF-8 locale，本会话亲测）：`--sid $'X\u00a02099-01-01T00:00:00+08:00'` → rc=0；map 行 4 字段膨胀，`p[3]`（ts 列）被载荷顶替；`--sid X --check-only` → `rc=0 {"registered": true, "fresh": true}`——map 中从未存在过 sid "X" 的注册调用却被铸造成立。
- 全表清零（修复前，LC_ALL=C）：`--sid $'a\xffb'` → 过 bash 正则 → python argv surrogateescape 得代理字符 → `open(smap,"w")` 已截断 → `UnicodeEncodeError: 'utf-8' codec can't encode characters … surrogates not allowed` → `wc -c=0`，既有注册行全失、dispatch 门集体 REGISTER_REQUIRED。
- 修复形态（register-session.sh python 块）：`for v in (sid, ent): if not (v.isprintable() and v.split() == [v] and 1 <= len(v) <= 128): …exit 2`＋写路径 `tmp = smap + ".tmp"; open(tmp,"w",…).write(…); os.replace(tmp, smap)`。修复后三攻击向量全 rc=2、map 零损伤、ASCII/CJK 正常注册不受影响（中文实体 `isprintable()` 为 True 合法通过）。

## 边界与残余
- 攻击前提是「能调注册 API」——v0 注册面无鉴权，攻击者直连可注册任意真形态行；本次闸防的是 bug/ confused-input 撕裂注册表结构，非鉴权绕过。
- `LC_ALL=C` 的真实可达面：docker/cron/CI 缺省 locale；UTF-8 桌面部署实际暴露面仅 NBSP 一类。
- hostname 字段未过校验（需 CAP_SYS_ADMIN/容器参数才可污染，suggestion 记录不修）；poll.sh `int()` vs register `float()` 对非整数 TTL 的解析差异（poll 侧未改面，记录）。
