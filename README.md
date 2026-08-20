# Muse Spark via OpenCode Go in DeepSeek Harness (DSH)

> 让 `muse-spark-1.2-contributor`（OpenCode Zen Go 网关）在 DeepSeek Harness（`deepseek-harness` / `pi-ai`）里正确工作：首轮出内容 + 多轮 thinking 回传不报错。
>
> Make `muse-spark-1.2-contributor` (the OpenCode Zen Go gateway model) work correctly in DeepSeek Harness (`deepseek-harness` / `pi-ai`): first-turn output plus lossless multi-turn thinking replay.

| 项目 | 值 |
| --- | --- |
| 模型 | `muse-spark-1.2-contributor` (Muse Spark 1.2 Contributor) |
| 网关 | OpenCode Zen Go — `https://opencode.ai/zen/go/v1` |
| 协议（正确） | **OpenAI Responses API** (`openai-responses`) |
| 宿主 | DeepSeek Harness (`deepseek-harness`), LLM 适配层 `@deepseek-ai/dsh-llm-pi-ai` → `@earendil-works/pi-ai` |
| 状态 | ✅ 已验证：多轮 + thinking 回传 + 工具调用 + **图片输入** 正常 |

---

## 一、问题现象 / Symptoms

在 `~/.dsh/settings.yaml` 里用 `muse-spark-1.2-contributor`，无论怎么配都会遇到下列错误之一：

| 配置的协议 | 现象 |
| --- | --- |
| `openai-completions` | `Stream ended without finish_reason`（流被网关截断，`message.content` 恒为空） |
| `anthropic-messages` | `model returned a completed response with no content`（非流式空回复） |
| `openai-responses` + 错误的 assistant 补丁 | `input[5] did not match any supported type`（发了 responses 不认识的输入项） |
| `openai-responses`（原始）多轮 | `reasoning_content in the thinking mode must be passed back to the API` |

而 **在 opencode 官方客户端里，Muse 完全正常**。

---

## 二、为什么 opencode 能用 / Why it works in opencode

opencode 的模型目录来自 `https://models.opencode.ai/api.json`（本地缓存在 `~/.cache/opencode/models.json`）。其中：

```jsonc
// provider "opencode-go"
{
  "id": "opencode-go",
  "npm": "@ai-sdk/openai-compatible",
  "api": "https://opencode.ai/zen/go/v1"
}
// model "muse-spark-1.2-contributor"
{
  "provider": { "npm": "@ai-sdk/openai" },   // ← 关键：模型级覆盖为 OpenAI Responses SDK
  "reasoning_options": [
    { "type": "effort", "values": ["minimal", "low", "medium", "high", "xhigh"] }
  ],
  "limit": { "context": 1048576, "output": 131072 }
}
```

**Muse 只认 OpenAI Responses 协议**（模型级 `@ai-sdk/openai`），不是 Chat Completions、也不是 Anthropic。opencode 发出的请求体：

```jsonc
{
  "model": "muse-spark-1.2-contributor",
  "input": [...],
  "stream": true,
  "store": false,                                   // 无状态：多轮不依赖服务端存 session
  "reasoning": { "effort": "medium", "summary": "auto" },
  "include": ["reasoning.encrypted_content"]        // 请求返回加密 reasoning 状态
}
```

多轮时，opencode 把上一轮返回的 `reasoning` item（含 `encrypted_content`）**原样放回 `input`**，实现无状态多轮续接。

---

## 三、根因 / Root cause

`deepseek-harness` 走的是 `@deepseek-ai/dsh-llm-pi-ai`（基于 `@earendil-works/pi-ai`）。pi-ai 的 Responses 通道在**流式收尾时**会把 reasoning item（含 `encrypted_content`）存到内部块上的 `thinkingSignature` 字段，供下一轮原样回传：

```js
// @earendil-works/pi-ai/dist/api/openai-responses-shared.js（约 598 行）
slot.block.thinkingSignature = JSON.stringify(item)   // item 即 {type:"reasoning", encrypted_content, ...}
```

但 `dsh-llm-pi-ai` 的 `src/stream.ts` 在把 pi-ai 事件翻译成 Harness 流时，**用 `event.content` 重建了一个全新的块，把 `thinkingSignature` 丢掉了**：

```ts
// 修复前（丢失 signature）
case 'thinking_end':
  yield { type: 'block-end', index: event.contentIndex, block: { type: 'reasoning', text: event.content } }
```

于是 Harness 会话里存的 assistant 消息没有 reasoning 签名 → 下一轮回传时 pi-ai 找不到 `thinkingSignature` → 不发 reasoning item → 网关拒绝：`reasoning_content in the thinking mode must be passed back to the API`。

---

## 四、修复 / The fix

### 4.1 `dsh-llm-pi-ai/src/stream.ts` — 保留 thinking/text 签名

从 `event.partial.content[event.contentIndex]`（pi-ai 提供的、带签名的真实块）上把签名带出来，写进 Harness 块：

```ts
function blockSignature(
  event: { contentIndex: number; partial: AssistantMessage },
  key: 'textSignature' | 'thinkingSignature',
): string | undefined {
  const block = event.partial.content[event.contentIndex]
  if (block === undefined) return undefined
  const signature = key === 'textSignature' && block.type === 'text'
    ? block.textSignature
    : key === 'thinkingSignature' && block.type === 'thinking'
      ? block.thinkingSignature
      : undefined
  return typeof signature === 'string' ? signature : undefined
}

// text_end
case 'text_end':
  yield {
    type: 'block-end', index: event.contentIndex,
    block: {
      type: 'text', text: event.content,
      ...blockSignature(event, 'textSignature') !== undefined
        ? { textSignature: blockSignature(event, 'textSignature') } : {},
    },
  }
  break

// thinking_end
case 'thinking_end':
  yield {
    type: 'block-end', index: event.contentIndex,
    block: {
      type: 'reasoning', text: event.content,
      ...blockSignature(event, 'thinkingSignature') !== undefined
        ? { thinkingSignature: blockSignature(event, 'thinkingSignature') } : {},
    },
  }
  break
```

> 说明：`replay.ts` 早已支持把 `textSignature` / `thinkingSignature` 写入 Harness 的 replay state，并在下轮经 `replayedAssistant` 还原。之前只是 `stream.ts` 没把签名喂进去。

### 4.2 配置 — 用 Responses 协议 + 正确的 effort 值

`~/.dsh/settings.yaml`（完整示例见 [`config/settings.yaml.example`](config/settings.yaml.example)）：

```yaml
llm-pi-ai:
  providers:
    opencode-go:
      apiKeyEnv: OPENCODE_GO_API_KEY
      models:
        - id: muse-spark-1.2-contributor
          name: Muse Spark 1.2 Contributor
          api: openai-responses              # ← 必须
          baseURL: https://opencode.ai/zen/go/v1
          contextWindow: 1048576
          maxTokens: 131072
          reasoningEfforts:
            off: null                        # responses 通道：off = 省略 reasoning 块
            minimal: minimal
            low: low
            medium: medium
            high: high
            xhigh: xhigh                     # Muse 支持 xhigh（没有 max）
            max: xhigh
          input:
            - text
            - image                          # 必须声明，否则 harness 拒绝图片上传
```

### 4.3 反模式（勿用） / Anti-patterns

- ❌ 不要用 `api: openai-completions` 或 `api: anthropic-messages` —— Muse 只认 Responses。
- ❌ 不要给 Muse 加 `compat.assistantThinkingFormat: deepseek` 之类的补丁，把 assistant 消息改写成 `{role:"assistant", reasoning_content}` —— Responses 端点会报 `input[N] did not match any supported type`。
- ⚠️ `off: null` 的语义按协议区分：`openai-completions` 下它发 `thinking:{type:"disabled"}`；`openai-responses` 下它省略整个 `reasoning` 块（网关不接受字面量 `"none"`）。

---

## 五、验证 / Verification

```bash
# 环境变量（或换成你的 key）
export OPENCODE_GO_API_KEY=...

# 1) 首轮：应返回 reasoning(encrypted_content) + message(output_text)
powershell -File scripts/verify_muse_first_turn.ps1

# 2) 多轮：第二轮回传上一轮的 reasoning item，应返回正常答案
powershell -File scripts/verify_muse_multiturn.ps1
```

实测结果（本工程验证）：

| 轮次 | 请求 | 回复 |
| --- | --- | --- |
| 1 | `2+2=?` | `2+2 = **4**` |
| 2 | `再加 1 等于几？` | `5` |
| 3 (Max) | `9+9=?` | `18` |
| 4 (Max) | `再加 1 等于几？` | `19` |
| 图 1 | 上传红色 PNG，`这是什么颜色？` | `红色` |

含工具调用与多轮"继续"的完整会话：4 轮 · 9 步 · 缓存命中 88% · 全部成功。图片输入也已实测（Muse 识别红色色块）。

---

## 六、相关文件 / Files

```
muse-dsh-fix/
├── README.md                  # 本文件（中英）
├── README.en.md               # 英文版
├── docs/
│   └── root-cause.md          # 根因分析（逆向 opencode 的完整过程）
├── config/
│   └── settings.yaml.example  # 可直接使用的配置示例
├── scripts/
│   ├── verify_muse_first_turn.ps1   # 首轮验证（curl）
│   └── verify_muse_multiturn.ps1    # 多轮 thinking 回传验证（curl）
├── patches/
│   └── llm-pi-ai-stream-signature.patch  # stream.ts 的修复补丁
└── LICENSE                    # MIT
```

---

## 七、适用版本 / Version scope

| 组件 | 版本 |
| --- | --- |
| `@deepseek-ai/dsh-llm-pi-ai` | 0.1.0-rc.7 |
| `@earendil-works/pi-ai` | 0.82.x |
| OpenCode Zen Go 网关 | 2026-08（Muse Spark 1.2 Contributor, released 2026-08-05） |

> 若 pi-ai / dsh 升级后该问题消失（上游可能已修复 `thinkingSignature` 透传），本仓库将归档为历史记录。

---

## License

[MIT](LICENSE)
