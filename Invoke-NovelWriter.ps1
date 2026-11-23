[CmdletBinding()]
param(
    [Parameter(ParameterSetName='Create', Mandatory=$true)]
    [string]$Create,
    [Parameter(ParameterSetName='Init', Mandatory=$true)]
    [string]$Init,
    [Parameter(ParameterSetName='Continue', Mandatory=$true)]
    [string]$Continue,
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

function Convert-ModelJson([string]$Text) {
    $jsonText = $Text.Trim()
    if ($jsonText -match '(?s)^```(?:json)?\s*(.*?)\s*```$') { $jsonText = $Matches[1].Trim() }
    try { return $jsonText | ConvertFrom-Json } catch {
        $repairedJsonText = [regex]::Replace($jsonText, '\\(?!["\\/bfnrtu])', '\\\\')
        try { return $repairedJsonText | ConvertFrom-Json } catch { throw "構成執筆者の応答を JSON として解析できません: $($_.Exception.Message)" }
    }
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
    $path = Resolve-StResource $Config $Directory $Name @('.json')
    $resource = Read-JsonResource $path
    foreach ($property in @('content','description','prompt','text')) {
        if ($null -ne $resource.PSObject.Properties[$property]) { return [string]$resource.$property }
    }
    return ($resource | ConvertTo-Json -Depth 20)
}

function Read-StCharacter([object]$Config, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $path = Resolve-StResource $Config 'characters' $Name @('.json','.png')
    if ($path.EndsWith('.json')) {
        $resource = Read-JsonResource $path
        $data = if ($null -ne $resource.data) { $resource.data } else { $resource }
        $parts = @()
        foreach ($property in @('name','description','personality','scenario','first_mes','mes_example','system_prompt','post_history_instructions')) {
            if ($null -ne $data.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace([string]$data.$property)) { $parts += "${property}: $($data.$property)" }
        }
        return ($parts -join "`r`n")
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
                $parts = @()
                foreach ($property in @('name','description','personality','scenario','first_mes','mes_example','system_prompt','post_history_instructions')) {
                    if ($null -ne $data.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace([string]$data.$property)) { $parts += "${property}: $($data.$property)" }
                }
                return ($parts -join "`r`n")
            }
        }
        $offset += 12 + [int]$length
    }
    throw "PNG キャラクターカード '$Name' に chara データがありません: $path"
}

function Invoke-KoboldCpp([object]$Config, [object]$Role, [string]$Prompt, [hashtable]$MacroValues, [string]$CharacterText, [string]$PersonaText, [string]$SystemText, [string]$InstructionText = '', [int]$ResponseTokenOverride = 0) {
    $uri = "$($Config.api_server.TrimEnd('/'))$($Config.generate_path)"
    $systemContent = (@($SystemText, $InstructionText, $PersonaText, $CharacterText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n`r`n"
    $userContent = (@($Role.prompt, $Prompt) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n`r`n"
    $messages = @()
    if (-not [string]::IsNullOrWhiteSpace($systemContent)) { $messages += @{ role = 'system'; content = (Expand-Macros $systemContent $MacroValues) } }
    $messages += @{ role = 'user'; content = (Expand-Macros $userContent $MacroValues) }
    $bodyObject = @{ messages = $messages; stream = $false }
    if ($null -ne $Config.override) {
        foreach ($property in $Config.override.PSObject.Properties) {
            $bodyObject[$property.Name] = $property.Value
        }
    }
    if ($ResponseTokenOverride -gt 0) { $bodyObject.max_tokens = $ResponseTokenOverride }
    $body = $bodyObject | ConvertTo-Json -Depth 5
    $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $body
    $text = if ($null -ne $response.choices -and $response.choices.Count -gt 0) { [string]$response.choices[0].message.content } elseif ($null -ne $response.text) { [string]$response.text } else { '' }
    if ([string]::IsNullOrWhiteSpace($text)) { throw "KoboldCpp が空の文章を返しました。" }
    return $text.Trim()
}

if (-not (Test-Path -LiteralPath $DefaultPath -PathType Leaf)) { throw "既定値ファイルが見つかりません: $DefaultPath" }
$defaults = Get-Content -LiteralPath $DefaultPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($PSCmdlet.ParameterSetName -eq 'Create') {
    if ([string]::IsNullOrWhiteSpace($Create)) { throw '作成する小説名を指定してください。' }
    $invalidNameChars = [System.IO.Path]::GetInvalidFileNameChars()
    if ($Create.IndexOfAny($invalidNameChars) -ge 0) { throw '小説名にファイル名として使用できない文字が含まれています。' }
    $novelConfigDirectory = Join-Path $PSScriptRoot 'novel-configs'
    New-Item -ItemType Directory -Force -Path $novelConfigDirectory | Out-Null
    $templatePath = [System.IO.Path]::GetFullPath((Join-Path $novelConfigDirectory "$Create.json"))
    if (Test-Path -LiteralPath $templatePath) { throw "JSON ファイルは既に存在します: $templatePath" }
    $template = [ordered]@{
        novel_name = $Create
        novel = ''
        character = ''
        chapter_count = 0
        macros = [ordered]@{ user = '' }
        outline_writer = [ordered]@{
            user = [string]$defaults.outline_writer.user
            system_prompt = [string]$defaults.outline_writer.system_prompt
            prompt = [string]$defaults.outline_writer.prompt
        }
        writer = [ordered]@{
            user = [string]$defaults.writer.user
            system_prompt = [string]$defaults.writer.system_prompt
            prompt = [string]$defaults.writer.prompt
        }
        proofreader = [ordered]@{
            user = [string]$defaults.proofreader.user
            system_prompt = [string]$defaults.proofreader.system_prompt
            prompt = [string]$defaults.proofreader.prompt
        }
    } | ConvertTo-Json -Depth 5 | ForEach-Object { Format-JsonText $_ }
    [System.IO.File]::WriteAllText($templatePath, "$template`r`n", [Text.Encoding]::UTF8)
    Write-Output "小説設定 JSON を作成しました: $templatePath"
    exit 0
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "設定ファイルが見つかりません: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($required in @('api_server','api_type','generate_path','override','json_retry_limit','sillytavern_root','sillytavern_user')) {
    if ($null -eq $config.$required) { throw "設定項目がありません: $required" }
}
if ($config.api_type -ne 'koboldcpp') { throw "api_type は koboldcpp である必要があります。" }
if ([string]::IsNullOrWhiteSpace([string]$config.sillytavern_root)) {
    throw "config.json の sillytavern_root に SillyTavern のルートディレクトリを指定してください。例: C:\\SillyTavern"
}
if (-not (Test-Path -LiteralPath $config.sillytavern_root -PathType Container)) {
    throw "sillytavern_root がディレクトリではありません: $($config.sillytavern_root)"
}

$novelConfigPath = if ($PSCmdlet.ParameterSetName -eq 'Init') { $Init } else { $Continue }
if (-not (Test-Path -LiteralPath $novelConfigPath -PathType Leaf)) { throw "小説設定ファイルが見つかりません: $novelConfigPath" }
$novelConfig = Get-Content -LiteralPath $novelConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$novelNameProperty = $novelConfig.PSObject.Properties['novel_name']
$novelName = if ($null -ne $novelNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$novelNameProperty.Value)) {
    [string]$novelNameProperty.Value
} else {
    [System.IO.Path]::GetFileNameWithoutExtension((Resolve-Path -LiteralPath $novelConfigPath))
}
$novelConfig | Add-Member -NotePropertyName novel_name -NotePropertyValue $novelName -Force
foreach ($required in @('character','novel','chapter_count','macros','outline_writer','writer','proofreader')) {
    if ($null -eq $novelConfig.$required) { throw "小説設定項目がありません: $required" }
    $config | Add-Member -NotePropertyName $required -NotePropertyValue $novelConfig.$required -Force
}
$novelConfig.novel = [string]$novelConfig.novel
$safeNovelName = [System.IO.Path]::GetInvalidFileNameChars() | ForEach-Object { [regex]::Escape([string]$_) }
if ($novelConfig.novel_name -match ("[" + ($safeNovelName -join '') + "]")) { throw 'novel_name にファイル名として使用できない文字が含まれています。' }
$novelDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot (Join-Path 'outputs' $novelName)))
$outlinePath = Join-Path $novelDirectory 'outline.json'
$outputPath = Join-Path $novelDirectory "$novelName.txt"
$statePath = Join-Path $novelDirectory 'state.json'

$characterText = Read-StCharacter $config ([string]$novelConfig.character)
$roleResources = @{}
foreach ($roleName in @('outline_writer','writer','proofreader')) {
    $role = $config.$roleName
    $roleResources[$roleName] = @{
        system = Read-StTextResource $config 'sysprompt' ([string]$role.system_prompt)
        persona = if ([string]::IsNullOrWhiteSpace([string]$role.user)) { '' } else { Read-StTextResource $config 'personas' ([string]$role.user) }
    }
}

$jsonRetryLimit = [int]$config.json_retry_limit
if ($jsonRetryLimit -lt -1) { throw 'json_retry_limit は -1 または0以上で指定してください。' }
$macroValues = @{}
foreach ($property in $novelConfig.macros.PSObject.Properties) { $macroValues[$property.Name] = [string]$property.Value }
$macroValues['char'] = [string]$novelConfig.character
if ($PSCmdlet.ParameterSetName -eq 'Init') {
    if ([int]$novelConfig.chapter_count -le 0) { throw 'chapter_count は1以上で指定してください。' }
    $outlinePromptText = ([ordered]@{
        novel = $novelConfig.novel
        chapter_count = [int]$novelConfig.chapter_count
        outline_template = $defaults.outline.outline_template
        chapter_template = $defaults.outline.chapter_template
    } | ConvertTo-Json -Depth 20)
    $outlineContextSize = [int]$config.override.context_size
    $outlinePromptCharacters = $outlinePromptText.Length + ([string]$characterText).Length + ([string]$roleResources.outline_writer.persona).Length + ([string]$roleResources.outline_writer.system).Length + ([string]$config.outline_writer.prompt).Length
    $outlinePromptTokens = [Math]::Ceiling($outlinePromptCharacters / 2)
    $outlineMaxTokens = $outlineContextSize - $outlinePromptTokens - 128
    if ($outlineMaxTokens -lt 1) { throw "構成用プロンプトが context_size を超えています。必要な context_size: $($outlinePromptTokens + 129)" }
    $outlineSystemText = $roleResources.outline_writer.system
    $outlineInstructionText = $defaults.outline.max_tokens_instruction -f $outlineMaxTokens
    $retryCount = 0
    while ($true) {
        try {
            $outlineResponse = Invoke-KoboldCpp $config $config.outline_writer $outlinePromptText $macroValues $characterText $roleResources.outline_writer.persona $outlineSystemText $outlineInstructionText $outlineMaxTokens
            $outline = Convert-ModelJson $outlineResponse
            if ($null -eq $outline.chapters -or $outline.chapters.Count -eq 0) { throw '構成 JSON に chapters がありません。' }
            if ($outline.chapters.Count -ne [int]$novelConfig.chapter_count) { throw "構成 JSON の chapters 数が指定値と一致しません。指定: $($novelConfig.chapter_count)、実際: $($outline.chapters.Count)" }
            foreach ($chapter in $outline.chapters) {
                if ($null -eq $chapter.elements) { $chapter | Add-Member -NotePropertyName elements -NotePropertyValue @() -Force }
            }
            break
        } catch {
            if (-not (Test-RetryAllowed $retryCount $jsonRetryLimit)) { throw }
            $retryCount++
            $outlinePromptText += "`r`n`r`n$($defaults.json_retry.outline)"
        }
    }
    New-Item -ItemType Directory -Force -Path $novelDirectory | Out-Null
    $outlineJsonText = $outline | ConvertTo-Json -Depth 20 | ForEach-Object { Format-JsonText $_ }
    [System.IO.File]::WriteAllText($outlinePath, "$outlineJsonText`r`n", [Text.Encoding]::UTF8)
    (@{ current_chapter = [int]$defaults.current_chapter } | ConvertTo-Json) | Set-Content -LiteralPath $statePath -Encoding UTF8
} else {
    if (-not (Test-Path -LiteralPath $outlinePath -PathType Leaf)) { throw "構成 JSON がありません。先に -Init を実行してください: $outlinePath" }
    try { $outline = Get-Content -LiteralPath $outlinePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "構成 JSON を解析できません: $($_.Exception.Message)" }
    if ($null -eq $outline.chapters -or $outline.chapters.Count -eq 0) { throw '構成 JSON に chapters がありません。' }
}

if ($PSCmdlet.ParameterSetName -eq 'Init') { Write-Output "小説フォルダと全体構成を作成しました: $novelDirectory"; exit 0 }

if ($Step -eq 0 -or $Step -lt -1) { throw 'Step は -1 または1以上で指定してください。' }
$stepsRemaining = $Step
while ($Step -eq -1 -or $stepsRemaining -gt 0) {
$existing = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Read-TextFile $outputPath } else { '' }
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
$novelSettingsJson = [string]$novelConfig.novel
$writerPromptData = [ordered]@{
    novel = $novelSettingsJson
    outline = ($outline | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    previous_chapter = ($previousChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    current_chapter = ($currentChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    next_chapter = ($nextChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    context = ''
    chapter = $chapterNumber
}
$responseTokens = 0
if ($null -ne $config.override.PSObject.Properties['max_tokens']) { $responseTokens = [int]$config.override.max_tokens }
elseif ($null -ne $config.override.PSObject.Properties['max_completion_tokens']) { $responseTokens = [int]$config.override.max_completion_tokens }
if ($null -eq $config.override.PSObject.Properties['context_size']) { throw 'override.context_size がありません。' }
$contextSize = [int]$config.override.context_size
if ($contextSize -le 0) { throw 'override.context_size は1以上で指定してください。' }
if ($responseTokens -lt 1) { throw 'override.max_tokens または override.max_completion_tokens は1以上で指定してください。' }
$promptWithoutContext = ($writerPromptData | ConvertTo-Json -Depth 20)
$promptWithoutContextTokens = [Math]::Ceiling($promptWithoutContext.Length / 2)
if ($promptWithoutContextTokens + $responseTokens -gt $contextSize) { throw "本文用プロンプトと応答予約長の合計が context_size を超えています。必要な context_size: $($promptWithoutContextTokens + $responseTokens)" }
$availableContextCharacters = (($contextSize - $responseTokens - $promptWithoutContextTokens) * 2)
if ($availableContextCharacters -lt 0) { $availableContextCharacters = 0 }
$context = if ($existing.Length -gt $availableContextCharacters) { $existing.Substring($existing.Length - $availableContextCharacters) } else { $existing }
$writerPromptData.context = $context
$draftPrompt = $writerPromptData | ConvertTo-Json -Depth 20
$retryCount = 0
$rejectionFeedback = ''
$proofreadingRejected = $false
while ($true) {
    try {
        $writerPromptForAttempt = $draftPrompt
        if (-not [string]::IsNullOrWhiteSpace($rejectionFeedback)) { $writerPromptForAttempt += "`r`n`r`n【校正者からの棄却理由と要求】`r`n$rejectionFeedback" }
        $draftResponse = Invoke-KoboldCpp $config $config.writer $writerPromptForAttempt $macroValues $characterText $roleResources.writer.persona $roleResources.writer.system
        $draftJson = Convert-ModelJson $draftResponse
        if ($null -eq $draftJson.PSObject.Properties['body'] -or [string]::IsNullOrWhiteSpace([string]$draftJson.body)) { throw '本文執筆者の JSON に body がありません。' }
        if ($null -eq $draftJson.PSObject.Properties['chapter_complete'] -or $draftJson.chapter_complete -isnot [bool]) { throw '本文執筆者の JSON に bool 型の chapter_complete がありません。' }
        $draft = [string]$draftJson.body
        $proofPrompt = ([ordered]@{
            novel = $novelSettingsJson
            draft = $draft
            outline = ($outline | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
            previous_chapter = ($previousChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
            current_chapter = ($currentChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
            next_chapter = ($nextChapter | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
            chapter = $chapterNumber
        } | ConvertTo-Json -Depth 20)
        $proofResponse = Invoke-KoboldCpp $config $config.proofreader $proofPrompt $macroValues $characterText $roleResources.proofreader.persona $roleResources.proofreader.system
        $proofJson = Convert-ModelJson $proofResponse
        if ($null -eq $proofJson.PSObject.Properties['body']) { throw '校正者の JSON に body がありません。' }
        if ($null -eq $proofJson.PSObject.Properties['append'] -or $proofJson.append -isnot [bool]) { throw '校正者の JSON に bool 型の append がありません。' }
        if (-not $proofJson.append -and ($null -eq $proofJson.PSObject.Properties['rejection_reason'] -or [string]::IsNullOrWhiteSpace([string]$proofJson.rejection_reason))) { throw '校正者の JSON に棄却理由がありません。' }
        if (-not $proofJson.append) {
            $proofreadingRejected = $true
            $rejectionFeedback = [string]$proofJson.rejection_reason
            Write-Output "第${displayChapterNumber}章を執筆・校正し、結果は棄却された。"
            throw '校正者が本文を棄却しました。'
        }
        $polished = [string]$proofJson.body
        if ([string]::IsNullOrWhiteSpace($polished)) { throw '校正者の JSON に校正後本文がありません。' }
        break
    } catch {
        if (-not (Test-RetryAllowed $retryCount $jsonRetryLimit)) { throw }
        $retryCount++
        $draftPrompt += "`r`n`r`n$($defaults.json_retry.writer)"
    }
}

$fullOutputPath = [System.IO.Path]::GetFullPath($outputPath)
$outputDirectory = Split-Path -Parent $fullOutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$separator = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n`r`n" }
[System.IO.File]::AppendAllText($fullOutputPath, "$separator$polished`r`n", [Text.Encoding]::UTF8)
$nextChapter = if ($draftJson.chapter_complete) { $chapterNumber + 1 } else { $chapterNumber }
(@{ current_chapter = [int]$nextChapter } | ConvertTo-Json) | Set-Content -LiteralPath $statePath -Encoding UTF8
$proofreadingReport = '承認'
$appendReport = '追記した'
$chapterReport = if ($draftJson.chapter_complete) { '完了した' } else { '継続している' }
Write-Output "第${displayChapterNumber}章を執筆・校正し、結果は${proofreadingReport}され、${appendReport}。章は${chapterReport}。"
if ($Step -ne -1) { $stepsRemaining-- }
if ($draftJson.chapter_complete -and $nextChapter -ge $outline.chapters.Count) { break }
}
