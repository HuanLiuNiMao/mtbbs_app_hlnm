# 分支管理与 Debug 包构建
> 适用：开工建分支、合并前检查、需要用 GitHub Actions 出一包验证前必读。

## 分支命名

| 前缀 | 用途 | 示例 |
| --- | --- | --- |
| feat/ | 新功能 | feat/mcp-floating-ball |
| fix/ | 缺陷修复 | fix/mcp-dialog-reentry |
| refactor/ | 不改行为的重构 | refactor/about-author-name |
| ci/ | 流水线变更 | ci/debug-apk-workflow |
| docs/ | 仅文档 | docs/branching-guide |

分支名小写、连字符分词。不要直接在 main 上改代码；**唯一例外是 CI workflow 文件**，见下。

## 提交信息

Conventional Commits，中文描述：type(scope): 一句话结论。正文写「为什么」不写「改了什么」，改动细节交给 diff。

| type | 场景 |
| --- | --- | --- |
| feat | 新增能力 |
| fix | 修缺陷 |
| refactor | 行为不变的结构调整 |
| ci | 流水线 |
| docs | 文档 |
| chore | 依赖、配置 |

一个 commit 只做一件事。无关改动（例如顺手改的文案）单独一个 commit，方便回滚。

## Debug 包：用 CI，不要在本机纠结

本机 Flutter 版本若高于项目锁定版本，会出现这条报错并直接中断构建：

> Your project Gradle version (9.1.0) is lower than Flutter minimum supported version of 9.3.1

**这不是代码问题，不要去升仓库的 Gradle。** 项目 Gradle wrapper 锁 9.1.0 是为了和 release.yml 的 Flutter 3.44.2 配套；升上去会把发布流水线一起弄坏。正确做法是让 CI 用同一套版本编。

## debug-apk.yml 用法

| 项 | 内容 |
| --- | --- |
| 触发 | 手动 workflow_dispatch |
| 环境 | Flutter 3.44.2 + Java 17 (zulu) + Gradle 9.1.0，与 release.yml 一致 |
| 产物 | mtbbs-debug-apk（artifact，14 天） |
| 日志 | analyze-log（7 天，always 上传） |
| 签名 | 走内置 testkey.keystore 回退，**不需要任何 Secrets** |

### 一个必须知道的限制

**GitHub 只索引默认分支（main）上的 workflow 文件。** 如果把新的 workflow 只提交到功能分支，API 调用会返回 404 Not Found，界面里也不显示这个 workflow。

所以流程是：workflow 文件先单独提交到 main 并推送，等它变成 active，再在功能分支上触发构建。

## 合并前检查

1. dart analyze 无 error；2. 功能分支的 debug 包能编出来；3. 文档与两个索引（AGENTS.md、README.md）同步。
