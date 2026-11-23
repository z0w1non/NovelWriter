[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$passed = 0
$failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:passed++
        Write-Output "PASS: $Name"
    } catch {
        $script:failed++
        Write-Output "FAIL: $Name - $($_.Exception.Message)"
    }
}

function Read-Json([string]$Path) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "ファイルがありません: $Path"
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

Test-Case 'config.json の KoboldCpp 設定' {
    $config = Read-Json (Join-Path $projectRoot 'config.json')
    Assert-True ($config.api_type -eq 'koboldcpp') 'api_type が koboldcpp ではありません。'
    Assert-True ($config.generate_path -eq '/v1/chat/completions') 'generate_path が KoboldCpp Chat API ではありません。'
    Assert-True ($null -ne $config.override) 'override 設定がありません。'
    Assert-True ($null -ne $config.PSObject.Properties['sillytavern_root']) 'sillytavern_root 設定がありません。'
    Assert-True ($null -ne $config.PSObject.Properties['sillytavern_user']) 'sillytavern_user 設定がありません。'
    Assert-True ([int]$config.json_retry_limit -ge -1) 'json_retry_limit が -1 未満です。'
    Assert-True ($config.api_server -match '^https?://') 'api_server が URL ではありません。'
    Assert-True ([int]$config.override.context_size -gt 0) 'override.context_size が不正です。'
}

Test-Case 'default.json の既定値' {
    $defaults = Read-Json (Join-Path $projectRoot 'default.json')
    Assert-True (($defaults.current_chapter -is [int] -or $defaults.current_chapter -is [long]) -and $defaults.current_chapter -eq 0) 'current_chapter が数値の 0 ではありません。'
    foreach ($role in @('outline_writer','writer','proofreader')) {
        Assert-True ($null -ne $defaults.$role) "$role がありません。"
        Assert-True ($defaults.$role.system_prompt -eq $role) "$role の system_prompt が一致しません。"
    }
    Assert-True ($null -eq $defaults.PSObject.Properties['prompts']) '旧 prompts 配下が残っています。'
    Assert-True (-not [string]::IsNullOrWhiteSpace($defaults.outline.max_tokens_instruction)) 'outline.max_tokens_instruction が空です。'
    Assert-True (-not [string]::IsNullOrWhiteSpace($defaults.json_retry.writer)) '本文 JSON の再試行指示が空です。'
}

Test-Case 'outline_writer の JSON 出力契約' {
    $prompt = Read-Json (Join-Path $projectRoot 'data/default-user/sysprompt/outline_writer.json')
    Assert-True ($prompt.name -eq 'outline_writer') 'outline_writer の名前が不正です。'
    Assert-True ($prompt.content -match 'chapters') 'chapters の指示がありません。'
    Assert-True ($prompt.content -match 'elements') 'elements の指示がありません。'
    Assert-True ($prompt.content -notmatch 'number 属性') '廃止した number 属性の指示が残っています。'
}

Test-Case 'writer と proofreader の sysprompt' {
    foreach ($role in @('writer','proofreader')) {
        $prompt = Read-Json (Join-Path $projectRoot "data/default-user/sysprompt/$role.json")
        Assert-True ($prompt.name -eq $role) "$role の名前が不正です。"
        Assert-True (-not [string]::IsNullOrWhiteSpace($prompt.content)) "$role の content が空です。"
    }
    $proofreader = Read-Json (Join-Path $projectRoot 'data/default-user/sysprompt/proofreader.json')
    Assert-True ($proofreader.content -match 'append' -and $proofreader.content -match 'rejection_reason' -and $proofreader.content -match '反復') '校正 JSON 契約または反復検査の指示がありません。'
}

Test-Case 'Invoke-NovelWriter.ps1 の構文と主要契約' {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'Invoke-NovelWriter.ps1'), [ref]$null, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) 'PowerShell 構文エラーがあります。'
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'Invoke-NovelWriter.ps1') -Raw -Encoding UTF8
    Assert-True ($source -match 'chapter_complete') 'chapter_complete の処理がありません。'
    Assert-True ($source -match 'repairedJsonText') '不正なJSONエスケープの補正処理がありません。'
    Assert-True ($source -notmatch '\[string\[\]\]\$Macro') 'Macro オプションが残っています。'
    Assert-True ($source -match 'novelConfig\.macros') 'novel-config の macros 読込がありません。'
    Assert-True ($source -match 'chapter_count') 'chapter_count の処理がありません。'
    Assert-True ($source -match "macroValues\['char'\]") 'char マクロの自動追加がありません。'
    Assert-True ($source -match 'rejectionFeedback' -and $source -match '校正者の JSON に棄却理由') '校正棄却の再執筆処理がありません。'
    Assert-True ($source -match '結果は\$\{proofreadingReport\}され' -and $source -match '\$appendReport' -and $source -match '章は\$\{chapterReport\}') '実行報告の項目が不足しています。'
    Assert-True ($source -notmatch '再試行します') '再試行報告が残っています。'
    Assert-True ($source -match '結果は棄却された') '校正棄却時の報告がありません。'
    Assert-True ($source -match '\$Step = 1' -and $source -match '\$Step -eq -1') 'Step オプションの処理がありません。'
    Assert-True ($source -match "role = 'system'" -and $source -match "role = 'user'") 'Chat API の role メッセージ構築がありません。'
    Assert-True ($source -match 'foreach \(\$property in \$Config\.override\.PSObject\.Properties\)') 'override の全属性転送がありません。'
    Assert-True ($source -match 'json_retry_limit') 'JSON 再試行設定の処理がありません。'
    Assert-True ($source -match 'outline\.json') 'outline.json の処理がありません。'
    Assert-True ($source -match 'outlineJsonText.*Format-JsonText') 'outline.json の整形処理がありません。'
    Assert-True ($source -match 'previousChapterJson' -and $source -match 'nextChapterJson') '前後章の受け渡しがありません。'
    Assert-True ($source -match 'chapter = \$chapterNumber') 'JSONプロンプトのchapterが0始まりではありません。'
    Assert-True ($source -match 'availableContextCharacters' -and $source -match 'context = \$context') 'コンテキスト容量の算出処理がありません。'
    Assert-True ($source -match 'outlineMaxTokens' -and $source -match 'ResponseTokenOverride') '構成生成の最大応答トークン指定がありません。'
    Assert-True ($source -match 'outline\.max_tokens_instruction') '構成者への最大トークン数指示がありません。'
    Assert-True ($source -match 'promptWithoutContextTokens' -and $source -match 'contextSize - \$responseTokens') 'context_size と応答長の関係がありません。'
}

Write-Output "結果: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
