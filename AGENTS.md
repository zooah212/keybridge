# 开发检查

- 构建：`apelin_project_build` 调用 `Apelin/build.sh`，安装使用其包产物与 `apelin_package_install`。
- 隔离回归：`sh Tests/run.sh`。只使用项目临时目录，运行真实 ZIP 解压、索引转换及同名目录替换；结束后清理。测试程序已签名，但本机本次运行被系统以 SIGKILL 终止，不能记为通过。
- 设置页及链接下载须另做真机验证：导入超过 20 秒、离开再返回、网络失败、同名导入失败时旧词库保留。
- `Injector/prerm` 仅在 `remove` 时清理，升级直接退出；已验证本机这次升级前后词库文件清单、大小、修改时间及 active 均保留。更新更早版本前仍须检查已安装的旧脚本并备份词库。

## 上游同步

- 本仓库是 https://github.com/wm0104/keybridge 的分叉。同步口径：`git fetch --no-tags https://github.com/wm0104/keybridge.git main:refs/remotes/upstream/main` 后 `git merge upstream/main`，只取上游侧功能，本分叉的打包口径（形态派生、`KEYBRIDGE_MIN_IOS` 参数化、`firmware` 只声明下限、plist 由 postinst 现场生成、偏好多候选读取）不得被顺带回退。
- 2026-11-06 并入 `acd7c94`（设置页分类展开与原生列表过渡、测试词库、sbreload 注销、`KBCandidateTrace`）：四处冲突按上面的口径解——上游也把最低系统写成了 15.0（但是写死），本分叉保留参数化；上游 `Depends` 带 `firmware (<< 17.0)` 上界，本分叉继续只声明下限（iOS 17 能装）；`Section: 键盘增强`、control Description、`CFBundleVersion 2`、面板编译带 `-DAPELIN_BUILD_ID`、`KEYBRIDGE_CANDIDATE_TRACE=1`（仅 debug 的诊断开关）取上游。上游删除了 `AGENTS.md`，本分叉保留这份口径记录。
- 上游新增的注销/`sbreload` 子系统按 `KBBootstrapRoot()` 拼工具路径（rootless 下得到 `/var/jb`），与本分叉的候选表逻辑不冲突；`KBInject`/偏好读取仍走候选，守护进程状态文件仍写 `prefsPath`、`injectTool`、`injectDylib`。
- 合并后版本 0.0.3（`build.sh` 默认值与 `Info.plist` 的 `CFBundleShortVersionString` 同步；上游也用过 0.0.2，与本分叉的 0.0.2 不是同一份产物，必须往上抬一位）。
- 上游自带的 Python 源码守护测试默认按 UTF-8 读文件，本分叉已补 `encoding='utf-8'`（Windows 默认 GBK 会解码失败）；`Tests/test_settings_rows.py` 需要真实 C 编译器，本机没有 clang 时的失败不是代码问题，不能记为上游功能回归通过。上游新增的原生回归（`Tests/run-local.sh`、`LocalTests.m`、`RespringTests.m`、`RespringStaticChecks.sh`）只在设备/macOS 上跑。

## 打包形态与 CI

- `Apelin/build.sh` 一套脚本出两种包，由 `kb_resolve_scheme` 决定：`KEYBRIDGE_SCHEME=rootless`（包内落 `/var/jb` 前缀，`APELIN_ARCHITECTURE=iphoneos-arm64`，出 fat arm64+arm64e）与 `roothide`（前缀为空，装机时由 vroot 改写）。不给 `KEYBRIDGE_SCHEME` 时按 Apelin 传下的 `APELIN_PREFIX` 推断：空即 roothide，非空即 rootless。本机 Apelin 构建口径不变。
- 编译最低系统统一 `-mios-version-min=${KEYBRIDGE_MIN_IOS:-15.0}`，control 只声明 `firmware (>= $min_ios)` 下限；旧版写死 16.3 与 `<< 17.0` 会让 iOS 15 装完直接跑不起来（守护进程被 dyld 拒，面板只能显示「等待后台接收任务」）。三处版本同步：`build.sh` 默认值、`ImportPreferences/Resources/Info.plist`（`CFBundleShortVersionString` 与 `MinimumOSVersion`）。
- GitHub Actions（`.github/workflows/build.yml`）只出 rootless 包：`workflow_dispatch` 触发，theos 仅用于取 ldid，`brew install dpkg` 供 `dpkg-deb`；版本优先用输入值，否则读 `build.sh`（`KEYBRIDGE_PRINT_VARS_ONLY=1` 只解析不编译）。产物名 `KeyBridge-<版本>-rootless.deb`。roothide 不在 CI 上打包：包内路径与 jbroot 视图绑定，runner 上造不出来也没有真机可验。
- CodeMagic（`codemagic.yaml`，口径参 SwipeDeck）也是只出 rootless 包：`mac_mini_m1` + `xcode: latest`，push / PR 到 main 自动跑。不用 Theos（本项目不用 make 编译），只装 `dpkg` 与 `ldid`（brew bottle 优先，失败回退 openssl@3 源码编译）；同样靠 `KEYBRIDGE_PRINT_VARS_ONLY=1` 取版本号写入 `CM_ENV`，产物平铺为仓库根的 `KeyBridge-<版本>-rootless.deb`。两条 CI 的包内布局校验现在抽到 `Tests/verify-rootless-deb.sh` 共用（不再各自内联一份规则，CodeMagic 首跑就是因为两份内联规则都直接拿 `dpkg-deb -c` 的第 6 列去 `grep -qx` 而没剥归档条目的 `./` 前缀，误报 missing）。改校验只改这个脚本：它用 `dpkg-deb -x` 真正解包后按相对路径判定，不依赖 tar 的列布局（macOS bsdtar 与 Linux GNU tar 字段数不同）；目录只放行 `var` 与 `var/jb` 两个祖先，其余目录与文件一律拦；维护脚本的 CRLF 用字节数差检测，不用 grep 匹配 CR（部分 grep 在文本模式吃掉行尾 CR 会漏报）。
- LaunchDaemon plist 由 `Injector/postinst` 现场生成，包里不再带模板：安装环节可能把落盘 plist 转成 binary1，对它做 `sed` 会整份改坏且 launchd 只报 109、不留日志。postinst 与 prerm 共用同一套前缀探测（rootless `/var/jb`、roothide 空、rootful 空），rootless 的 `ProgramArguments` 用 `sh -c 'sleep 20; exec …'` 越过开机 uncrush 窗口（直接 exec 有「running 却从未进 main、KeepAlive 不再重拉」的先例），roothide 保持原来的直接 exec。安装结论写进 `<词库目录>/install.log`，卸载/排查先看这份。
- 守护进程不再只认一处偏好文件：`var/mobile/Library/Preferences/com.wm0104.keybridge.plist` 的 bootstrap 根、`/var/jb`、真实根、`/rootfs` 候选都读，取 `requestStamp` 最新的那份，并把选中路径写进 `KeyBridgeInjector.json`（`prefsPath`、`keyboardDir`、`injectTool`、`injectDylib`）。opainject 与探针 dylib 同样按候选找，不再假定一定在 bootstrap 根下。`import-task.json` 与 `last-import.json` 写失败会记 os_log，避免面板只剩一句等待提示。
- iOS 15 / rootless 仍待真机验证：守护进程能否被 launchd 拉起并写心跳、opainject 在该越狱里叫什么在哪、探针 hook 在 15 的 `TIKeyboardInputManagerPinyin` 上是否命中、从设置页 ZIP 选择到索引生成的整条导入链，都不能凭源码写成已通过。

## 查询性能验证

- 日常 debug/release 构建均不自动运行查询基准；仅显式设置 `KEYBRIDGE_LOOKUP_BENCHMARK=1` 的 debug 构建启用 `KB_LOOKUP_BENCHMARK`，在 kbd 内复用 `Tests/LookupBench.m` 做边界回归和同索引新旧查询对照。测试使用独立 mmap/cache，不与按键路径共享映射；release 拒绝开启基准。
- 仅显式诊断构建在校验通过前让真实按键使用参考查询，通过后切到有界去重查询；日常构建直接使用优化查询。`KeyBridgeProbe-kbd.json` 的 `buildID`、`benchmark.verified`、`benchmark.samples` 与 `perf` 分别用于识别构建、比对结果、查看热缓存中位数及实际调用耗时。它们不能证明完整的键到屏延迟。
- 流畅度须另测 26 键、九宫格、退格及连续输入，并回归词库切换/停用与排除词更新。修改探针后需征得用户同意再重启 kbd；安装成功不代表旧进程已换用新探针。
- 已签名的独立查询程序与最小 hello 程序都曾以 SIGKILL/137 结束；原因未确定，不能称为沙箱结论或性能测量结果，不要反复换路径、签名或提权重试。

### 2026-11-05 源码性能复核（待真机编译）

- 审查基线 `459e558`，对比最近代码提交 `e2c72ae`：普通 debug 默认运行基准会与输入争用资源；无词库启动时验证失败后可能持续走旧查询。现改为显式诊断开关，日常构建不自动运行基准。
- 重复查询增加 NSCache（countLimit=32，淘汰由系统决定）；键包含规范化输入、数量、26/9模式、算法及普通/自定义映射各自代次。重映射/停用会隔离旧结果，缓存持有字符串而非 mmap 指针。自定义索引纳入已有的 inode/mtime/size 刷新检查。
- 保留原扫描范围、词频加分、Unicode同分排序和自定义词优先；首次短前缀未命中仍可能扫描很多行，未承诺消除延迟尖峰。NSCache线程安全不等于已验证私有输入回调或mmap生命周期的并发安全。
- 本机实际执行：`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p test_build_mode.py -v`，修改前7项中5项失败，修改后7项通过；此测试只执行生产shell函数，用假clang检查参数，不是iOS编译。另通过shell语法与diff检查。
- `Tests/LookupBench.m` 新增生产缓存路径回归（命中、退格重输、输入/数量/模式/算法隔离、custom新增/替换/删除、主索引重映射/停用/重启用及独立基准映射），使用私有夹具；**本轮未运行Foundation原生回归、未编译iOS包、未安装或重启kbd、未启动云端**。不可写成“原生回归通过”或“打字已不卡”。
- 仍待验证：原代码把当前空串回退到旧按键缓冲、九键缓冲提交后的清理语义；排除词使用两个mtime的MAX导致跨库失效不完整。两项可能造成候选残留/设置更新不及时，不当作本轮已修复。
- 用户在Apelin正常构建即可测手感；仅要跑诊断对照时，在Apelin提供的构建环境里设 `KEYBRIDGE_LOOKUP_BENCHMARK=1` 且用debug构建，检查相同buildID的 `benchmark.verified=true` 和 `benchmark.failures=[]`，再单独测试26/9快速连打、退格、切库、停用与自定义词更新。不要一边运行基准一边判定日常打字延迟。

### 2026-11-05 查询测量

- iOS 16.3 / roothide，白霜 1,938,127 行；每次取 5 个候选、交错执行 3 次，以下是查询函数热缓存中位数，不是键到屏延迟：`s` 17.92→5.71 ms，`sh` 19.67→4.26 ms，`shi` 11.98→1.20 ms，九宫格索引 `64` 8.73→1.27 ms。125 项对照（含大量重复词、词频、同分 Unicode 排序、无末尾换行与候选数 1/3/5/8/10）全部一致。
- 确认假设：为前缀区逐条建对象并整体排序有可测的额外耗时；有界去重选择显著降低该部分开销。排除词文件读取与状态写盘是源码可确认的高频工作，但其各自对用户卡顿的贡献未单独测量。
- 重启后最初 10 次真实查询均值 2.38 ms、峰值 5.09 ms，探针自身同步处理峰值 5.35 ms；样本较少，连续输入、退格、26/9 键实测手感及切换词库仍须回归。启动标记监听未捕获本次 marker，不能把状态文件当作加载确认工具成功。
- 后续累计 176 次真实查询均值 3.57 ms、峰值 28.71 ms；探针同步处理峰值 28.75 ms，20 次处理超过 8 ms。峰值输入为九宫格单键字形 `➏`，发生在本轮屏幕测试开始前；尚未分段定位，不能把基准中位数当作延迟上限，也不能说卡顿已消失。
- 设置搜索框点按验证：观察到 26 键 `s` 的首选为「是」，引擎收到 `sh`，点按删除后搜索框显示 `sh`。多次读树未完整取得候选，或与引擎记录不对应，不能记为完整候选显示通过。九宫格界面出现后点按了 MNO 键，下一步 GHI 点按因设置不是已验证前台（SpringBoard 在前台）而被拒绝；已停止界面操作，`64426` 组合及九宫格退格未完成。未截屏、未修改设置；真实快速连打仍须用户手动反馈或另行可控测试。
