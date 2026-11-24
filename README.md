# NovelWriter

SillyTavern のローカル資源を参照し、KoboldCpp の Chat API で小説を段階的に作成・校閲する PowerShell ツールです。

## 前提

- PowerShell 7 または Windows PowerShell 5.1
- KoboldCpp が起動していること
- SillyTavern のデータが利用できること

`config.example.json` を `config.json` にコピーし、KoboldCpp と SillyTavern の場所を設定します。

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
  "json_retry_limit": 3,
  "summary_size": 512
}
```

`summary_size` は過去本文の要約目標トークン数です。`override` の属性は KoboldCpp に転送されます。`seed` は未指定時に自動設定されません。

## ロールと資源

ロール名は `planner`、`author`、`reviewer`、`summarizer` です。

```text
data/default-user/sysprompt/
data/default-user/characters/
data/default-user/personas/
```

プロジェクト内の `data/<user>/` が優先され、ない場合だけ SillyTavern 側の同じ資源を参照します。sysprompt は Markdown 入力を指示し、出力形式を示す JSON 例を含みます。

## 小説設定の作成

```powershell
.\Invoke-NovelWriter.ps1 -New 'テスト'
```

作成された `novel-configs/テスト.json` を編集します。

```json
{
  "novel_name": "テスト",
  "novel_prompt": "小説固有の設定",
  "character": "Assistant",
  "chapter_count": 5,
  "macros": {
    "user": ""
  },
  "planner": {
    "user": "",
    "system_prompt": "planner"
  },
  "author": {
    "user": "",
    "system_prompt": "author"
  },
  "reviewer": {
    "user": "",
    "system_prompt": "reviewer"
  },
  "summarizer": {
    "user": "",
    "system_prompt": "summarizer"
  }
}
```

`{{char}}` には `character` の値が自動設定されます。

## 実行

全体構成を生成します。

```powershell
.\Invoke-NovelWriter.ps1 -Plan .\novel-configs\テスト.json
```

本文作成・校閲を1回実行します。

```powershell
.\Invoke-NovelWriter.ps1 -Write .\novel-configs\テスト.json
```

```powershell
# 3回実行
.\Invoke-NovelWriter.ps1 -Write .\novel-configs\テスト.json -Step 3

# 全章が完了するまで実行
.\Invoke-NovelWriter.ps1 -Write .\novel-configs\テスト.json -Step -1
```

旧 CLI 名は使用しません。`state.json` がない場合、`-Write` 時に初期状態で作成されます。`state.json` と本文 `.txt` を削除して再実行すると、先頭章から再試行できます。

## プロンプトと出力

入力プロンプトは日本語 Markdown で構築します。本文作成時は、system、過去本文全量の assistant、Markdown の user 指示、過去本文要約の順に送信します。各 API リクエストにはロールごとの `json_schema` を指定し、回答は JSON として検証・再試行します。

主な出力形式は以下です。

```json
{
  "body": "本文",
  "chapter_complete": false
}
```

ログは `Run:`、`Input:`、`Output:`、`Result:` の形式で表示されます。

## 出力

```text
outputs/<novel_name>/outline.json
outputs/<novel_name>/<novel_name>.txt
outputs/<novel_name>/state.json
```

詳細な仕様は [docs/SPECIFICATION.md](docs/SPECIFICATION.md)、開発上のルールは [docs/AGENTS.md](docs/AGENTS.md) を参照してください。

## License

MIT License（[LICENSE](LICENSE)）
