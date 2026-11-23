[CmdletBinding()]
param(
    [Parameter(ParameterSetName='New', Mandatory=$true)]
    [string]$New,
    [Parameter(ParameterSetName='Plan', Mandatory=$true)]
    [string]$Plan,
    [Parameter(ParameterSetName='Write', Mandatory=$true)]
    [string]$Write,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$DefaultPath = (Join-Path $PSScriptRoot 'default.json'),
    [int]$Step = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-TextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "ファイルが見つかりません: $Path" }
    return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path), [Text.Encoding]::UTF8)
}

function Normalize-ModelText([string]$Text) {
    return [System.Net.WebUtility]::HtmlDecode([string]$Text).Trim()
}

function Extract-ModelJsonText([string]$Text) {
    $normalized = Normalize-ModelText $Text
    if ($normalized -match '(?s)^```(?:json)?\s*(.*?)\s*```$') { return $Matches[1].Trim() }
    if ($normalized -match '(?s)(\{.*\})') { return $Matches[1].Trim() }
    return $normalized
}

function Convert-ModelJson([string]$Text) {
    $jsonText = Extract-ModelJsonText $Text
    try { return $jsonText | ConvertFrom-Json } catch {
        $repairedJsonText = [regex]::Replace($jsonText, '\\(?!["\\/bfnrtu])', '\\\\')
        try { return $repairedJsonText | ConvertFrom-Json } catch { throw "モデルの応答を JSON として解析できません: $($_.Exception.Message)" }
    }
}

function Convert-OutlineResponse([string]$Text) {
    try {
        $json = Convert-ModelJson $Text
        if ($null -ne $json.chapters) { return $json }
    } catch { }
    $lines = (Normalize-ModelText $Text) -split "`r?`n"
    $chapters = @()
    $chapter = $null
    $section = ''
    foreach ($line in $lines) {
        if ($line -match '^##\s+(.+?)\s*$') {
            if ($null -ne $chapter) { $chapters += [pscustomobject]$chapter }
            $chapter = [ordered]@{ title = $Matches[1].Trim(); summary = ''; elements = @() }
            $section = ''
            continue
        }
        if ($null -eq $chapter) { continue }
        if ($line -match '^###\s+要素\s*$') { $section = 'elements'; continue }
        if ($line -match '^###\s+概要\s*$') { $section = 'summary'; continue }
        if ($line -match '^###\s+') { $section = ''; continue }
        if ($section -eq 'elements' -and $line -match '^\s*[-*]\s+(.+?)\s*$') { $chapter.elements += $Matches[1].Trim(); continue }
        if ($section -eq 'summary' -and -not [string]::IsNullOrWhiteSpace($line)) { $chapter.summary += $(if ($chapter.summary) { "`r`n" } else { '' }) + $line.Trim() }
    }
    if ($null -ne $chapter) { $chapters += [pscustomobject]$chapter }
    if ($chapters.Count -eq 0) { throw '構成作成者の出力から章を解析できません。' }
    return [pscustomobject]@{ chapters = $chapters }
}

function Format-PromptValue([object]$Value, [int]$Indent = 0) {
    $prefix = ' ' * $Indent
    if ($null -eq $Value) { return "${prefix}(なし)" }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $lines = @()
        foreach ($property in $Value.PSObject.Properties) {
            $heading = switch ($property.Name) {
                'novel_prompt' { '小説設定' }
                'chapter_count' { '章数' }
                'name' { '名前' }
                'description' { '説明' }
                'personality' { '性格' }
                'scenario' { '状況' }
                'first_mes' { '初回メッセージ' }
                'post_history_instructions' { '履歴後の指示' }
                'example_dialogues' { '例示会話' }
                'previous_chapter' { '前章計画' }
                'current_chapter' { '現在章計画' }
                'next_chapter' { '次章計画' }
                'summary_size' { '要約目標トークン数' }
                'rejection_reason' { '校閲からの修正要求' }
                'retry_instruction' { '再試行指示' }
                'summary' { '過去本文の要約' }
                'title' { '章タイトル' }
                'elements' { '章の要素' }
                'body' { '本文' }
                'chapter_complete' { '章完了' }
                default { [string]$property.Name }
            }
            $level = if ($Indent -eq 0) { '##' } else { '###' }
            if ($lines.Count -gt 0) { $lines += '' }
            $lines += "${prefix}${level} $heading"
            $lines += Format-PromptValue $property.Value ($Indent + 2)
        }
        return $lines -join "`r`n"
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $lines = @()
        foreach ($item in $Value) { $lines += "${prefix}- $((Format-PromptValue $item 0).Trim())" }
        return $lines -join "`r`n"
    }
    return "${prefix}$Value"
}

function Format-JsonText([string]$JsonText) {
    $level = 0
    $lines = @()
    foreach ($line in ($JsonText -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('}') -or $trimmed.StartsWith(']')) { $level = [Math]::Max(0, $level - 1) }
        $trimmed = $trimmed -replace '^("[^\"]+"\s*):\s+', '$1: '
        $lines += ('  ' * $level) + $trimmed
        if ($trimmed.EndsWith('{') -or $trimmed.EndsWith('[')) { $level++ }
    }
    return ($lines -join "`r`n")
}

function Test-RetryAllowed([int]$RetryCount, [int]$RetryLimit) {
    return ($RetryLimit -eq -1 -or $RetryCount -lt $RetryLimit)
}

function Expand-Macros([string]$Text, [hashtable]$MacroValues) {
    $result = $Text
    foreach ($key in $MacroValues.Keys) { $result = $result.Replace("{{$key}}", [string]$MacroValues[$key]) }
    return $result
}

function Read-JsonResource([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "SillyTavern のリソースが見つかりません: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-StResource([object]$Config, [string]$RelativeDirectory, [string]$Name, [string[]]$Extensions) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $bases = @(
        (Join-Path (Join-Path (Join-Path $PSScriptRoot 'data') $Config.sillytavern_user) $RelativeDirectory),
        (Join-Path (Join-Path (Join-Path $Config.sillytavern_root 'data') $Config.sillytavern_user) $RelativeDirectory)
    )
    $candidates = @($Name)
    foreach ($extension in $Extensions) { $candidates += "$Name$extension" }
    foreach ($base in $bases) {
        foreach ($candidate in $candidates) {
            $path = Join-Path $base $candidate
            if (Test-Path -LiteralPath $path -PathType Leaf) { return (Resolve-Path -LiteralPath $path).Path }
        }
    }
    throw "リソース '$Name' が見つかりません。検索先: $($bases -join ', ')"
}

function Read-StTextResource([object]$Config, [string]$Directory, [string]$Name) {
    $path = Resolve-StResource $Config $Directory $Name @('.txt','.json')
    if ($path.EndsWith('.txt')) { return Read-TextFile $path }
    $resource = Read-JsonResource $path
    foreach ($property in @('content','description','prompt','text')) {
        if ($null -ne $resource.PSObject.Properties[$property]) { return [string]$resource.$property }
    }
    return Format-PromptValue $resource
}

function Convert-StCharacterData([object]$Data, [string]$CharacterName) {
    $characterObject = [ordered]@{ name = $CharacterName }
    foreach ($property in @('description','personality','scenario','first_mes','system_prompt','post_history_instructions')) {
        if ($null -ne $Data.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace([string]$Data.$property)) { $characterObject[$property] = [string]$Data.$property }
    }
    if ($null -ne $Data.PSObject.Properties['mes_example'] -and -not [string]::IsNullOrWhiteSpace([string]$Data.mes_example)) {
        $characterObject.example_dialogues = @([regex]::Split([string]$Data.mes_example, '(?im)^\s*<START>\s*$') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    }
    return Format-PromptValue ([pscustomobject]$characterObject)
}

function Read-StCharacter([object]$Config, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $path = Resolve-StResource $Config 'characters' $Name @('.json','.png')
    if ($path.EndsWith('.json')) {
        $resource = Read-JsonResource $path
        $data = if ($null -ne $resource.data) { $resource.data } else { $resource }
        return Convert-StCharacterData $data $Name
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $offset = 8
    while ($offset + 12 -le $bytes.Length) {
        $length = [System.BitConverter]::ToUInt32(@($bytes[$offset+3],$bytes[$offset+2],$bytes[$offset+1],$bytes[$offset]), 0)
        $type = [Text.Encoding]::ASCII.GetString($bytes, $offset + 4, 4)
        if ($type -eq 'tEXt' -or $type -eq 'iTXt') {
            $chunk = [Text.Encoding]::ASCII.GetString($bytes, $offset + 8, [int]$length)
            if ($chunk.StartsWith('chara' + [char]0)) {
                $encoded = $chunk.Substring(6)
                $data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
                $data = if ($null -ne $data.data) { $data.data } else { $data }
                return Convert-StCharacterData $data $Name
            }
        }
        $offset += 12 + [int]$length
    }
    throw "PNG キャラクターカード '$Name' に chara データがありません: $path"
}

function Invoke-KoboldCpp([object]$Config, [string]$Prompt, [hashtable]$MacroValues, [string]$CharacterText, [string]$PersonaText, [string]$SystemText, [string]$InstructionText = '', [int]$ResponseTokenOverride = 0, [string]$ContextText = '', [string]$UserSuffix = '') {
    $uri = "$($Config.api_server.TrimEnd('/'))$($Config.generate_path)"
    $systemContent = (@($SystemText, $InstructionText, $PersonaText, $CharacterText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n`r`n"
    $requestData = $Prompt | ConvertFrom-Json
    $userContent = Format-PromptValue $requestData
    if (-not [string]::IsNullOrWhiteSpace($UserSuffix)) { $userContent += "`r`n`r`n$UserSuffix" }
    $messages = @()
    if (-not [string]::IsNullOrWhiteSpace($systemContent)) { $messages += @{ role = 'system'; content = (Expand-Macros $systemContent $MacroValues) } }
    if (-not [string]::IsNullOrWhiteSpace($ContextText)) { $messages += @{ role = 'assistant'; content = (Expand-Macros $ContextText $MacroValues) } }
    $messages += @{ role = 'user'; content = (Expand-Macros $userContent $MacroValues) }
    $bodyObject = @{ messages = $messages; stream = $false }
    if ($null -ne $Config.override) {
        foreach ($property in $Config.override.PSObject.Properties) {
            $bodyObject[$property.Name] = $property.Value
        }
    }
    if ($ResponseTokenOverride -gt 0) { $bodyObject.max_tokens = $ResponseTokenOverride }
    $body = $bodyObject | ConvertTo-Json -Depth 5
    $inputContent = @($messages | ForEach-Object { [string]$_.content }) -join "`r`n`r`n"
    Write-Host 'Input:' -ForegroundColor Cyan
    Write-Host $inputContent -ForegroundColor DarkCyan
    $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $body
    $text = if ($null -ne $response.choices -and $response.choices.Count -gt 0) { [string]$response.choices[0].message.content } elseif ($null -ne $response.text) { [string]$response.text } else { '' }
    if ([string]::IsNullOrWhiteSpace($text)) { throw "KoboldCpp が空の文章を返しました。" }
    $normalizedText = Normalize-ModelText $text
    $outputContent = $normalizedText
    try {
        $outputJson = $normalizedText | ConvertFrom-Json
        if ($null -ne $outputJson.PSObject.Properties['body']) { $outputContent = [string]$outputJson.body }
    } catch { }
    Write-Host 'Output:' -ForegroundColor Magenta
    Write-Host $outputContent -ForegroundColor DarkMagenta
    return $normalizedText
}

if (-not (Test-Path -LiteralPath $DefaultPath -PathType Leaf)) { throw "既定値ファイルが見つかりません: $DefaultPath" }
$defaults = Get-Content -LiteralPath $DefaultPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($PSCmdlet.ParameterSetName -eq 'New') {
    if ([string]::IsNullOrWhiteSpace($New)) { throw '作成する小説名を指定してください。' }
    $invalidNameChars = [System.IO.Path]::GetInvalidFileNameChars()
    if ($New.IndexOfAny($invalidNameChars) -ge 0) { throw '小説名にファイル名として使用できない文字が含まれています。' }
    $novelConfigDirectory = Join-Path $PSScriptRoot 'novel-configs'
    New-Item -ItemType Directory -Force -Path $novelConfigDirectory | Out-Null
    $templatePath = [System.IO.Path]::GetFullPath((Join-Path $novelConfigDirectory "$New.json"))
    if (Test-Path -LiteralPath $templatePath) { throw "JSON ファイルは既に存在します: $templatePath" }
    $template = [ordered]@{
        novel_name = $New
        novel_prompt = [string]$defaults.novel_prompt
        character = ''
        chapter_count = 0
        macros = [ordered]@{ user = '' }
        planner = [ordered]@{
            user = [string]$defaults.planner.user
            system_prompt = [string]$defaults.planner.system_prompt
        }
        author = [ordered]@{
            user = [string]$defaults.author.user
            system_prompt = [string]$defaults.author.system_prompt
        }
        reviewer = [ordered]@{
            user = [string]$defaults.reviewer.user
            system_prompt = [string]$defaults.reviewer.system_prompt
        }
        summarizer = [ordered]@{
            user = [string]$defaults.summarizer.user
            system_prompt = [string]$defaults.summarizer.system_prompt
        }
    } | ConvertTo-Json -Depth 5 | ForEach-Object { Format-JsonText $_ }
    [System.IO.File]::WriteAllText($templatePath, "$template`r`n", [Text.Encoding]::UTF8)
    Write-Output "Result: config_created=true; path=$templatePath"
    exit 0
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "設定ファイルが見つかりません: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($required in @('api_server','api_type','generate_path','override','json_retry_limit','summary_size','sillytavern_root','sillytavern_user')) {
    if ($null -eq $config.$required) { throw "設定項目がありません: $required" }
}
if ($config.api_type -ne 'koboldcpp') { throw "api_type は koboldcpp である必要があります。" }
if ([int]$config.summary_size -lt 1) { throw 'summary_size は1以上で指定してください。' }
if ([string]::IsNullOrWhiteSpace([string]$config.sillytavern_root)) {
    throw "config.json の sillytavern_root に SillyTavern のルートディレクトリを指定してください。例: C:\\SillyTavern"
}
if (-not (Test-Path -LiteralPath $config.sillytavern_root -PathType Container)) {
    throw "sillytavern_root がディレクトリではありません: $($config.sillytavern_root)"
}

$novelConfigInput = if ($PSCmdlet.ParameterSetName -eq 'Plan') { $Plan } else { $Write }
$novelConfigInputWithExtension = if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($novelConfigInput))) { "$novelConfigInput.json" } else { $novelConfigInput }
$novelConfigCandidates = @(
    (Join-Path (Join-Path $PSScriptRoot 'novel-configs') $novelConfigInput),
    (Join-Path (Join-Path $PSScriptRoot 'novel-configs') $novelConfigInputWithExtension),
    $novelConfigInput,
    $novelConfigInputWithExtension
)
$novelConfigPath = $novelConfigCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not (Test-Path -LiteralPath $novelConfigPath -PathType Leaf)) { throw "小説設定ファイルが見つかりません: $novelConfigPath" }
$novelConfig = Get-Content -LiteralPath $novelConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$novelNameProperty = $novelConfig.PSObject.Properties['novel_name']
$novelName = if ($null -ne $novelNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$novelNameProperty.Value)) {
    [string]$novelNameProperty.Value
} else {
    [System.IO.Path]::GetFileNameWithoutExtension((Resolve-Path -LiteralPath $novelConfigPath))
}
$novelConfig | Add-Member -NotePropertyName novel_name -NotePropertyValue $novelName -Force
foreach ($required in @('character','chapter_count','macros','planner','author','reviewer','summarizer')) {
    if ($null -eq $novelConfig.$required) { throw "小説設定項目がありません: $required" }
    $config | Add-Member -NotePropertyName $required -NotePropertyValue $novelConfig.$required -Force
}
$novelPromptProperty = $novelConfig.PSObject.Properties['novel_prompt']
if ($null -eq $novelPromptProperty) {
    $legacyNovelProperty = $novelConfig.PSObject.Properties['novel']
    $novelPrompt = if ($null -ne $legacyNovelProperty) { [string]$novelConfig.novel } else { [string]$defaults.novel_prompt }
    $novelConfig | Add-Member -NotePropertyName novel_prompt -NotePropertyValue $novelPrompt
}
$novelConfig.novel_prompt = [string]$novelConfig.novel_prompt
$safeNovelName = [System.IO.Path]::GetInvalidFileNameChars() | ForEach-Object { [regex]::Escape([string]$_) }
if ($novelConfig.novel_name -match ("[" + ($safeNovelName -join '') + "]")) { throw 'novel_name にファイル名として使用できない文字が含まれています。' }
$novelDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot (Join-Path 'outputs' $novelName)))
$outlinePath = Join-Path $novelDirectory 'outline.json'
$outputPath = Join-Path $novelDirectory "$novelName.txt"
$statePath = Join-Path $novelDirectory 'state.json'

$characterText = Read-StCharacter $config ([string]$novelConfig.character)
$roleResources = @{}
foreach ($roleName in @('planner','author','reviewer','summarizer')) {
    $role = $config.$roleName
    $roleResources[$roleName] = @{
        system = Read-StTextResource $config 'sysprompt' ([string]$role.system_prompt)
        persona = if ([string]::IsNullOrWhiteSpace([string]$role.user)) { '' } else { Read-StTextResource $config 'personas' ([string]$role.user) }
    }
}

$jsonRetryLimit = [int]$config.json_retry_limit
if ($jsonRetryLimit -lt -1) { throw 'json_retry_limit は -1 または0以上で指定してください。' }
$effectiveJsonRetryLimit = if ($PSCmdlet.ParameterSetName -eq 'Write' -and $Step -eq -1) { -1 } else { $jsonRetryLimit }
$macroValues = @{}
foreach ($property in $novelConfig.macros.PSObject.Properties) { $macroValues[$property.Name] = [string]$property.Value }
$macroValues['char'] = [string]$novelConfig.character
if ($PSCmdlet.ParameterSetName -eq 'Plan') {
    if ([int]$novelConfig.chapter_count -le 0) { throw 'chapter_count は1以上で指定してください。' }
    $outlinePromptText = ([ordered]@{
        novel_prompt = $novelConfig.novel_prompt
        chapter_count = [int]$novelConfig.chapter_count
    } | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ })
    $outlineContextSize = [int]$config.override.context_size
    $outlinePromptCharacters = $outlinePromptText.Length + ([string]$characterText).Length + ([string]$roleResources.planner.persona).Length + ([string]$roleResources.planner.system).Length
    $outlinePromptTokens = [Math]::Ceiling($outlinePromptCharacters / 2)
    $outlineMaxTokens = $outlineContextSize - $outlinePromptTokens - 128
    if ($outlineMaxTokens -lt 1) { throw "構成用プロンプトが context_size を超えています。必要な context_size: $($outlinePromptTokens + 129)" }
    $outlineSystemText = $roleResources.planner.system
    $outlineInstructionText = $defaults.outline.max_tokens_instruction -f $outlineMaxTokens
    $retryCount = 0
    while ($true) {
        try {
            Write-Host 'Run: Planner' -ForegroundColor Yellow
            $outlineResponse = Invoke-KoboldCpp $config $outlinePromptText $macroValues $characterText $roleResources.planner.persona $outlineSystemText $outlineInstructionText $outlineMaxTokens
            $outline = Convert-OutlineResponse $outlineResponse
            if ($null -eq $outline.chapters -or $outline.chapters.Count -eq 0) { throw '構成 JSON に chapters がありません。' }
            if ($outline.chapters.Count -ne [int]$novelConfig.chapter_count) { throw "構成 JSON の chapters 数が指定値と一致しません。指定: $($novelConfig.chapter_count)、実際: $($outline.chapters.Count)" }
            foreach ($chapter in $outline.chapters) {
                if ($null -eq $chapter.elements) { $chapter | Add-Member -NotePropertyName elements -NotePropertyValue @() -Force }
            }
            break
        } catch {
            if (-not (Test-RetryAllowed $retryCount $effectiveJsonRetryLimit)) { throw }
            $retryCount++
            $outlinePromptData = $outlinePromptText | ConvertFrom-Json
            $outlinePromptData | Add-Member -NotePropertyName retry_instruction -NotePropertyValue ([string]$defaults.json_retry.outline) -Force
            $outlinePromptText = $outlinePromptData | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ }
        }
    }
    New-Item -ItemType Directory -Force -Path $novelDirectory | Out-Null
    $outlineJsonText = $outline | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ }
    [System.IO.File]::WriteAllText($outlinePath, "$outlineJsonText`r`n", [Text.Encoding]::UTF8)
} else {
    if (-not (Test-Path -LiteralPath $outlinePath -PathType Leaf)) { throw "構成 JSON がありません。先に -Plan を実行してください: $outlinePath" }
    try { $outline = Get-Content -LiteralPath $outlinePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "構成 JSON を解析できません: $($_.Exception.Message)" }
    if ($null -eq $outline.chapters -or $outline.chapters.Count -eq 0) { throw '構成 JSON に chapters がありません。' }
}

if ($PSCmdlet.ParameterSetName -eq 'Plan') { Write-Output "Result: plan_created=true; path=$novelDirectory"; exit 0 }

if ($Step -eq 0 -or $Step -lt -1) { throw 'Step は -1 または1以上で指定してください。' }
$stepsRemaining = $Step
while ($Step -eq -1 -or $stepsRemaining -gt 0) {
$existing = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Read-TextFile $outputPath } else { '' }
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    (@{ current_chapter = [int]$defaults.current_chapter } | ConvertTo-Json) | Set-Content -LiteralPath $statePath -Encoding UTF8
}
$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) { Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ current_chapter = [int]$defaults.current_chapter } }
$chapterNumber = [int]$state.current_chapter
if ($chapterNumber -lt 0) { throw 'current_chapter は0以上である必要があります。' }
$chapterIndex = $chapterNumber
$displayChapterNumber = $chapterNumber + 1
if ($chapterIndex -ge $outline.chapters.Count) { throw "構成 JSON に第${chapterNumber}章がありません。" }
$previousChapter = if ($chapterIndex -gt 0) { $outline.chapters[$chapterIndex - 1] } else { $null }
$currentChapter = $outline.chapters[$chapterIndex]
$nextChapter = if ($chapterIndex + 1 -lt $outline.chapters.Count) { $outline.chapters[$chapterIndex + 1] } else { $null }
$outlineJson = $outline | ConvertTo-Json -Depth 20
$previousChapterJson = if ($null -eq $previousChapter) { 'null' } else { $previousChapter | ConvertTo-Json -Depth 20 }
$currentChapterJson = $currentChapter | ConvertTo-Json -Depth 20
$nextChapterJson = if ($null -eq $nextChapter) { 'null' } else { $nextChapter | ConvertTo-Json -Depth 20 }
$novelSettingsJson = [string]$novelConfig.novel_prompt
$contextSummary = ''
if (-not [string]::IsNullOrWhiteSpace($existing)) {
    $summaryPrompt = ([ordered]@{
        novel_prompt = $novelSettingsJson
        current_chapter = ($currentChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        summary_size = [int]$config.summary_size
    } | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ })
    $summaryRetryCount = 0
    while ($true) {
        try {
            Write-Host 'Run: Summarize' -ForegroundColor Yellow
            $summaryResponse = Invoke-KoboldCpp $config $summaryPrompt $macroValues $characterText $roleResources.summarizer.persona $roleResources.summarizer.system '' ([int]$config.summary_size) $existing
            $summaryJson = Convert-ModelJson $summaryResponse
            if ($null -eq $summaryJson.PSObject.Properties['summary'] -or [string]::IsNullOrWhiteSpace([string]$summaryJson.summary)) { throw '要約作成者の JSON に summary がありません。' }
            $contextSummary = [string]$summaryJson.summary
            break
        } catch {
            if (-not (Test-RetryAllowed $summaryRetryCount $effectiveJsonRetryLimit)) { throw }
            $summaryRetryCount++
            $summaryPromptData = $summaryPrompt | ConvertFrom-Json
            $summaryPromptData | Add-Member -NotePropertyName retry_instruction -NotePropertyValue ([string]$defaults.json_retry.summarizer) -Force
            $summaryPrompt = $summaryPromptData | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ }
        }
    }
}
$writerPromptData = [ordered]@{
    novel_prompt = $novelSettingsJson
    previous_chapter = ($previousChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    current_chapter = ($currentChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    next_chapter = ($nextChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}
$authorChapter = $writerPromptData.current_chapter
$chapterElements = @($authorChapter.elements)
if ($chapterElements.Count -gt 0) {
    $elementCount = Get-Random -Minimum 1 -Maximum ([Math]::Min(3, $chapterElements.Count) + 1)
    $authorChapter.elements = @($chapterElements | Get-Random -Count $elementCount)
    $writerPromptData.current_chapter = $authorChapter
}
$responseTokens = 0
if ($null -ne $config.override.PSObject.Properties['max_tokens']) { $responseTokens = [int]$config.override.max_tokens }
elseif ($null -ne $config.override.PSObject.Properties['max_completion_tokens']) { $responseTokens = [int]$config.override.max_completion_tokens }
if ($null -eq $config.override.PSObject.Properties['context_size']) { throw 'override.context_size がありません。' }
$contextSize = [int]$config.override.context_size
if ($contextSize -le 0) { throw 'override.context_size は1以上で指定してください。' }
if ($responseTokens -lt 1) { throw 'override.max_tokens または override.max_completion_tokens は1以上で指定してください。' }
$writerPrompt = ($writerPromptData | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ })
$writerPromptTokens = [Math]::Ceiling($writerPrompt.Length / 2)
$writerSystemContent = (@($roleResources.author.system, $roleResources.author.persona, $characterText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n`r`n"
$writerSystemContent = Expand-Macros $writerSystemContent $macroValues
$writerSystemTokens = [Math]::Ceiling($writerSystemContent.Length / 2)
$requiredWriterTokens = $writerSystemTokens + $writerPromptTokens + $responseTokens
if ($requiredWriterTokens -gt $contextSize) { throw "本文用プロンプトと応答予約長の合計が context_size を超えています。必要な context_size: $requiredWriterTokens" }
$availableContextCharacters = (($contextSize - $responseTokens - $writerPromptTokens - $writerSystemTokens) * 2)
if ($availableContextCharacters -lt 0) { $availableContextCharacters = 0 }
$context = $existing
$writerUserSuffix = if (-not [string]::IsNullOrWhiteSpace($contextSummary)) { "## 過去本文の要約`r`n`r`n$contextSummary" } else { '' }
$draftPrompt = $writerPrompt
$retryCount = 0
$rejectionFeedback = ''
$includeRejectionFeedback = $false
$proofreadingRejected = $false
while ($true) {
    try {
        $writerPromptForAttempt = $draftPrompt
        if ($includeRejectionFeedback -and -not [string]::IsNullOrWhiteSpace($rejectionFeedback)) {
            $writerPromptDataForAttempt = $draftPrompt | ConvertFrom-Json
            $writerPromptDataForAttempt | Add-Member -NotePropertyName rejection_reason -NotePropertyValue $rejectionFeedback -Force
            $writerPromptForAttempt = $writerPromptDataForAttempt | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ }
        }
        $includeRejectionFeedback = $false
        Write-Host 'Run: Author' -ForegroundColor Yellow
        $draftResponse = Invoke-KoboldCpp $config $writerPromptForAttempt $macroValues $characterText $roleResources.author.persona $roleResources.author.system '' 0 $context $writerUserSuffix
        $draftJson = Convert-ModelJson $draftResponse
    if ($null -eq $draftJson.PSObject.Properties['body'] -or [string]::IsNullOrWhiteSpace([string]$draftJson.body)) { throw '本文作成者の JSON に body がありません。' }
    if ($null -eq $draftJson.PSObject.Properties['chapter_complete'] -or $draftJson.chapter_complete -isnot [bool]) { throw '本文作成者の JSON に bool 型の chapter_complete がありません。' }
        $draft = [string]$draftJson.body
        $proofPrompt = ([ordered]@{
            novel_prompt = $novelSettingsJson
            previous_chapter = ($previousChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
            current_chapter = ($currentChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
            next_chapter = ($nextChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        } | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ })
        Write-Host 'Run: Reviewer' -ForegroundColor Yellow
        $reviewerUserSuffix = if (-not [string]::IsNullOrWhiteSpace($contextSummary)) { "## 過去本文の要約`r`n`r`n$contextSummary" } else { '' }
        $proofResponse = Invoke-KoboldCpp $config $proofPrompt $macroValues $characterText $roleResources.reviewer.persona $roleResources.reviewer.system '' 0 $draft $reviewerUserSuffix
        $proofJson = Convert-ModelJson $proofResponse
        if ($null -eq $proofJson.PSObject.Properties['body']) { throw '校閲者の JSON に body がありません。' }
        if ($null -eq $proofJson.PSObject.Properties['append'] -or $proofJson.append -isnot [bool]) { throw '校閲者の JSON に bool 型の append がありません。' }
        if (-not $proofJson.append -and ($null -eq $proofJson.PSObject.Properties['rejection_reason'] -or [string]::IsNullOrWhiteSpace([string]$proofJson.rejection_reason))) { throw '校閲者の JSON に棄却理由がありません。' }
        if (-not $proofJson.append) {
            $proofreadingRejected = $true
            $rejectionFeedback = [string]$proofJson.rejection_reason
            $includeRejectionFeedback = $true
            Write-Output "Result: chapter=${displayChapterNumber}; approved=false; appended=false"
            throw '校閲者が本文を棄却しました。'
        }
        $polished = [string]$proofJson.body
        if ([string]::IsNullOrWhiteSpace($polished)) { throw '校閲者の JSON に校正後本文がありません。' }
        break
    } catch {
        if (-not (Test-RetryAllowed $retryCount $effectiveJsonRetryLimit)) { throw }
        $retryCount++
        $draftPromptData = $draftPrompt | ConvertFrom-Json
        $draftPromptData | Add-Member -NotePropertyName retry_instruction -NotePropertyValue ([string]$defaults.json_retry.author) -Force
        $draftPrompt = $draftPromptData | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ }
    }
}

$fullOutputPath = [System.IO.Path]::GetFullPath($outputPath)
$outputDirectory = Split-Path -Parent $fullOutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$separator = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n`r`n" }
[System.IO.File]::AppendAllText($fullOutputPath, "$separator$polished`r`n", [Text.Encoding]::UTF8)
$nextChapter = if ($draftJson.chapter_complete) { $chapterNumber + 1 } else { $chapterNumber }
(@{ current_chapter = [int]$nextChapter } | ConvertTo-Json) | Set-Content -LiteralPath $statePath -Encoding UTF8
$proofreadingReport = 'true'
$appendReport = 'true'
$chapterReport = if ($draftJson.chapter_complete) { 'true' } else { 'false' }
Write-Output "Result: chapter=${displayChapterNumber}; approved=${proofreadingReport}; appended=${appendReport}; chapter_completed=${chapterReport}"
if ($Step -ne -1) { $stepsRemaining-- }
if ($draftJson.chapter_complete -and $nextChapter -ge $outline.chapters.Count) { break }
}
