# Claude Code Hooks：Agent Workspace 实时会话渲染调研

> 状态：已被 live-pane 方案取代。Agent Workspace 当前直接渲染 tmux scrollback，不安装 Hook，也不读取 Claude JSONL；以下内容仅保留为未来结构化历史模式的研究资料。

调研日期：2026-07-12。目标是让 Hook 只承担“数据已变化”的通知职责，Claude JSONL 继续作为唯一事实源，不接管登录、不复制凭证，也不让 Hook 生成第二份会话记录。

## 结论

1. 当前 Claude Code 有 30 个 Hook 事件。本机 `claude --version` 为 `2.1.207`，已支持 `MessageDisplay`；该事件在 `2.1.152` 加入。[官方 Hooks reference](https://code.claude.com/docs/en/hooks#hook-lifecycle) · [官方 CHANGELOG 2.1.152](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21152)
2. 官方明确说明：`transcript_path` 指向的会话文件是**异步写入**的，Hook 触发时可能还没有当前回合的最新消息；因此 Hook 触发后立即读取可能短暂落后。[Common input fields](https://code.claude.com/docs/en/hooks#common-input-fields) 本次实机问题已证明是长历史布局后失去贴底，而不是 JSONL 漏写，Hook 不能替代滚动状态修复。
3. 没有逐 token Hook，也没有名为 `TranscriptAppend` 的专用事件。`MessageDisplay` 在交互模式下按“新完成的文本行批次”触发；短消息可能一次，长消息多次。纯工具调用、工具结果和用户输入不会触发它。[MessageDisplay](https://code.claude.com/docs/en/hooks#messagedisplay)
4. Claude Code 可以在 `SessionStart` 返回绝对路径 `watchPaths`，随后由 `FileChanged` 在被监视文件实际变化时触发。对 Agent Workspace，最可靠的最小链路是：`SessionStart.watchPaths = [transcript_path]` → `FileChanged` → UI 重新 tail JSONL。[SessionStart output](https://code.claude.com/docs/en/hooks#sessionstart-decision-control) · [FileChanged](https://code.claude.com/docs/en/hooks#filechanged)
5. `MessageDisplay` 可以作为更早的“Claude 正在输出”提示，但不应把 `delta` 直接写入持久会话模型。否则 UI 会拥有 JSONL 与 Hook delta 两个事实源，并且无法用 `message_id` 与 transcript 记录可靠关联。

## 与实时渲染直接相关的事件

### `MessageDisplay`：按行批次，不是按 token

交互模式下，每批新增的完整行准备显示时触发；最后一批可以在行中间结束。非交互模式（Agent SDK、`claude -p`）则在整条 assistant message 完成后只触发一次。[官方输入规范](https://code.claude.com/docs/en/hooks#messagedisplay-input)

```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/me/.claude/projects/.../abc123.jsonl",
  "cwd": "/Users/me/project",
  "hook_event_name": "MessageDisplay",
  "turn_id": "...",
  "message_id": "...",
  "index": 0,
  "final": false,
  "delta": "Here is the plan:\n"
}
```

约束：

- `message_id` 只在同一条流式消息的批次之间稳定，不是 API 的 `msg_…` id，也不能和 transcript message id 关联。
- `final: true` 才是消息结束信号；如果消息恰好以换行结尾，最后一次 `delta` 可以为空。
- 无 matcher，所有 assistant 文本都会触发；不包含工具结果和用户输入。
- 同步 Hook 返回前 Claude Code 会暂缓显示该批次，默认超时 10 秒。失败或超时后显示原文。
- `displayContent` 只改变终端显示，不改变 transcript，也不改变 Claude 看到的内容。[MessageDisplay output](https://code.claude.com/docs/en/hooks#messagedisplay-output)

因此 Agent Workspace 只消费其 `session_id`、`transcript_path`、`final` 作为失效/活跃提示；不消费 `delta` 作为会话正文。

### `FileChanged`：实际写盘后的失效信号

`SessionStart` 可返回：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "watchPaths": ["/absolute/path/from/transcript_path.jsonl"]
  }
}
```

`watchPaths` 接受绝对路径。文件发生创建、修改或删除后，`FileChanged` 输入提供 `file_path` 与 `event`（`add`、`change`、`unlink`）。这比在 `MessageDisplay` 到达后立刻读取一个可能尚未追平的 transcript 更贴近事实源。[FileChanged input](https://code.claude.com/docs/en/hooks#filechanged-input)

Claude Code 没有单独的 transcript-append 事件；这里是把通用 `FileChanged` 动态绑定到本次会话的 `transcript_path`。

### `Stop`：回合结束校准

`Stop` 在主 agent 完成响应后触发，带有 `last_assistant_message`。官方明确建议：需要刚完成文本的 Hook 应读取该字段，而不是假设 `transcript_path` 已经追平。[Stop input](https://code.claude.com/docs/en/hooks#stop-input)

Agent Workspace 仍不把 `last_assistant_message` 写入正式记录；它只把 `Stop` 当作“进行一次最终 JSONL 重读/延迟重试”的信号。用户中断不会触发 `Stop`，API 错误会改触发 `StopFailure`，所以最终校准还应覆盖 `StopFailure`。[StopFailure](https://code.claude.com/docs/en/hooks#stopfailure)

### `statusLine` 不是实时正文 Hook

`statusLine` 是 Claude 终端底部的一行自定义输出。它在完整 assistant message、`/compact`、权限模式和 Vim 模式变化后更新，300ms debounce；新触发会取消仍在运行的脚本。它有 `session_id`、`transcript_path`、模型、成本和上下文数据，但没有流式正文 delta。[官方 Status line](https://code.claude.com/docs/en/statusline#how-status-lines-work) · [Available data](https://code.claude.com/docs/en/statusline#available-data)

结论：不要占用或改写用户的 `statusLine` 来驱动 Agent Workspace。它只能提供回合级信号，且职责是渲染 Claude 自己的状态栏；`MessageDisplay`/`FileChanged` 才是合适的事件面。

## 当前事件与输入字段

所有事件先接收公共字段：`session_id`、可选 `prompt_id`、`transcript_path`、`cwd`、部分事件上的 `permission_mode`/`effort`、`hook_event_name`；子 agent 场景还可能有 `agent_id`/`agent_type`。事件特有字段如下。字段后的 `?` 表示可选。[Common input fields](https://code.claude.com/docs/en/hooks#common-input-fields) · [Hook events](https://code.claude.com/docs/en/hooks#hook-events)

| 事件 | 事件特有输入 | matcher 对象 |
|---|---|---|
| `SessionStart` | `source`, `model?`, `agent_type?`, `session_title?` | 启动来源 |
| `Setup` | `trigger` | `init` / `maintenance` |
| `UserPromptSubmit` | `prompt` | 不支持 |
| `UserPromptExpansion` | `expansion_type`, `command_name`, `command_args`, `command_source`, `prompt` | command name |
| `MessageDisplay` | `turn_id`, `message_id`, `index`, `final`, `delta` | 不支持 |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` | tool name |
| `PermissionRequest` | `tool_name`, `tool_input`, `permission_suggestions?`；没有 `tool_use_id` | tool name |
| `PermissionDenied` | `tool_name`, `tool_input`, `tool_use_id`, `reason` | tool name |
| `PostToolUse` | `tool_name`, `tool_input`, `tool_response`, `tool_use_id`, `duration_ms?` | tool name |
| `PostToolUseFailure` | `tool_name`, `tool_input`, `tool_use_id`, `error`, `is_interrupt?`, `duration_ms?` | tool name |
| `PostToolBatch` | `tool_calls[]` | 不支持 |
| `Notification` | `message`, `title?`, `notification_type` | notification type |
| `SubagentStart` | `agent_id`, `agent_type` | agent type |
| `SubagentStop` | `stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`, `background_tasks`, `session_crons` | agent type |
| `TaskCreated` | `task_id`, `task_subject`, `task_description?`, `teammate_name?`, `team_name?` | 不支持 |
| `TaskCompleted` | 同 `TaskCreated` | 不支持 |
| `Stop` | `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons` | 不支持 |
| `StopFailure` | `error`, `error_details?`, `last_assistant_message?` | error type |
| `TeammateIdle` | `teammate_name`, `team_name` | 不支持 |
| `InstructionsLoaded` | `file_path`, `memory_type`, `load_reason`, `globs?`, `trigger_file_path?`, `parent_file_path?` | load reason |
| `ConfigChange` | `source`, `file_path?` | configuration source |
| `CwdChanged` | `old_cwd`, `new_cwd` | 不支持 |
| `FileChanged` | `file_path`, `event` | 特殊：literal filename/watch list |
| `WorktreeCreate` | `name` | 不支持 |
| `WorktreeRemove` | `worktree_path` | 不支持 |
| `PreCompact` | `trigger`, `custom_instructions` | `manual` / `auto` |
| `PostCompact` | `trigger`, `compact_summary` | `manual` / `auto` |
| `Elicitation` | `mcp_server_name`, `message`, `mode?`, `url?`, `elicitation_id?`, `requested_schema?` | MCP server name |
| `ElicitationResult` | `mcp_server_name`, `action`, `mode?`, `elicitation_id?`, `content?` | MCP server name |
| `SessionEnd` | `reason` | exit reason |

与正文完整性最相关的是 `SessionStart`、`FileChanged`、`MessageDisplay`、`UserPromptSubmit`、`PostToolUse`/`PostToolUseFailure`、`Stop`/`StopFailure`、`PostCompact`、`SessionEnd`。其余事件不应为了“保险”全部安装，否则只会增加进程数和噪声。

## Matcher 与异步语义

Matcher 规则：[官方 Matcher patterns](https://code.claude.com/docs/en/hooks#matcher-patterns)

- `"*"`、空字符串或省略：匹配该事件的每次发生。
- 只含普通字符以及 `,`/`|`：精确字符串或精确列表。为了兼容旧版本，列表优先写 `A|B`。
- 含其他字符：按 JavaScript 正则、非锚定匹配；需要全匹配时显式使用 `^…$`。
- `if` 只对 `PreToolUse`、`PostToolUse`、`PostToolUseFailure`、`PermissionRequest`、`PermissionDenied` 生效；放到其他事件会导致 handler 永不运行。
- `FileChanged` 特殊：matcher 同时建立 literal filename watch list，并在事件发生时按 basename 过滤；动态绝对路径应通过 `watchPaths` 添加。
- 同时匹配的 handlers 并行执行；相同 command+args 或相同 HTTP URL 会自动去重。[Hook handler fields](https://code.claude.com/docs/en/hooks#hook-handler-fields)

异步规则：[Run hooks in the background](https://code.claude.com/docs/en/hooks#run-hooks-in-the-background)

- 默认 Hook 会等待 handler 完成。
- 只有 `type: "command"` 支持 `async: true`。
- 异步 Hook 不能 block、allow、deny 或改变已发生的动作；decision 类输出无效。
- 每次触发都会建立独立后台进程，跨触发不去重；完成顺序也不应被视为事件顺序。
- 输出通常延迟到下一轮才交给 Claude。Agent Workspace 的 helper 应保持 stdout/stderr 为空，只做本地 IPC。

对纯失效信号而言乱序无所谓：接收端按 `session_id` 合并成“需要重读”，不重放 Hook 序列。`SessionStart` 是例外，必须同步返回 `watchPaths`。

## 推荐的最小安全架构

```text
Claude Code
  ├─ SessionStart ──同步 helper──> 注册 session + 返回 watchPaths
  ├─ FileChanged ──快速 IPC──────> invalidate(session_id, transcript_path)
  ├─ MessageDisplay（可选）──────> mark-active + schedule-read
  └─ Stop/StopFailure ───────────> final-reconcile
                                      │
                                      ▼
Agent Workspace IPC receiver ──50–100ms 合并──> incremental JSONL tailer ──> UI
                                                    ▲
                                                    └── 唯一正文事实源
```

实现约束：

1. **MVP 必需事件只有 `SessionStart` + `FileChanged`。** `MessageDisplay` 用于更及时的 working 状态；`Stop`/`StopFailure` 用于最终校准。若 JSONL 尚未写入，UI 只能显示“正在输出”，不能在坚持 JSONL-only 的同时凭空展示正文。
2. **Hook 载荷只当提示。** IPC 只发送 `session_id`、`transcript_path`、事件名和少量状态；不传 `delta`、prompt、tool output 或凭证。
3. **尾读必须可恢复。** 按 inode/device/offset 增量读取，只解析以换行结束的完整 JSON；保留未完成尾字节。inode 变化或文件缩小时重建；解析未知字段时忽略，而不是让整条会话失败。Hooks 文档公开了 transcript 路径，但没有承诺内部 JSONL record schema 的稳定版本。
4. **早到信号要重试。** `MessageDisplay` 到达但文件无新增完整 record 时，建议在 25/75/200/500ms 做有界重试；`FileChanged` 和 `Stop` 到达时再强制校准。具体间隔是 Agent Workspace 的工程策略，不是 Claude API 保证。
5. **Hook 不能成为唯一可用路径。** app 仍保留 macOS 文件监听与低频 polling watchdog；Hooks 被 `disableAllHooks`、managed policy、旧版 CLI 或用户卸载时，历史仍能恢复。[Disable hooks](https://code.claude.com/docs/en/hooks#disable-or-remove-hooks) · [Managed hook policy](https://code.claude.com/docs/en/settings#hook-configuration)
6. **不启动 app，不阻塞 Claude。** helper 找不到本地 IPC receiver 时应静默 `exit 0`，不自动拉起 GUI；MessageDisplay 路径尤其要快。

概念配置（安装器必须保留用户已有配置并幂等合并）：

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/agent-workspace-hook",
            "args": ["session-start"],
            "timeout": 1
          }
        ]
      }
    ],
    "FileChanged": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/agent-workspace-hook",
            "args": ["invalidate"],
            "async": true,
            "timeout": 1
          }
        ]
      }
    ],
    "MessageDisplay": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/agent-workspace-hook",
            "args": ["active"],
            "async": true,
            "timeout": 1
          }
        ]
      }
    ]
  }
}
```

`args` 使 command 采用 exec form，没有 shell 展开，降低路径与参数注入面；helper 从 stdin 读取 JSON。[Exec form and shell form](https://code.claude.com/docs/en/hooks#exec-form-and-shell-form)

## 安装范围与凭证边界

Claude 官方支持这些 Hook 位置：[Hook locations](https://code.claude.com/docs/en/hooks#hook-locations)

| 位置 | 范围 | 对 Agent Workspace 的判断 |
|---|---|---|
| `~/.claude/settings.json` | 当前用户所有项目 | 推荐：一次 opt-in 覆盖所有会话 |
| `.claude/settings.json` | 单项目，可提交 | 不推荐默认提交 app-specific command |
| `.claude/settings.local.json` | 单项目、本机、通常 gitignored | 适合试运行/单项目启用 |
| managed settings | 组织范围 | 由管理员控制 |
| plugin `hooks/hooks.json` | 插件启用期间 | 适合未来正式分发 |
| skill/agent frontmatter | 组件活跃期间 | 不适合全程会话同步 |

**可以在用户级或项目级安装，不需要也不应该触碰 Claude 登录。** macOS 上 Claude 凭证由 Claude Code 存在加密 Keychain；Hook 配置位于独立的 `settings.json`。[Credential management](https://code.claude.com/docs/en/authentication#credential-management) · [Settings files](https://code.claude.com/docs/en/settings#settings-files)

安装器的硬边界：

- 只编辑用户明确选择的 `settings.json`，保留已有 hooks、permissions、statusLine 和未知字段。
- 不调用 `/login`、`/logout`，不读写 Keychain，不改 auth 环境变量，不写 `apiKeyHelper`。
- 写前备份，使用结构化 JSON merge；用 command+args 作为稳定身份，重复安装不重复追加；卸载只删除自己的 handler。
- 对公开仓库，默认不要提交能在协作者机器上运行任意本地命令的 project Hook。

## 安全风险与控制

Anthropic 明确警告 command hooks 以当前系统用户的完整权限运行，能访问、修改或删除该用户可访问的文件。[Security considerations](https://code.claude.com/docs/en/hooks#security-considerations)

Agent Workspace helper 应满足：

- 固定绝对路径、exec form、无 shell、无 `eval`。
- 严格 JSON decode、输入大小上限、事件名 allowlist。
- `transcript_path` 做 canonicalize，验证归当前用户所有、是普通文件，并位于已知 Claude config roots；拒绝 `..`、符号链接逃逸和任意外部路径。
- 只连接权限收紧的本地 Unix socket；不向公网发送会话、环境变量或 Hook stdin。
- stdout/stderr 默认完全为空；任何 IPC 失败都 `exit 0`，不污染 Claude transcript。
- app 端合并失效信号并限流；不要按 MessageDisplay 每批启动昂贵解析或全文件重载。

## 最终建议

先实现 `SessionStart.watchPaths + FileChanged + incremental tailer`，这是最小、可解释、与 JSONL 唯一事实源一致的修复。随后添加 `MessageDisplay` 作为 working 状态与早到失效提示，再用 `Stop`/`StopFailure` 做最终校准；不要使用 `statusLine`，不要持久化 Hook `delta`，不要碰 Claude credentials。
