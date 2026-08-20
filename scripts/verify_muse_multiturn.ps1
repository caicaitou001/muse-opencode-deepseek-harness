# =============================================================================
# verify_muse_multiturn.ps1
# 多轮验证：第一轮拿到 reasoning item（含 encrypted_content），第二轮回传它，
# 确认不再报 `reasoning_content must be passed back`，且能正常回答。
# Multi-turn verification: take turn 1's reasoning item (with encrypted_content),
# replay it verbatim on turn 2, and confirm the gateway no longer rejects the turn.
#
# 这模拟 opencode 的 @ai-sdk/openai 无状态多轮（store:false）回传方式。
# This mirrors opencode's @ai-sdk/openai stateless (store:false) replay.
#
# 前置 / Prereqs:
#   - OPENCODE_GO_API_KEY 环境变量（或 ~/.dsh/.credentials.yaml 中的值）
#   - PowerShell 5.1+
# =============================================================================
$ErrorActionPreference = 'Stop'

function Get-Key {
  $envKey = $env:OPENCODE_GO_API_KEY
  if ($envKey) { return $envKey }
  $credPath = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
  if (Test-Path $credPath) {
    $match = Select-String -Path $credPath -Pattern 'OPENCODE_GO_API_KEY:\s*"?([^"\s]+)' | Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
  }
  throw 'OPENCODE_GO_API_KEY not found (set env var or ~/.dsh/.credentials.yaml)'
}

$key = Get-Key
$uri = 'https://opencode.ai/zen/go/v1/responses'
$headers = @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' }

function Invoke-Response($inputItems, [string]$label) {
  $body = @{
    model   = 'muse-spark-1.2-contributor'
    input   = $inputItems
    stream  = $false
    store   = $false
    reasoning = @{ effort = 'medium'; summary = 'auto' }
    include = @('reasoning.encrypted_content')
  } | ConvertTo-Json -Depth 12
  Write-Host "--- $label ---" -ForegroundColor Cyan
  $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body -UseBasicParsing
  return ($resp.Content | ConvertFrom-Json)
}

# ---- Turn 1 ----
$t1 = Invoke-Response @(
  @{ role = 'user'; content = @(@{ type = 'input_text'; text = '3+5=? 只回答数字。' }) }
) 'Turn 1'

$reasoning1 = $t1.output | Where-Object { $_.type -eq 'reasoning' } | Select-Object -First 1
$msg1 = $t1.output | Where-Object { $_.type -eq 'message' } | Select-Object -First 1
if (-not $reasoning1) { throw 'FAIL: turn 1 produced no reasoning item' }
$text1 = ($msg1.content | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text }) -join ''
Write-Host "Turn 1 reasoning id  : $($reasoning1.id)"
Write-Host "Turn 1 answer        : $text1"

# ---- Turn 2: replay the reasoning item verbatim ----
# 与 opencode 一致：把上一轮的 reasoning item 原样塞回 input。
# Same as opencode: put the previous reasoning item back verbatim.
$t2 = Invoke-Response @(
  @{ role = 'user'; content = @(@{ type = 'input_text'; text = '3+5=? 只回答数字。' }) },
  $reasoning1,
  @{
    role    = 'user'
    content = @(@{ type = 'input_text'; text = '再加 2 等于几？只回答数字。' })
  }
) 'Turn 2 (with reasoning replay)'

$msg2 = $t2.output | Where-Object { $_.type -eq 'message' } | Select-Object -First 1
if (-not $msg2) { throw 'FAIL: turn 2 returned no message item' }
$text2 = ($msg2.content | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text }) -join ''
if (-not $text2) { throw 'FAIL: turn 2 message is empty' }

Write-Host "Turn 2 answer        : $text2" -ForegroundColor Green
Write-Host "PASS: multi-turn reasoning replay works (no reasoning_content 400)" -ForegroundColor Green
