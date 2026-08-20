# 根因分析：为什么 Muse 在 opencode 能用、在 dsh 不能用

> 中文为主，附关键英文术语。英文版见 `../README.en.md` 的 Root cause 一节。

## 1. 一句话结论

`muse-spark-1.2-contributor` **只实现 OpenAI Responses 协议**，且多轮续接依赖把上一轮的 `reasoning` item（含 `encrypted_content`）**原样回传**。`dsh-llm-pi-ai` 的 `stream.ts` 在翻译 pi-ai 事件时丢掉了 `thinkingSignature`，导致多轮回传时网关拒绝请求。

## 2. 逆向过程（我们是怎么找到答案的）

### 2.1 为什么 opencode 能用

opencode 的模型目录不是内置的，而是运行时从 `https://models.opencode.ai/api.json` 拉取，缓存在 `~/.cache/opencode/models.json`（约 4 MB）。用 node 解析：

```
provider "opencode-go":
  id    = opencode-go
  npm   = @ai-sdk/openai-compatible
  api   = https://opencode.ai/zen/go/v1

model "muse-spark-1.2-contributor":
  provider.npm = @ai-sdk/openai      # ← 模型级覆盖为 OpenAI Responses SDK
  reasoning_options = [{ type: "effort", values: ["minimal","low","medium","high","xhigh"] }]
  limit = { context: 1048576, output: 131072 }
  modalities.input = [text, image, video, pdf, audio]
```

注意 `opencode-go` 这个 provider 默认是 `@ai-sdk/openai-compatible`（Chat Completions），但 **Muse 单独被标记为 `@ai-sdk/openai`（Responses）**——同一个网关、同一个 key、不同协议。这就是"在 opencode 能用"的机制：opencode 对每个模型按目录里声明的 npm SDK 选协议。

### 2.2 opencode 发出的请求体

对照 opencode 源码 `packages/opencode/src/provider/transform.ts`：

```ts
const INCLUDE_ENCRYPTED_REASONING = ["reasoning.encrypted_content"] as const

// 对 @ai-sdk/openai（responses）模型的 providerOptions：
{ reasoningEffort: effort, reasoningSummary: "auto", include: INCLUDE_ENCRYPTED_REASONING }
```

再加上 `store: false`。于是请求体为：

```jsonc
{
  "model": "muse-spark-1.2-contributor",
  "input": [...],
  "stream": true,
  "store": false,
  "reasoning": { "effort": "medium", "summary": "auto" },
  "include": ["reasoning.encrypted_content"]
}
```

返回的 `output` 形如：

```jsonc
[
  { "id": "rs_...", "type": "reasoning", "status": "completed", "encrypted_content": "...", "summary": [] },
  { "id": "msg_...", "type": "message", "role": "assistant",
    "content": [{ "type": "output_text", "text": "2+2 = **4**" }] }
]
```

下一轮把 `rs_...` 那个 item 原样塞回 `input`，`store:false` 下即完成无状态多轮。

### 2.3 dsh 里为什么会失败

`dsh-llm-pi-ai` 基于 `@earendil-works/pi-ai`。pi-ai 的 Responses 通道在 `response.output_item.done` 时把 reasoning item 存到内部块：

```js
// @earendil-works/pi-ai/dist/api/openai-responses-shared.js
slot.block.thinkingSignature = JSON.stringify(item)   // item = {type:"reasoning", id, encrypted_content, ...}
```

pi-ai 的流式事件（`thinking_end`）只携带 `content` 和 `partial`，**不带独立 signature 字段**——签名是挂在 `partial.content[contentIndex]` 这个真实块上的。

`dsh-llm-pi-ai` 的 `stream.ts` 处理 `thinking_end` 时用 `event.content` **新建块**，没去读真实块上的 `thinkingSignature`：

```ts
// 修复前：丢失 signature
case 'thinking_end':
  yield { type: 'block-end', index: event.contentIndex, block: { type: 'reasoning', text: event.content } }
```

结果：
- Harness 会话持久化的 assistant 消息里，thinking 块没有 `thinkingSignature`；
- `replay.ts` 的 `toPiReplayState` 读到无签名的块 → replay state 里也没有 reasoning 签名；
- 下一轮 `convertResponsesMessages` 只遇到 `type:"message"` 的 item，**没有 `type:"reasoning"` 的 item**；
- 网关（Console Go 的 Responses 实现）检测到缺失 reasoning 回传 → 400：`reasoning_content in the thinking mode must be passed back to the API`。

（`text_end` 同理：`textSignature`（responses 消息 id / phase）也被丢掉，影响 commentary/final_answer 的 phase 语义，一并修复。）

## 3. 其它已试通道为什么也不行

| 通道 | 结果 | 原因 |
| --- | --- | --- |
| `openai-completions`（`/v1/chat/completions`） | `message.content` 恒空、`finish_reason: null`、`completion_tokens` 被吞 | 网关对 Muse 的 chat/completions 兼容层有 bug：把全部 token 算成思考，不吐 content |
| `anthropic-messages`（`/v1/messages`） | `no content` 空回复 | 同上，Muse 并不真正实现 Anthropic 兼容 |
| `openai-responses` + 自定义 `assistantThinkingFormat: deepseek` | `input[N] did not match any supported type` | 该补丁把 assistant 消息改写成 `{role:"assistant", reasoning_content}`（无 `type` 字段），Responses 输入校验不认 |
| `openai-responses`（原始、正确） | ✅ 正常 | 协议正确 + `store:false` + 原样回传 reasoning item |

## 4. 修复清单

1. `dsh-llm-pi-ai/src/stream.ts`：`text_end` / `thinking_end` 从 `partial.content[contentIndex]` 带出 `textSignature` / `thinkingSignature`。见 `../patches/llm-pi-ai-stream-signature.patch`。
2. `~/.dsh/settings.yaml`：`api: openai-responses` + `baseURL: https://opencode.ai/zen/go/v1` + `reasoningEfforts` 用 `xhigh`（无 `max`）+ `input: [text, image]`（Muse 目录 `modalities.input` 含 image；不声明则 harness 拒绝图片上传）。见 `../config/settings.yaml.example`。
3. （可选）`dsh-llm-pi-ai/src/catalog.ts`：`off: null` 按协议区分——`openai-completions` 下 absent（发 `thinking:{type:"disabled"}`），`openai-responses` 下 `null`（省略 `reasoning` 块，因为网关拒绝字面量 `"none"`）。

## 5. 验证

- `scripts/verify_muse_first_turn.ps1`：首轮，验证返回 `reasoning(encrypted_content)` + `message(output_text)`。
- `scripts/verify_muse_multiturn.ps1`：第二轮回传上一轮 reasoning item，验证不再 400。
- GUI 实测：4 轮多轮（含 Max 档、工具调用、缓存命中 88%）全部成功。
