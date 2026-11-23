# SPECIFICATION.md

## 概要

`Invoke-NovelWriter.ps1` は、SillyTavern のローカルデータからペルソナ、キャラクター、システムプロンプトを読み込み、KoboldCpp の `/v1/chat/completions` に `system`／`user` メッセージを送る。SillyTavern の HTTP サーバー応答、ログイン、Cookie、CSRF には依存しない。

## 処理フロー

1. `-Init xxx.json` または `-Continue xxx.json` で小説設定を読み込む。
2. `outputs/<novel_name>/` を小説フォルダとして使用する。
3. `-Init` は JSON 構造の全体構成を生成して `outline.json` に保存し、終了する。
4. `-Continue` は構成、現在章の前後、直近の本文、JSON の `current_chapter` を本文執筆者へ渡して本文 JSON を生成する。
5. 本文 JSON の `body` を校正者へ渡し、校正済み本文を `<novel_name>.txt` へ追記する。
6. `chapter_complete` が `true` の場合だけ、次章番号を `state.json` の `current_chapter` に保存する。`false` の場合は同じ章番号を維持する。

`-Create <小説名>` は、プロジェクトの `novel-configs/` に `<小説名>.json` を作成する。`novel_name`、単一文字列の小説固有設定 `novel`、共通 `character`、`chapter_count`、`macros`、`outline_writer`、`writer`、`proofreader` を初期化する。構成形式や初期章番号などの既定値は `default.json` に集約する。SillyTavern への接続は行わない。

## 入力

- `config.json`: KoboldCpp URL、SillyTavern ルートディレクトリとユーザー名、生成設定、再試行回数。`override.context_size` はコンテキスト上限、`max_tokens` または `max_completion_tokens` は応答予約長として使用する。`override` 配下の属性は内容を限定せず、そのまま KoboldCpp の生成リクエストへ転送する。
- `default.json`: `outline` 配下の構成テンプレート・章テンプレート・構成応答指示、初期章番号、3役の既定値、JSON 再試行時の補正指示など、全小説に共通する既定値
- `config.json` の `json_retry_limit`: 構成 JSON・本文 JSON の形式不正時の再試行回数。`-1` は無限、`0` は再試行なし

`default.json` の `json_retry.outline` と `json_retry.writer` は、構成 JSON・本文 JSON の再試行時に追加する指示文である。実行時データは `novel`、`outline`、`previous_chapter`、`current_chapter`、`next_chapter`、`context` などのJSON属性として構造化し、そのJSON文字列をプロンプトへ渡す。`context` は `(override.context_size × 2) - (応答予約トークン × 2) - (context以外のプロンプト文字数)` を上限文字数として、既存本文の末尾から取得する。日本語を含むプロンプトの安全側の概算として1トークンを約2文字とする。

`context_size` は入力プロンプトと生成応答の合計トークン上限、`max_tokens` または `max_completion_tokens` は生成応答の予約上限である。入力プロンプトの推定トークン数と応答予約長の合計は `context_size` 以下でなければならない。
- `novel-configs/xxx.json`: 小説ごとの設定と SillyTavern 設定。`novel` に小説がどのような作品かを記述する単一のプロンプト文字列、`chapter_count` に構成の章数を指定する
- `outputs/<novel_name>/state.json`: 現在の執筆状態。`current_chapter` は次に執筆する章を表す0始まりの数値
- `data/default-user/sysprompt/*.json`: プロジェクト側で優先して読み込む3役のシステムプロンプト。SillyTavern の同じ相対パスへコピーすることもできる
- `novel-configs/xxx.json` の `macros`: PowerShell 側で展開するマクロ値のオブジェクト

`novel-configs/xxx.json` の `novel` には、小説の題材・ジャンル・人物・舞台・文体・制約などを自由記述する単一のプロンプト文字列を設定する。`-Init` ではこのプロンプトを構成執筆者へ渡し、`-Continue` では本文執筆者と校正者のコンテキストとして利用する。

## SillyTavern データと KoboldCpp 連携

既定の `generate_path` は KoboldCpp の Chat Completions API `/v1/chat/completions` である。まずプロジェクトの `data/<user>/...`、存在しない場合にだけ `sillytavern_root/data/<user>/...` を検索する。対象は `characters`、`personas`、`sysprompt` である。

`sillytavern_root` は必須である。空文字や存在しないディレクトリを指定すると、処理開始時にエラーになる。Windows では例えば `C:\\SillyTavern` のように指定する。

ブリッジからの応答は OpenAI 互換の `choices[0].message.content`、または単純な `text` のいずれかを返してください。構成生成時と本文生成時は JSON オブジェクトを返し、校正時は本文テキストを返します。

キャラクターとペルソナは JSON、システムプロンプトは `{name}.json` として読み込む。キャラクターとペルソナの空文字は指定できない。

小説設定JSONの `macros` オブジェクトは、読み込んだ全プロンプト内の `{{name}}` を対応する値へPowerShell側で展開します。コマンドラインの `-Macro` オプションは使用しません。

`-Create` 直後の `macros` には `user` を空文字で作成する。実行時には共通キャラクター名を `char` マクロとして自動追加する。

`novel-configs/` と `outputs/` は小説ごとの設定・成果物を格納する保護対象ディレクトリである。アプリケーションは実行に必要な範囲で参照するが、チャット上の通常の調査・検索・レビューでは参照しない。内容確認が必要な場合は対象ファイルを明示的に指定する。

```powershell
pwsh -File .\Invoke-NovelWriter.ps1 -Init .\novel-configs\雨の街.json
```

## 出力

構成を `outputs/<novel_name>/outline.json` に保存し、校正済み本文のみを `outputs/<novel_name>/<novel_name>.txt` に章ごとに追記する。進行状態は `outputs/<novel_name>/state.json` に保存する。API の応答に含まれるメタデータや見出しは成果物へ追加しない。

`outline.json` は2スペースインデントで保存する。

`outline.json` は次の構造を基本とする。`chapters` は章の配列、`elements` は各章に帰属する任意個数の要素の配列である。現在章は `state.json` の `current_chapter` と `chapters` 配列の位置（0始まり）で決定する。

```json
{
  "chapters": [
    {
      "title": "",
      "summary": "",
      "elements": []
    }
  ]
}
```

章オブジェクトの構造は `title`、`summary`、`elements` の3属性とする。`chapters` は章オブジェクトの配列、`elements` は各章に帰属する任意個数の要素を格納する配列とする。現在章は `state.json` の `current_chapter` を配列位置として決定する。要素内部の追加属性は本仕様では定義しない。

本文執筆者と校正者には、小説固有設定と全体構成に加えて、現在章の前後関係を示す3つの JSON を渡す。先頭章では前章を `null`、最終章では次章を `null` とする。

プロンプトへ渡すJSONの `chapter` は0始まりの章インデックスとする。ユーザー向けの実行結果表示だけは1始まりで表示する。

実行例:

```powershell
pwsh -File .\Invoke-NovelWriter.ps1 -Create '雨の街'
pwsh -File .\Invoke-NovelWriter.ps1 -Init .\novel-configs\雨の街.json
pwsh -File .\Invoke-NovelWriter.ps1 -Continue .\novel-configs\雨の街.json
pwsh -File .\Invoke-NovelWriter.ps1 -Continue .\novel-configs\雨の街.json -Step -1
```

`-Continue` の `-Step` は1回の実行で処理する回数を指定する。既定値は `1`、`-1` は構成の全章が完了するまで繰り返す。正の値ではその回数だけ繰り返し、`0` や `-2` 以下はエラーとする。

実行報告は「第何章を執筆・校正し、結果は承認され、追記した。章は完了した。」の形式で出力する。校正が棄却された場合は再執筆し、最終的に承認された結果を報告する。

校正者が棄却した場合は直ちに「第N章を執筆・校正し、結果は棄却された。」と報告する。構成JSONや本文の再試行自体は報告しない。

## エラー

API 接続不能、設定不足、再試行上限到達、`choices[0].message.content`／`text` 欠落、構成 JSON の `chapters` 欠落、本文 JSON の `body`／bool 型 `chapter_complete` 欠落、空の生成結果は処理を中断し、成果物を変更しない。JSON 構造不正は上限まで再試行する。

## テスト

構成生成時は `override.context_size` から構成用プロンプト等の推定トークン数と128トークンの安全余裕を差し引いた値を `max_tokens` として自動指定する。本文生成時も同じ関係を使い、残った容量だけ既存本文の末尾を `context` として含める。

`tests/run_tests.ps1` は SillyTavern に接続せず、設定 JSON、sysprompt JSON、PowerShell 構文、構成・本文 JSON の実装契約を検証する。

本文執筆者の JSON 形式:

```json
{
  "body": "今回生成した本文",
  "chapter_complete": true
}
```

校正者の回答は次の JSON 形式とする。`append` が `false` の場合、`rejection_reason` に棄却理由と執筆者への要求を包括して記述する。その内容は執筆者へ転送され、本文を再生成する。

```json
{
  "body": "校正後の本文",
  "append": true,
  "rejection_reason": ""
}
```
