# patches/

这两个补丁是对 `deepseek-harness` 仓库（`packages/llm/llm-pi-ai`）的最小改动。用 `git apply` 应用，或用下面的说明手工修改。

> **版本锚点 / Version anchor**: 补丁基于 `deepseek-harness` commit `99f6f02fec`（`release/dsh-0.1.0-rc.7`）生成，`git apply` 验证干净。若你的 checkout 已前进导致 `git apply` 报 `patch failed`，改用 `git apply --3way` 或手工按说明修改。
> The patches are generated against `deepseek-harness` commit `99f6f02fec` (`release/dsh-0.1.0-rc.7`) and apply cleanly. If your checkout is ahead and `git apply` reports `patch failed`, use `git apply --3way` or hand-apply per the notes.

## 1. `llm-pi-ai-stream-signature.patch` — 修复多轮 thinking 回传 (fixes multi-turn replay)

**文件 / File**: `packages/llm/llm-pi-ai/src/stream.ts`

**问题 / Problem**: `text_end` / `thinking_end` 事件用 `event.content` 重建块，丢掉了 pi-ai 存在真实块上的 `textSignature` / `thinkingSignature`（后者含 `encrypted_content` 的 reasoning item）。导致下一轮回传没有 reasoning item，网关 400。

**修复 / Fix**: 新增 `blockSignature` 辅助函数，从 `event.partial.content[event.contentIndex]` 读取签名并写进 Harness 块，使 `replay.ts` 能持久化、下轮原样回传。

```bash
git apply patches/llm-pi-ai-stream-signature.patch
```

## 2. `llm-pi-ai-catalog-off-null.patch` — `off: null` 按协议区分 (protocol-aware `off: null`)

**文件 / File**: `packages/llm/llm-pi-ai/src/catalog.ts`, `packages/llm/llm-pi-ai/src/config.ts`

**问题 / Problem**: `reasoningEfforts: { off: null, ... }` 在 `openai-completions` 下应保持 `off` 档（发 `thinking:{type:"disabled"}`），但在 `openai-responses` 下必须让 `off` 落到 `null`（省略整个 `reasoning` 块），否则网关收到字面量 `"none"` 报错。同时为 `openai-responses` 增加 `compat.assistantThinkingFormat` 兼容字段声明（默认 `openai`，仅做透传）。

> ⚠️ 说明：`assistantThinkingFormat: deepseek` 是**反模式**（会导致 `input[N] did not match any supported type`）。此补丁只新增字段声明与协议校验，不应在配置里使用 `deepseek` 值。
> Note: `assistantThinkingFormat: deepseek` is an **anti-pattern** (it causes `input[N] did not match any supported type`). This patch only declares the field and protocol validation; do not use the `deepseek` value in config.

```bash
git apply patches/llm-pi-ai-catalog-off-null.patch
```

## 应用后 / After applying

```bash
cd deepseek-harness
pnpm install          # 若 patch 改变了依赖解析
pnpm run dev:web      # 或你的 dsh 启动方式
```

然后按 `config/settings.yaml.example` 配置 Muse，运行 `scripts/` 下的验证脚本。
