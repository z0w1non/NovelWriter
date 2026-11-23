# Tests

`run_tests.ps1` は SillyTavern へ接続せず、プロジェクトの設定・sysprompt・PowerShell 実装契約を検証する単体テストです。

```powershell
pwsh -File .\tests\run_tests.ps1
```

小説固有データを含む `novel-configs/` と `outputs/` はテスト対象にしません。
