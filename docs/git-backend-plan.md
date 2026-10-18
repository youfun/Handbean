# Git 后端拆分计划

## 目标与边界

- 桌面 App、电脑/服务器上的 Phoenix WebUI 默认使用宿主 Git CLI。
- Android/iOS 宿主保留 ExGit/libgit2；按宿主能力显式选择，不按 UI 或 MOB 环境变量猜测。
- 保持 Handbean.Git.perform/4、工具返回数据、工作区权限与现有移动端行为。
- 桌面构建和 release 不编译、不携带 ExGit/libgit2；移动构建显式拥有该依赖。
- 本任务不实现桌面外壳，不改变其他 NIF，不提交或发布。

## 实施步骤

1. **确定契约**：读取 Git 门面、工具、身份/凭据设置、调用者、现有测试以及 mobile 构建与初始化。记录各 action 的语义和返回 metadata。
2. **建立后端边界**：门面保留公共验证与权限；定义小而明确的后端契约。迁移现有 ExGit 实现到移动端可拥有的模块位置，避免桌面编译出现未定义 ExGit 调用。默认 CLI，手机在启动时显式注入后端。不要保留桌面自动回退 NIF。
3. **实现 CLI**：覆盖 init/status/diff/add/reset/commit/log/branches/create_branch/checkout/clone/fetch/pull/push/remotes/remote_add/remote_set_url。使用 executable + argv，不拼 shell；安全处理 option/pathspec 注入、特殊路径和 revision。使用 Git 稳定机器输出（如 porcelain、NUL 分隔）。保留 pull 的 fast-forward-only 语义、路径边界和身份/凭据设置契约，不顺带扩展协议权限。
4. **可用性检测**：支持显式可执行文件配置和 PATH 查找；执行有超时的 git --version 验证，区分缺失、不可执行、探测失败。macOS 缺少开发工具时提供可操作提示，不自动安装。探测不得依赖交互提示；不能仅判断 /usr/bin/git 文件存在。暴露可测试的检测接口并接入实际 Git 调用，失败时返回清楚错误。
5. **进程和安全**：优先复用现有进程管理；设置确定的工作目录、非交互环境、超时与进程回收。凭据不能写 URL、命令行、日志或长期明文临时文件；不改变全局 git config。明确处理继承 Git 环境的仓库重定向风险、hooks/helpers 等执行边界。用户 Git 配置与 Handbean 显式配置优先级要写清楚。
6. **切开依赖**：将 ex_git 从根应用依赖移至 mobile，保留版本锁定和 Android/iOS NIF 构建输入。检查脚本对 deps/ex_git 的路径假设。更新相关文档及与新实现冲突的 AGENTS 指引，不触碰已有无关更改。
7. **测试验收**：桌面真实临时仓库覆盖本地 Git 操作、空仓库、staged/unstaged、分支、特殊文件名、路径越界与参数注入；测试凭据不泄漏、不可用检测、超时和非零退出。远端语义通过本地隔离夹具或注入执行器验证，不访问用户真实远端。验证手机后端选择与原契约，不加载 Android NIF。

## 完成标准

- 根工程相关 Git/工具/Host 测试通过，修改文件格式检查通过，编译无新增警告。
- WebUI 与桌面同走 CLI 的行为有测试证据，不只是模块重命名。
- 根工程生产依赖树不含 ex_git，mobile 依赖树仍含固定版本；可行时检查生产 release 内容。
- 手机相关 host 测试通过；若设备或构建环境限制真机/打包验证，明确报告未验证项目。
- 审阅 diff，确认保留所有既有 Git action 与安全边界，不影响用户未提交的 mobile generated 文件及其他文档。

## 分工

Grok CLI 负责按本计划实现、测试并报告证据。Amp 负责审阅变更、独立运行相关检查并给出最终结论。
