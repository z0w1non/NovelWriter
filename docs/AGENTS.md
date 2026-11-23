# AGENTS.md

## 目的

このプロジェクトは、ローカルで動作する SillyTavern サーバーの生成ブリッジと通信し、planner・author・reviewer・summarizer に割り当てたユーザー（ペルソナ）と、対象キャラクター、登録済みプロンプトを使って成果物を作る PowerShell プロジェクトです。

## 変更方針

- チャットによる調査・レビュー・検索では `novel-configs/` と `outputs/` を既定の参照対象から除外する。ユーザーが特定のファイルや内容の確認を明示的に依頼した場合のみ参照する。
- アプリケーションの実行に必要な `novel-configs/` と `outputs/` の読み書きは許可するが、チャットへの内容表示、ログ出力、資料への転載は行わない。
- `rg`、`Get-ChildItem`、レビュー用の再帰検索では `novel-configs/` と `outputs/` を除外する。
- 実装を変更した場合は、同じ変更で影響を受ける `docs/AGENTS.md`、`docs/SPECIFICATION.md`、`docs/ISSUES.md`、サンプル設定・プロンプトを必ず確認し、必要な資料を同時に更新する。
- 実装と資料の内容が一致していることを、検索・構文検査・`git diff --check` で確認する。
- API 接続先、生成パラメータ、SillyTavern に登録されたリソース名は `config.json` に置き、コードへハードコードしない。
- 全小説共通の既定値、生成プロンプト、再試行指示は `default.json` に置き、小説 JSON やスクリプトへ重複記述しない。
- `character` は共通設定として役割と同階層に置く。planner・author・reviewer・summarizer には各役割の `user` を割り当てる。
- 小説固有の設定（題材、ジャンル、人物、舞台、文体、制約など）は `novel-configs/<novel_name>.json` の単一文字列 `novel` に記述する。
- マクロは小説設定JSONの `macros` オブジェクトから読み込み、PowerShell側で展開する。
- 開発者個人のパス、ユーザー名、トークン、Cookie、その他の環境依存値はGit管理対象にしない。ローカル設定は `config.json` に置き、共有用の雛形は `config.example.json` に置く。
- JSONファイルのインデントは半角スペース2文字に統一する。タブや、プロパティ位置に応じた可変幅の整列インデントは使用しない。
- 全体構成を `outputs/<novel_name>/outline.json` に保存し、同フォルダの `state.json` の0始まり数値 `current_chapter` で段階的に進行する。
- 成果物は追記型とし、既存の `outputs/<novel_name>/<novel_name>.txt` を上書きしない。
- 生成結果を信頼せず、空応答・接続失敗・不正な API 応答をエラーにする。
- 構成 JSON・本文 JSON の形式不正は `config.json` の `json_retry_limit` に従って再試行し、`-1` は無限再試行とする。
- JSON 再試行時の補正指示は `default.json` の `json_retry` から取得し、スクリプトへ直接記述しない。
- 役割、出力形式、恒常的な禁止事項は `data/default-user/sysprompt/` に置き、同名ファイルがあれば SillyTavern 側より優先する。実行時の入力プロンプトは日本語 Markdown とし、出力形式を示す JSON 例だけを sysprompt に残す。
- PowerShell 5.1 以上で動作する構文を優先する。
- 構成は `outline.json` とし、トップレベルの `chapters` 配列と各章の `elements` 配列を維持する。
- 実装変更後は `pwsh -File .\tests\run_tests.ps1` を実行し、SillyTavern に接続しない単体テストを通過させる。

## 実行例

```powershell
pwsh -File .\Invoke-NovelWriter.ps1 -New '新しい小説'
pwsh -File .\Invoke-NovelWriter.ps1 -Plan .\novel-configs\新しい小説.json
pwsh -File .\Invoke-NovelWriter.ps1 -Write .\novel-configs\新しい小説.json
```

## 受け入れ確認

SillyTavern と生成ブリッジを `config.json` の URL で起動し、初回実行で `outputs/<novel_name>/outline.json` と `outputs/<novel_name>/<novel_name>.txt` が作成され、二回目以降は既存本文に校正済み本文が追記されることを確認する。
