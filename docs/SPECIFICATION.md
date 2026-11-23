# SPECIFICATION.md

## 概要

`Invoke-NovelWriter.ps1` は、SillyTavern のロール資源とキャラクター情報を読み込み、KoboldCpp の Chat Completions API で小説を生成する PowerShell プロジェクトです。

## CLI

- `-New <小説名>`：小説設定を作成する。
- `-Plan <設定JSON>`：全体構成を生成して `outline.json` に保存する。
- `-Write <設定JSON>`：本文作成・校閲・追記を実行する。
- `-Write <設定JSON> -Step N`：N回実行する。`-1` は全章完了まで繰り返す。

旧 CLI 名は使用しません。

## ロール

- `planner`：全体構成を作成する。
- `author`：本文を作成する。
- `reviewer`：本文と過去文脈の矛盾・重複・章計画からの逸脱を検証する。
- `summarizer`：過去本文を要約する。

設定キー、sysprompt ファイル名、内部参照はこのロール名に統一する。

## プロンプト形式

入力プロンプトは JSON を埋め込まず、日本語 Markdown の見出しと箇条書きで構築する。見出しの前には空行を置く。出力形式を示す JSON 例だけは sysprompt に残す。

本文作成時の messages は、system、過去本文全量を持つ assistant、Markdown の user 指示、user 指示末尾の過去本文要約の順とする。校閲時は system、作成本文を持つ assistant、Markdown の user 指示、過去本文要約の順とする。

## 構成

planner の user 指示には小説設定と章数を含める。`outline_template` と `chapter_template` は使用しない。各章は `title`、`summary`、`elements` を持ち、`elements` は短い語句で原則6〜10個、目安8個とする。

本文作成者へは `current_chapter.elements` のうち1〜3個を毎回ランダム抽選し、ランダム順で渡す。

## コンテキスト

過去本文は要約者へ assistant message として全量を渡す。要約後のトークン目標は `config.json` の `summary_size` で指定する。本文作成者・校閲者へは過去本文要約を user message 末尾の Markdown 見出し `## 過去本文の要約` として追加する。本文全量は本文作成者の assistant message として渡し、直近本文用の個別サイズ設定は持たない。

## 設定

`config.json` の `override` 属性は KoboldCpp リクエストへ転送する。`seed` を指定しない場合は自動付与しない。`summary_size` は1以上の要約目標トークン数とする。

## 出力と再試行

planner、author、reviewer、summarizer の回答は JSON を要求し、`Convert-ModelJson` で抽出・検証する。不正な場合は `json_retry_limit` の範囲で再試行する。

実行ログは `Run: Planner`、`Run: Summarize`、`Run: Author`、`Run: Reviewer`、`Input:`、`Output:`、`Result:` の形式で出力する。

校閲承認時の結果例：

```text
Result: chapter=1; approved=true; appended=true; chapter_completed=true
```
