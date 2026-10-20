# 开源记忆工具与 Nowledge Mem 的数据结构对照

核对日期：2026-10-17。下面只写当时能打开的源码或官方文档。Nowledge Mem 的引擎没有开源，所以它这一节是逻辑模型，不是物理表 DDL。Letta 的现行源码已迁到 `letta-code`，表结构取自已归档的 V1 ORM。

## 结论先说

这几家没有一家把“说不清的关系”落成一条 `related`。

- 关系要么是边上的开放名字（Nowledge Memory Link、Cognee `relationship_name`、Graphiti `EntityEdge.name`）。
- 要么根本没有记忆到记忆的关系表（mem0）。
- 版本变化和普通关联是两条边，不混在一个枚举里（Nowledge `EVOLVES`，Graphiti 的 `valid_at` / `invalid_at`）。
- 原始对话和抽出来的记忆也不是同一行（Nowledge Trace / Unit，Letta message / passage，Graphiti Episodic / Entity）。

Handbean 现在是两张表：`engrams` 存正文，`synapses` 用封闭的五种 `kind` 连两条记忆。召回排序不读这条边。提示词里写的 `requires`、`depends_on`、`implements` 工具并不接受。

## 一张对照

| 系统 | 记忆正文放哪 | 原始对话放哪 | 关系怎么存 | 关系名是否封闭 |
| --- | --- | --- | --- | --- |
| Handbean | `engrams.content` | 不在记忆表 | `synapses.kind` | 是，五种 |
| Nowledge Mem | Memory；Crystal 仍是 Memory | Thread | Memory Link、`EVOLVES`、实体边、`CRYSTALLIZED_FROM` | Memory Link 开放；`EVOLVES` 只有四种 |
| mem0 | 向量库 payload | SQLite `messages` | 无关系表 | 不适用 |
| Letta archive | `block.value`、`archival_passages.text` | `message` | 多对多连接表，不是语义边 | 连接表没有关系名 |
| Cognee | 图节点 `attributes`，另有图数据库 | `data` 是原始文件 | `edges.relationship_name` | 否，自由文本 |
| Graphiti | `EntityEdge.fact`，节点有 `summary` | `EpisodicNode.content` | `EntityEdge.name`，另有结构边 | 边名开放；结构边是固定标签 |

## Handbean

来源：

- [priv/repo/migrations/20260514032113_create_engrams_and_synapses.exs](../../priv/repo/migrations/20260514032113_create_engrams_and_synapses.exs)
- [lib/handbean/memory/engram.ex](../../lib/handbean/memory/engram.ex)
- [lib/handbean/memory/synapse.ex](../../lib/handbean/memory/synapse.ex)
- [lib/handbean/memory/memory_store.ex](../../lib/handbean/memory/memory_store.ex)
- [lib/handbean/memory/prompt_policy.ex](../../lib/handbean/memory/prompt_policy.ex)

`engrams`：`content`、`kind`、`short_term`、`expires_at`、`reinforced_count`、`last_reinforced_at`、`metadata`。`kind` 是 `fact`、`pattern`、`preference`、`rule`、`context`。短期记忆默认 24 小时过期，`reinforce` 后变长期。

`synapses`：`source_id`、`target_id`、`kind`、`strength`、`metadata`。唯一约束是 `(source_id, target_id, kind)`。`kind` 只允许 `related`、`contradicts`、`example_of`、`context_for`、`reinforces`。

召回先按命中 token 数、FTS `bm25`、是否长期、强化次数排序，然后才 preload synapse。排序键不读 `kind` 或 `strength`。模块注释写 strength 会衰减，写入路径没有衰减逻辑。

## Nowledge Mem

公开仓库只有说明，没有 `CREATE TABLE`：[nowledge-co/nowledge-mem](https://github.com/nowledge-co/nowledge-mem)。

导出不是数据库转储。官方写明是 JSON / JSONL / Markdown，向量和全文索引可以重建，不进备份：[Back Up, Export, and Import](https://mem.nowledge.co/docs/data-portability)。导出记录包括 memories、threads、sources、entities、skills 和 graph edges。Working Memory 是 Markdown。

### 记忆和线程是两种记录

[Memories](https://mem.nowledge.co/docs/memories) 把可单独阅读的结论和原始对话分开。Memory 字段至少有 title、content、type、labels、importance、created。`unit_type` 是：

`fact`、`preference`、`decision`、`plan`、`procedure`、`learning`、`context`、`event`。

importance 是 0.1 到 1.0，默认 0.5，参与搜索和 briefing 排序。写入入口包括 `POST /memories`、`nmem m add`、MCP `memory_add` / `memory_update` / `memory_delete`。

### 边不进一个 related 桶

[Memory Links](https://mem.nowledge.co/docs/concepts/memory-links) 是人或者 agent 明确保存的记忆到记忆边，不是搜索相似度。建议名包括 `supports`、`contradicts`、`depends_on`、`example_of`、`blocks`、`same_topic`，也可以自定义。`same topic`、`same-topic`、`same_topic` 会规范成同一个名字。两条记忆必须在同一个 Space。

它和下面几种边分开：

| 边 | 来源 | 含义 |
| --- | --- | --- |
| Memory Link | [memory-links](https://mem.nowledge.co/docs/concepts/memory-links) | 这两条记忆应该一起读，关系名开放 |
| `EVOLVES` | [evolves](https://mem.nowledge.co/docs/concepts/evolves) | 知识怎么变了 |
| Label | 同上 | 宽分类，不是两条记忆之间的原因 |
| Entity graph | 同上 | 人、项目、工具、概念及其关系 |
| Search | 同上 | 没保存关系时的相似检索 |

`EVOLVES` 只有四种：`replaces`、`enriches`、`confirms`、`challenges`。前两种是版本推进，被替换的旧记忆在日常搜索里标成 superseded，历史检索仍能看到。后两种是证据，不替换原文，两边都保持有效。

[Crystals](https://mem.nowledge.co/docs/concepts/crystals) 仍是 Memory，但要至少三个独立来源才合成。来源边是 `CRYSTALLIZED_FROM`。确认后的 Crystal 有排序加权，驳回后降权，不删除。来源变化时系统提议重评，不静默改写已确认的 Crystal。

公开文档没有给出完整的 7 节点 / 11 边枚举，也没有物理表 DDL。上面只列文档点了名的记录和边。

## mem0

来源：

- [mem0/memory/storage.py](https://github.com/mem0ai/mem0/blob/main/mem0/memory/storage.py)
- [mem0/memory/main.py](https://github.com/mem0ai/mem0/blob/main/mem0/memory/main.py)
- [mem0/vector_stores](https://github.com/mem0ai/mem0/tree/main/mem0/vector_stores)

SQLite 只有两张本地表，都不是关系图。

`history`：`id`、`memory_id`、`old_memory`、`new_memory`、`event`、`created_at`、`updated_at`、`is_deleted`、`actor_id`、`role`。这是变更审计。旧 schema 里的会话列会被迁移删掉。

`messages`：`id`、`session_scope`、`role`、`content`、`name`、`created_at`。

可检索记忆在向量库 payload 里。作用域是 `user_id`、`agent_id`、`run_id`，由实体参数写入 metadata；调用方 metadata 里的同名键会被丢掉。向量库有很多适配器，没有统一的关系表。

## Letta

现行仓库说明源码已迁到 [letta-ai/letta-code](https://github.com/letta-ai/letta-code)。下面的表来自归档分支 [letta/orm](https://github.com/letta-ai/letta/tree/archive/letta/orm)，不是现行产品的物理库承诺。

已读到的记忆相关表：

- [`block`](https://github.com/letta-ai/letta/blob/archive/letta/orm/block.py)：上下文里的一块核心记忆。`label`、`value`、`limit`、`description`、`read_only`、`metadata_`、`version`、`current_history_entry_id`。`label` 用来区分 `human`、`persona` 这类块，不是关系类型。
- [`archival_passages`](https://github.com/letta-ai/letta/blob/archive/letta/orm/passage.py)：归档记忆。`text`、`embedding`、`embedding_config`、`metadata_`、`tags`，并按 `archive_id` 索引。
- [`source_passages`](https://github.com/letta-ai/letta/blob/archive/letta/orm/passage.py)：外部文件切块。多一个 `file_name`，并索引 `file_id`。

同目录还有 `message.py`、`step.py`、`source.py`、`blocks_agents.py`、`archives_agents.py`、`block_history.py`。核心记忆、归档记忆、文件块、对话消息是不同的表，不是一行加一个 kind。连接表表达“谁拥有这块记忆”，不表达 `depends_on` 这类语义。

## Cognee

关系库模型和 Kuzu/Ladybug、Neo4j 图库是两套存储。这里核对的是关系库模型。

来源：

- [modules/graph/models/Node.py](https://github.com/topoteretes/cognee/blob/main/cognee/modules/graph/models/Node.py)
- [modules/graph/models/Edge.py](https://github.com/topoteretes/cognee/blob/main/cognee/modules/graph/models/Edge.py)
- [modules/graph/models/EdgeType.py](https://github.com/topoteretes/cognee/blob/main/cognee/modules/graph/models/EdgeType.py)
- [modules/data/models/Data.py](https://github.com/topoteretes/cognee/blob/main/cognee/modules/data/models/Data.py)

`nodes`：`id`、`slug`、`user_id`、`data_id`、`dataset_id`、`pipeline_run_id`、`label`、`type`、`indexed_fields`、`attributes`、`created_at`。`type` 是文本，`attributes` 和 `indexed_fields` 是 JSON。节点正文不拆成固定列。

`edges`：`source_node_id`、`destination_node_id`、`relationship_name`、`label`、`attributes`，再加同样的用户、数据集、来源文件和 pipeline 作用域。`relationship_name` 是自由文本，不是封闭枚举。

`data` 是原始文件行：`name`、`mime_type`、`raw_data_location`、`content_hash`、`owner_id`、`dataset_id`、`external_metadata`、`system_metadata`、`node_set`、`pipeline_status`、`importance_weight`。同一内容在两个 dataset 里是两行。

图数据库适配器目录在 [infrastructure/databases/graph](https://github.com/topoteretes/cognee/tree/main/cognee/infrastructure/databases/graph)。当前 `kuzu/adapter.py` 只是把旧名转到 Ladybug，不能把它当成 DDL。

## Graphiti

来源：

- [graphiti_core/nodes.py](https://github.com/getzep/graphiti/blob/main/graphiti_core/nodes.py)
- [graphiti_core/edges.py](https://github.com/getzep/graphiti/blob/main/graphiti_core/edges.py)

这是图模型，不是一套 SQL 表。后端包括 Neo4j、Kuzu、FalkorDB、Neptune。Kuzu 里实体关系边会落成 `RelatesToNode_` 节点，因为该后端不把这种边当一等关系。

节点公共字段：`uuid`、`name`、`group_id`、`labels`、`created_at`。

| 标签 | 已核对字段 | 角色 |
| --- | --- | --- |
| `Episodic` | `source`、`source_description`、`content`、`valid_at`、`entity_edges`、`episode_metadata` | 原始事件。`source` 是 `message`、`json`、`text`、`fact_triple` |
| `Entity` | `name_embedding`、`summary` | 抽出的实体。摘要来自周围边 |
| `Community` | `name_embedding`、`summary` | 一组节点的区域摘要 |
| `Saga` | `summary`、`last_summarized_episode_valid_at` | 覆盖一段 episode 的摘要 |

边：

| 类 | 作用 |
| --- | --- |
| `EpisodicEdge` | 情节边 |
| `EntityEdge` | 语义事实。`name` 是关系名，`fact` 是这句话，`episodes` 指向来源情节，`valid_at` / `invalid_at` 是事实有效期 |
| `CommunityEdge` | 社区成员关系 |
| `HasEpisodeEdge` | 拥有情节 |
| `NextEpisodeEdge` | 情节顺序 |

删除语句里出现的结构标签是 `MENTIONS`、`RELATES_TO`、`HAS_MEMBER`。语义关系名在 `EntityEdge.name`，不是这几个固定标签。事实过期靠 `invalid_at`，不靠把边改名为 `related`。

## 对 Handbean 的含义

不支持的关系不要建成 `related`。

- `contradicts` 已经有对应值，不能降级。
- `example_of` 已经有对应值。
- `depends_on` 更接近 `context_for`，但方向是 source 给 target 提供背景，不能假装它就是依赖。对不上就不要建边。
- `requires`、`implements`、`related_to` 现在会报非法 kind。改提示词，或者给 schema 加开放关系名。不要先写成 `related` 以后再解释。
- 如果要借鉴这几家，优先分开三件事：原始对话、可检索记忆、带名字和时间的边。关系名用开放文本，版本关系单独一条边。召回要读边，否则多出来的 kind 只给 UI 看。
