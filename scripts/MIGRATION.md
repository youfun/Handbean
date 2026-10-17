# Handbeam → Handbean 数据迁移

需要 Python 3.8 或更新版本及标准库 `sqlite3`，无需安装第三方包。
在同一个操作系统用户下运行，以便读取原配置。执行前停止旧版和新版应用，
避免复制完成后旧版继续写入，或新版创建一个会被跳过的空数据库。

在仓库根目录先预览，再执行：

```bash
python3 scripts/migrate_legacy_data.py
python3 scripts/migrate_legacy_data.py --apply
```

默认复制以下文件，原文件全部保留：

| 来源 | 目标 |
|---|---|
| `~/.handbeam/settings.json` | `~/.handbean/settings.json` |
| `~/.handbeam/models.json` | `~/.handbean/models.json` |
| `~/.handbeam/auth.json` | `~/.handbean/auth.json` |
| `~/.handbeam/workspaces.json` | `~/.handbean/workspaces.json` |
| `<工作区>/.handbeam/settings.jsonc` | `<工作区>/.handbean/settings.jsonc` |
| `~/.handbeam/handbeam.db` | `~/.handbean/handbean.db` |

这里只复制正式数据库，不处理开发库、测试库、手机应用私有数据或整个旧目录。
配置文件逐字节复制，不修改其中的自定义绝对路径或环境变量；如仍引用旧路径，
请在迁移后按需调整。脚本不会输出配置内容或凭据。

工作区登记文件 `workspaces.json` 与数据库必须配套迁移。会话按工作区 ID 关联，
仅复制数据库或在新版重新添加同一路径，都不能恢复原关联。脚本会在复制前检查
工作区会话使用的 ID；缺少登记文件或目标登记文件的 ID 不匹配时，会停止且不复制。

目标已存在时输出 `KEEP existing` 并跳过，不覆盖或合并已有数据；
来源不存在时输出 `MISSING source`。重复执行不会覆盖先前复制的结果。
如已启动过新版且工作区显示 0 条，先停止新旧应用，分别备份新旧的正式数据库、
各自关联文件及 `workspaces.json`。把新版目标文件移出原位置后，再成套迁移旧库和
旧登记文件；保留新版备份，以便找回新版创建的会话。不要只重新添加工作区，也
不要直接修改数据库中的工作区 ID。

数据库通过 SQLite 备份接口创建完整快照，包含 WAL 中已提交的数据，
并在完整性检查通过后发布为单个数据库文件。不要单独用 `cp` 复制正在使用的
SQLite 主文件，也不要把旧数据库的 `-wal`、`-shm` 或应用锁文件配到新数据库上。
新文件在支持 POSIX 权限的平台上仅当前用户可读写。

可为其他工作区、用户目录或自定义正式数据库路径指定参数：

```bash
python3 scripts/migrate_legacy_data.py --workspace /path/to/project
python3 scripts/migrate_legacy_data.py --home /path/to/home --apply
python3 scripts/migrate_legacy_data.py \
  --database-source /path/to/old-production.db \
  --database-target /path/to/new-production.db \
  --apply
```

`--home` 默认是当前用户的 home；`--workspace` 默认是此脚本所在仓库的根目录。
脚本不会自动读取 `DATABASE_PATH`；如应用使用该变量，应显式指定实际数据库路径，
并确保新版启动配置指向复制后的数据库。

执行后启动新版，检查设置、模型和历史记录是否正常，再决定何时归档原文件。
脚本不会启动应用、修改系统环境变量或删除旧数据。

脚本回归测试：

```bash
python3 -m unittest discover -s scripts -p 'test_migrate_legacy_data.py'
```
