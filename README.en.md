# Muse Spark via OpenCode Go in DeepSeek Harness (DSH)

> Make `muse-spark-1.2-contributor` (the OpenCode Zen Go gateway model) work correctly in DeepSeek Harness (`deepseek-harness` / `pi-ai`): first-turn output plus lossless multi-turn thinking replay.

> **Disclaimer**: This is a personal tech-sharing repo. It is **not** an official DeepSeek or opencode project and is unrelated to `deepseek-ai`, `sst/opencode`, or `opencode.ai`. Protocol/code analysis herein is based on public interfaces, for learning and personal use only.

| Item | Value |
| --- | --- |
| Model | `muse-spark-1.2-contributor` (Muse Spark 1.2 Contributor) |
| Gateway | OpenCode Zen Go — `https://opencode.ai/zen/go/v1` |
| Protocol (correct) | **OpenAI Responses API** (`openai-responses`) |
| Host | DeepSeek Harness (`deepseek-harness`), LLM layer `@deepseek-ai/dsh-llm-pi-ai` → `@earendil-works/pi-ai` |
| Status | ✅ Verified: multi-turn + thinking replay + tool calls + **image input** all work |

---

## 1. Symptoms

Adding `muse-spark-1.2-contributor` in `~/.dsh/settings.yaml` fails with different errors depending on the protocol you configure:

| Protocol configured | Symptom |
| --- | --- |
| `openai-completions` | `Stream ended without finish_reason` (stream truncated by gateway, `message.content` always empty) |
| `anthropic-messages` | `model returned a completed response with no content` (empty non-streaming reply) |
| `openai-responses` + a bad assistant patch | `input[5] did not match any supported type` (sent an input item Responses does not know) |
| `openai-responses` (stock), multi-turn | `reasoning_content in the thinking mode must be passed back to the API` |

Yet **in the official opencode client, Muse works fine.**

---

## 2. Why it works in opencode

opencode's model catalog comes from `https://models.opencode.ai/api.json` (cached locally at `~/.cache/opencode/models.json`):

```jsonc
// provider "opencode-go"
{
  "id": "opencode-go",
  "npm": "@ai-sdk/openai-compatible",
  "api": "https://opencode.ai/zen/go/v1"
}
// model "muse-spark-1.2-contributor"
{
  "provider": { "npm": "@ai-sdk/openai" },   // key: model-level override to the OpenAI Responses SDK
  "reasoning_options": [
    { "type": "effort", "values": ["minimal", "low", "medium", "high", "xhigh"] }
  ],
  "limit": { "context": 1048576, "output": 131072 }
}
```

**Muse only speaks the OpenAI Responses protocol** (model-level `@ai-sdk/openai`), not Chat Completions, not Anthropic. opencode sends:

```jsonc
{
  "model": "muse-spark-1.2-contributor",
  "input": [...],
  "stream": true,
  "store": false,                                   // stateless: multi-turn does not rely on a server-side session
  "reasoning": { "effort": "medium", "summary": "auto" },
  "include": ["reasoning.encrypted_content"]        // ask for the encrypted reasoning state
}
```

On the next turn opencode puts the previous turn's `reasoning` item (with `encrypted_content`) **verbatim back into `input`**, achieving stateless multi-turn continuation.

---

## 3. Root cause

`deepseek-harness` uses `@deepseek-ai/dsh-llm-pi-ai` (built on `@earendil-works/pi-ai`). On stream completion, pi-ai's Responses channel stores the reasoning item (with `encrypted_content`) on the internal block as `thinkingSignature`, for verbatim replay next turn:

```js
// @earendil-works/pi-ai/dist/api/openai-responses-shared.js (~line 598)
slot.block.thinkingSignature = JSON.stringify(item)   // item is {type:"reasoning", encrypted_content, ...}
```

But `dsh-llm-pi-ai`'s `src/stream.ts`, when translating pi-ai events into the Harness stream, **rebuilds a brand-new block from `event.content` and drops `thinkingSignature`**:

```ts
// before (signature lost)
case 'thinking_end':
  yield { type: 'block-end', index: event.contentIndex, block: { type: 'reasoning', text: event.content } }
```

So the assistant message persisted in the Harness session has no reasoning signature → on replay pi-ai finds no `thinkingSignature` → sends no reasoning item → the gateway rejects with `reasoning_content in the thinking mode must be passed back to the API`.

---

## 4. The fix

### 4.1 `dsh-llm-pi-ai/src/stream.ts` — preserve thinking/text signatures

Hoist the signature from `event.partial.content[event.contentIndex]` (the real, signature-carrying block pi-ai provides) into the Harness block:

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

> Note: `replay.ts` already knew how to serialize `textSignature` / `thinkingSignature` into the Harness replay state and restore them via `replayedAssistant` on the next turn. The gap was simply that `stream.ts` never fed the signatures in.

### 4.2 Configuration — Responses protocol + correct effort values

`~/.dsh/settings.yaml` (full example in [`config/settings.yaml.example`](config/settings.yaml.example)):

```yaml
llm-pi-ai:
  providers:
    opencode-go:
      apiKeyEnv: OPENCODE_GO_API_KEY
      models:
        - id: muse-spark-1.2-contributor
          name: Muse Spark 1.2 Contributor
          api: openai-responses              # ← required
          baseURL: https://opencode.ai/zen/go/v1
          contextWindow: 1048576
          maxTokens: 131072
          reasoningEfforts:
            off: null                        # responses channel: off = omit the reasoning block
            minimal: minimal
            low: low
            medium: medium
            high: high
            xhigh: xhigh                     # Muse supports xhigh (there is no max)
            max: xhigh
          input:
            - text
            - image                          # required, or the harness rejects image uploads
```

### 4.3 Anti-patterns

- ❌ Do not use `api: openai-completions` or `api: anthropic-messages` — Muse only speaks Responses.
- ❌ Do not patch Muse with `compat.assistantThinkingFormat: deepseek` to rewrite assistant messages as `{role:"assistant", reasoning_content}` — the Responses endpoint rejects that with `input[N] did not match any supported type`.
- ⚠️ `off: null` semantics differ by protocol: under `openai-completions` it sends `thinking:{type:"disabled"}`; under `openai-responses` it omits the whole `reasoning` block (the gateway rejects the literal `"none"`).

---

## 5. Verification

```bash
# environment variable (or substitute your key)
export OPENCODE_GO_API_KEY=...

# 1) First turn: should return reasoning(encrypted_content) + message(output_text)
powershell -File scripts/verify_muse_first_turn.ps1

# 2) Multi-turn: replay the previous turn's reasoning item, should return a proper answer
powershell -File scripts/verify_muse_multiturn.ps1
```

Measured results (from this repo's verification):

| Turn | Request | Reply |
| --- | --- | --- |
| 1 | `2+2=?` | `2+2 = **4**` |
| 2 | `再加 1 等于几？` | `5` |
| 3 (Max) | `9+9=?` | `18` |
| 4 (Max) | `再加 1 等于几？` | `19` |
| image | upload red PNG, `what color?` | `red` |

A session including tool calls and repeated "continue" turns: 4 turns · 9 steps · 88% cache hit · all successful. Image input is verified too (Muse recognized the red swatch).

---

## 6. Files

```
muse-dsh-fix/
├── README.md                  # this file (zh/en)
├── README.en.md               # English version
├── docs/
│   └── root-cause.md          # root-cause analysis (full reverse-engineering of opencode)
├── config/
│   └── settings.yaml.example  # ready-to-use config example
├── scripts/
│   ├── verify_muse_first_turn.ps1   # first-turn verification (curl)
│   └── verify_muse_multiturn.ps1    # multi-turn thinking-replay verification (curl)
├── patches/
│   └── llm-pi-ai-stream-signature.patch  # stream.ts fix patch
└── LICENSE                    # MIT
```

---

## 7. Version scope

| Component | Version |
| --- | --- |
| `@deepseek-ai/dsh-llm-pi-ai` | 0.1.0-rc.7 |
| `@earendil-works/pi-ai` | 0.82.x |
| OpenCode Zen Go gateway | 2026-08 (Muse Spark 1.2 Contributor, released 2026-08-05) |

> If an upstream upgrade makes this issue disappear (e.g. pi-ai/dsh fixes `thinkingSignature` passthrough), this repo is archived as historical record.

---

## License

[MIT](LICENSE)
