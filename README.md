# NovelWriter

SillyTavern のローカルデータを参照し、KoboldCpp の Chat API で小説を段階的に執筆する PowerShell ツールです。

## 前提

- PowerShell 7 または Windows PowerShell 5.1
- KoboldCpp が起動していること
- SillyTavern のデータが利用できること

`config.example.json` を `config.json` にコピーし、`config.json` に KoboldCpp と SillyTavern の場所を設定します。`config.json` は開発者固有の設定を含むためGit管理対象外です。

```json
{
  "api_server": "http://127.0.0.1:5001",
  "api_type": "koboldcpp",
  "generate_path": "/v1/chat/completions",
  "sillytavern_root": "C:/app/SillyTavern",
  "sillytavern_user": "default-user",
  "override": {
    "context_size": 8192,
    "max_tokens": 1024
  },
  "json_retry_limit": 3
}
```

## システムプロンプト

プロジェクトの `data/<user>/` が最優先で参照され、存在しない場合だけ SillyTavern の同じ場所が参照されます。

```text
data/default-user/sysprompt/
data/default-user/characters/
data/default-user/personas/
```

システムプロンプトは `sysprompt`、キャラクターは JSON または PNG カード、ペルソナは JSON を使用します。

## 小説設定の作成

```powershell
.\Invoke-NovelWriter.ps1 -Create 'テスト'
```

作成された `novel-configs/テスト.json` を編集します。

```json
{
  "novel_name": "テスト",
  "novel": "小説固有の設定",
  "character": "Assistant",
  "chapter_count": 5,
  "macros": {
    "user": ""
  },
  "outline_writer": {
    "user": "",
    "system_prompt": "outline_writer",
    "prompt": ""
  },
  "writer": {
    "user": "",
    "system_prompt": "writer",
    "prompt": ""
  },
  "proofreader": {
    "user": "",
    "system_prompt": "proofreader",
    "prompt": ""
  }
}
```

`{{char}}` には `character` の値が自動的に設定されます。

## 実行

最初に全体構成を生成します。

```powershell
.\Invoke-NovelWriter.ps1 -Init .\novel-configs\テスト.json
```

本文執筆と校正を1回実行します。

```powershell
.\Invoke-NovelWriter.ps1 -Continue .\novel-configs\テスト.json
```

複数回実行する場合は `-Step` を指定します。

```powershell
# 3回実行
.\Invoke-NovelWriter.ps1 -Continue .\novel-configs\テスト.json -Step 3

# 全章が完了するまで実行
.\Invoke-NovelWriter.ps1 -Continue .\novel-configs\テスト.json -Step -1
```

校正者が棄却した場合は、その理由を本文執筆者へ渡して再執筆します。棄却時は追記せず、承認された本文だけを成果物へ追記します。

## 出力

```text
outputs/<novel_name>/outline.json
outputs/<novel_name>/<novel_name>.txt
outputs/<novel_name>/state.json
```

詳細な仕様は [docs/SPECIFICATION.md](docs/SPECIFICATION.md)、開発上のルールは [docs/AGENTS.md](docs/AGENTS.md) を参照してください。
