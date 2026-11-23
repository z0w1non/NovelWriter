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

Test-Case 'JSONのインデント方針' {
    foreach ($relativePath in @('config.example.json','default.json','data/default-user/sysprompt/planner.json','data/default-user/sysprompt/author.json','data/default-user/sysprompt/reviewer.json','data/default-user/sysprompt/summarizer.json')) {
        $path = Join-Path $projectRoot $relativePath
        $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        Assert-True ($content -notmatch '(?m)^\t') "$relativePath にタブインデントがあります。"
        foreach ($line in ($content -split "`r?`n")) {
            if ($line -match '^( +)\S') { Assert-True (($Matches[1].Length % 2) -eq 0) "$relativePath に2文字単位でないインデントがあります。" }
        }
    }
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
    Assert-True ($null -ne $defaults.PSObject.Properties['novel_prompt']) 'default.json の novel_prompt がありません。'
    foreach ($role in @('planner','author','reviewer')) {
        Assert-True ($null -ne $defaults.$role) "$role がありません。"
        Assert-True ($defaults.$role.system_prompt -eq $role) "$role の system_prompt が一致しません。"
    }
    Assert-True ($null -eq $defaults.PSObject.Properties['prompts']) '旧 prompts 配下が残っています。'
    Assert-True (-not [string]::IsNullOrWhiteSpace($defaults.json_retry.rejection)) 'json_retry.rejection が空です。'
    Assert-True (-not [string]::IsNullOrWhiteSpace($defaults.outline.max_tokens_instruction)) 'outline.max_tokens_instruction が空です。'
    Assert-True (-not [string]::IsNullOrWhiteSpace($defaults.json_retry.author)) '本文 JSON の再試行指示が空です。'
}

Test-Case 'planner の JSON 出力契約' {
    $prompt = Read-Json (Join-Path $projectRoot 'data/default-user/sysprompt/planner.json')
    Assert-True ($prompt.name -eq 'planner') 'planner の名前が不正です。'
    Assert-True ($prompt.content -match 'chapters') 'chapters の指示がありません。'
    Assert-True ($prompt.content -match 'elements') 'elements の指示がありません。'
    Assert-True ($prompt.content -notmatch 'number 属性') '廃止した number 属性の指示が残っています。'
}

Test-Case 'author と reviewer の sysprompt' {
    foreach ($role in @('author','reviewer')) {
        $prompt = Read-Json (Join-Path $projectRoot "data/default-user/sysprompt/$role.json")
        Assert-True ($prompt.name -eq $role) "$role の名前が不正です。"
        Assert-True (-not [string]::IsNullOrWhiteSpace($prompt.content)) "$role の content が空です。"
    }
    $author = Read-Json (Join-Path $projectRoot 'data/default-user/sysprompt/author.json')
    Assert-True ($author.content -match '繰り返したり要約し直したりしない') '章継続時の重複回避指示がありません。'
    $reviewer = Read-Json (Join-Path $projectRoot 'data/default-user/sysprompt/reviewer.json')
    Assert-True ($reviewer.content -match 'append' -and $reviewer.content -match 'rejection_reason' -and $reviewer.content -match '反復') '校閲 JSON 契約または反復検査の指示がありません。'
    Assert-True ($reviewer.content -match 'assistant ロールの直前メッセージ' -and $reviewer.content -match '校正対象の本文') '校正対象本文の入力構造が明記されていません。'
}

Test-Case 'Invoke-NovelWriter.ps1 の構文と主要契約' {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'Invoke-NovelWriter.ps1'), [ref]$null, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) 'PowerShell 構文エラーがあります。'
    $source = Get-Content -LiteralPath (Join-Path $projectRoot 'Invoke-NovelWriter.ps1') -Raw -Encoding UTF8
    Assert-True ($source -match 'chapter_complete') 'chapter_complete の処理がありません。'
    Assert-True ($source -match 'mes_example' -and $source -match 'example_dialogues') 'SillyTavernのSTARTタグJSON化処理がありません。'
    Assert-True ($source -match 'name = \$CharacterName') 'キャラクター名のJSON設定がありません。'
    Assert-True ($source -match 'repairedJsonText') '不正なJSONエスケープの補正処理がありません。'
    Assert-True ($source -match 'Extract-ModelJsonText' -and $source -match 'HtmlDecode' -and $source -match '\$normalized -match') '応答形式に依存しないJSON抽出処理がありません。'
    Assert-True ($source -notmatch 'channel>thought|channel\|') '特定の思考チャンネルへの依存が残っています。'
    Assert-True ($source -match 'inputContent' -and $source -match 'outputContent') 'Input/Outputの内容報告がありません。'
    Assert-True ($source -notmatch 'systemData' -and $source -match 'Format-PromptValue') 'system と user の入力構造が適切に分離されていません。'
    Assert-True ($source -match '\$requestData = \$Prompt \| ConvertFrom-Json' -and $source -match 'Format-PromptValue \$requestData') 'Input 構造のプレーンテキスト展開がありません。'
    Assert-True ($source -match 'Add-Member -NotePropertyName rejection_reason' -and $source -notmatch 'request\.rejection_reason') '棄却理由がトップレベル属性ではありません。'
    Assert-True ($source -notmatch 'role_prompt|\$Role\.prompt') '廃止した role_prompt が残っています。'
    Assert-True ($source -notmatch '\$userData\[\$property\] = \$characterData\.\$property') 'system側にあるキャラクター情報をInputへ重複転送しています。'
    Assert-True ($source -match 'モデルの応答を JSON として解析できません') 'JSON解析エラーの役割非依存メッセージがありません。'
    Assert-True ($source -notmatch '\[string\[\]\]\$Macro') 'Macro オプションが残っています。'
    Assert-True ($source -match 'novelConfig\.macros') 'novel-config の macros 読込がありません。'
    Assert-True ($source -match 'novelConfigCandidates') 'novel-configs のコマンドラインJSON探索がありません。'
    Assert-True ($source -match 'novelConfigInputWithExtension' -and $source -match 'GetExtension') 'Init/Continue の拡張子省略処理がありません。'
    Assert-True ($source -match 'effectiveJsonRetryLimit') 'Step -1 の例外継続捕捉がありません。'
    Assert-True ($source -match 'chapter_count') 'chapter_count の処理がありません。'
    Assert-True ($source -match "macroValues\['char'\]") 'char マクロの自動追加がありません。'
    Assert-True ($source -match 'rejectionFeedback' -and $source -match '校閲者の JSON に棄却理由') '校閲棄却の再執筆処理がありません。'
    Assert-True ($source -match 'includeRejectionFeedback' -and $source -match '\$includeRejectionFeedback = \$false') '棄却理由の適用範囲が管理されていません。'
    Assert-True ($source -match 'NotePropertyName rejection_reason' -and $source -match 'writerPromptDataForAttempt') '棄却理由の追加処理がありません。'
    Assert-True ($source -match '\$contextSummary' -and $source -match '\[System\.IO\.File\]::AppendAllText\(\$fullOutputPath, "\$separator\$polished') '要約・本文または成果物に棄却本文を混入させない構造がありません。'
    Assert-True ($source -notmatch '\$existing\s*\+=\s*\$draft' -and $source -notmatch '\$context\s*\+=\s*\$draft') '棄却本文をcontextへ追加しています。'
    Assert-True ($source -match 'approved=\$\{proofreadingReport\}' -and $source -match 'appended=\$\{appendReport\}' -and $source -match 'chapter_completed=\$\{chapterReport\}') '実行報告の項目が不足しています。'
    Assert-True ($source -notmatch '再試行します') '再試行報告が残っています。'
    Assert-True ($source -match 'approved=false' -and $source -match 'appended=false') '校閲棄却時の報告がありません。'
    Assert-True ($source -match '\$Step = 1' -and $source -match '\$Step -eq -1') 'Step オプションの処理がありません。'
    Assert-True ($source -match "role = 'system'" -and $source -match "role = 'user'") 'Chat API の role メッセージ構築がありません。'
    Assert-True ($source -match 'foreach \(\$property in \$Config\.override\.PSObject\.Properties\)') 'override の全属性転送がありません。'
    Assert-True ($source -match 'json_retry_limit') 'JSON 再試行設定の処理がありません。'
    Assert-True ($source -match 'outline\.json') 'outline.json の処理がありません。'
    Assert-True ($source -match 'outlineJsonText.*Format-JsonText') 'outline.json の整形処理がありません。'
    Assert-True ($source -match 'previousChapterJson' -and $source -match 'nextChapterJson') '前後章の受け渡しがありません。'
    Assert-True ($source -notmatch 'writerPromptData = .*outline' -and $source -notmatch 'draft = \$draft\r?\n\s*outline') '本文・校正プロンプトに全体構成が残っています。'
    Assert-True ($source -notmatch '(?m)^\s+chapter = \$chapterNumber') '廃止したJSONプロンプトのchapter属性が残っています。'
    Assert-True ($source -match 'availableContextCharacters' -and $source -match 'ContextText') 'Chat API の assistant メッセージとしてコンテキストを渡す処理がありません。'
    Assert-True ($source -match 'outlineMaxTokens' -and $source -match 'ResponseTokenOverride') '構成生成の最大応答トークン指定がありません。'
    Assert-True ($source -match 'outline\.max_tokens_instruction') '構成者への最大トークン数指示がありません。'
    Assert-True ($source -match 'writerPromptTokens' -and $source -match 'contextSize - \$responseTokens') 'context_size と応答長の関係がありません。'
    Assert-True ($source -match 'writerPromptData \| ConvertTo-Json -Depth 20 \| ForEach-Object') '本文プロンプトJSONの整形処理がありません。'
}

Write-Output "結果: $passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
