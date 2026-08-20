# =============================================================================
# verify_muse_first_turn.ps1
# 首轮验证：确认 Muse 在 Responses 协议下返回 reasoning + message content。
# First-turn verification: confirm Muse returns reasoning + message content.
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
Write-Host "Using key length: $($key.Length)" -ForegroundColor Cyan

$body = @{
  model   = 'muse-spark-1.2-contributor'
  input   = @(
    @{
      role    = 'user'
      content = @(
        @{ type = 'input_text'; text = '2+2=? 只回答数字。' }
      )
    }
  )
  stream  = $false
  store   = $false
  reasoning = @{ effort = 'medium'; summary = 'auto' }
  include = @('reasoning.encrypted_content')
} | ConvertTo-Json -Depth 10

Write-Host 'POST https://opencode.ai/zen/go/v1/responses ...' -ForegroundColor Cyan
$resp = Invoke-WebRequest -Uri 'https://opencode.ai/zen/go/v1/responses' -Method Post `
  -Headers @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' } `
  -Body $body -UseBasicParsing

$json = $resp.Content | ConvertFrom-Json

$reasoning = $json.output | Where-Object { $_.type -eq 'reasoning' } | Select-Object -First 1
$message   = $json.output | Where-Object { $_.type -eq 'message' } | Select-Object -First 1

if (-not $reasoning) { throw 'FAIL: no reasoning item in output (gateway did not think?)' }
if (-not $reasoning.encrypted_content) { throw 'FAIL: reasoning item has no encrypted_content' }
if (-not $message) { throw 'FAIL: no message item in output' }
$text = ($message.content | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text }) -join ''
if (-not $text) { throw 'FAIL: message item has empty text' }

Write-Host "PASS" -ForegroundColor Green
Write-Host "  reasoning.encrypted_content len : $($reasoning.encrypted_content.Length)"
Write-Host "  reasoning.summary              : $(($reasoning.summary | ConvertTo-Json -Compress))"
Write-Host "  message output_text            : $text"
Write-Host "  status                         : $($json.status)"
