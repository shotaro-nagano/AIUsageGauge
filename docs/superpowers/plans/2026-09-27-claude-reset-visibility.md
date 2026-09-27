# Claude Reset Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claudeの5時間・7日reset時間を常時表示しながら、ログイン更新警告とクリック再ログイン導線を維持する。

**Architecture:** Claude usage取得・マッピングは変更せず、成功時UIの表示優先順位だけを修正する。resetはフッター、更新警告はタイトルとWindows通知に分離し、インストール済みファイルだけに存在する通知タイマーのclosure修正も追跡ソースへ同期する。

**Tech Stack:** PowerShell 7、WPF、Windows Task Scheduler、既存PowerShellテスト

---

### Task 1: Claude成功時の表示優先順位をテストで固定する

**Files:**
- Modify: `tests/Test-ClaudeCredentialState.ps1`
- Modify: `tests/Test-AIUsageGauge.ps1`
- Modify: `Start-AIUsageGauge.ps1`

- [ ] **Step 1: reset維持と更新警告の失敗テストを書く**

`tests/Test-ClaudeCredentialState.ps1`で、既存の`login renewal due`文字列確認を次へ置き換える。

```powershell
Assert-True ($start -match '\$claudeFooter\.Text\s*=\s*\(''reset \{0\} / \{1\}''') 'Claude footer must format both reset durations'
Assert-True ($start -notmatch '\$claudeFooter\.Text\s*=\s*''login renewal due''') 'Login renewal warning must not replace Claude reset times'
Assert-True ($start -match '\$claudeTitle\.Text\s*=\s*''Claude rate · renew''') 'Login renewal warning must move to the Claude title'
Assert-True ($start -match '(?s)if\s*\(\$cl\.LoginRenewalDue\).*\$script:ClaudeNeedsRelogin\s*=\s*\$true.*Show-AIUsageGaugeNotification') 'Login renewal must preserve click-to-login state and notification'
```

`tests/Test-AIUsageGauge.ps1`へ、通知タイマーの既存実機修正を保護する検査を追加する。

```powershell
Assert-True ($start -match '(?s)\$cleanupTimer\.Add_Tick\(\{.*?\}\.GetNewClosure\(\)\)') 'Notification cleanup timer must capture its own timer instance'
```

- [ ] **Step 2: REDを確認する**

```powershell
pwsh -NoProfile -File .\tests\Test-ClaudeCredentialState.ps1 -RepoRoot (Get-Location).Path
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1 -RepoRoot (Get-Location).Path
```

Expected: reset上書きと`.GetNewClosure()`未同期のため失敗する。

- [ ] **Step 3: 最小実装を追加する**

`Start-AIUsageGauge.ps1`の通知タイマーを、稼働中ファイルと同じclosure保持へ変更する。

```powershell
$cleanupTimer.Add_Tick({
    try {
        $cleanupTimer.Stop()
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch {}
}.GetNewClosure())
```

Claude成功時の更新期限分岐は、フッターではなくタイトルだけを変更する。

```powershell
if ($cl.LoginRenewalDue) {
    $claudeTitle.Text = 'Claude rate · renew'
    $script:ClaudeNeedsRelogin = $true
    Show-AIUsageGaugeNotification -Key 'Claude-login-renewal' -Title 'AI Usage Gauge' -Message 'Claude login renewal is due.' -Icon 'Warning'
}
```

- [ ] **Step 4: 対象テストをGREENにする**

```powershell
pwsh -NoProfile -File .\tests\Test-ClaudeCredentialState.ps1 -RepoRoot (Get-Location).Path
pwsh -NoProfile -File .\tests\Test-AIUsageGauge.ps1 -RepoRoot (Get-Location).Path
```

Expected: `Claude credential state tests passed`と`AI Usage Gauge static tests passed`。

- [ ] **Step 5: PowerShell構文とUTF-8 BOMを確認する**

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Get-Location) 'Start-AIUsageGauge.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count) { throw ($errors.Message -join '; ') }
$bytes = [IO.File]::ReadAllBytes((Join-Path (Get-Location) 'Start-AIUsageGauge.ps1'))
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    throw 'Start-AIUsageGauge.ps1 must retain its UTF-8 BOM.'
}
```

Expected: 構文エラーなし、BOM確認成功。

- [ ] **Step 6: コミットする**

```powershell
git add Start-AIUsageGauge.ps1 tests/Test-ClaudeCredentialState.ps1 tests/Test-AIUsageGauge.ps1
git commit -m "fix: keep Claude reset times visible"
```

### Task 2: 全体検証と実機反映を完了する

**Files:**
- Modify: `docs/superpowers/plans/2026-09-27-claude-reset-visibility.md`
- Deploy: `C:\Users\syota\AI-Usage-Gauge\AI-Usage-Gauge-v0.1.0\Start-AIUsageGauge.ps1`

- [ ] **Step 1: 全テストを実行する**

```powershell
$repoRoot = (Get-Location).Path
foreach ($test in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter 'Test-*.ps1' | Sort-Object Name) {
    & pwsh -NoProfile -File $test.FullName -RepoRoot $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "$($test.Name) failed with exit code $LASTEXITCODE" }
}
git diff --check
```

Expected: Claude mapping、認証、Codex、ヘルス復旧、設定、画面位置を含む全テスト成功、差分形式エラーなし。

- [ ] **Step 2: 正規のWPFゲージだけを停止する**

`Start-AIUsageGauge.ps1`の`Test-GaugeProcessCommandLine`と同じWindows引数解析を使い、次の正規パスが`-File`引数に指定されたプロセスだけを停止する。

```text
C:\Users\syota\AI-Usage-Gauge\AI-Usage-Gauge-v0.1.0\Start-AIUsageGauge.ps1
```

自分自身、他のPowerShell、Claude、Codex、tmux作業プロセスは停止しない。

- [ ] **Step 3: 検証済みスクリプトを配置して再起動する**

```powershell
$source = Join-Path (Get-Location) 'Start-AIUsageGauge.ps1'
$destination = 'C:\Users\syota\AI-Usage-Gauge\AI-Usage-Gauge-v0.1.0\Start-AIUsageGauge.ps1'
Copy-Item -LiteralPath $source -Destination $destination -Force
Start-Sleep -Milliseconds 700
Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') `
    -ArgumentList @('//B', '//Nologo', 'C:\Users\syota\AI-Usage-Gauge\AI-Usage-Gauge-v0.1.0\Start-AIUsageGauge-hidden.vbs') `
    -WindowStyle Hidden
```

- [ ] **Step 4: 実機状態を確認する**

トークンやコマンドライン本文を出力せず、次を確認する。

- 正規のWPFゲージプロセスが1件。
- 配置元と配置先のSHA-256が一致。
- 配置先のPowerShell 7構文エラーが0件。
- 配置先がUTF-8 BOMを保持。
- 公式usage APIを追加で呼ばず、既存の3分更新でreset表示が更新される。

- [ ] **Step 5: mainへ統合して再検証する**

```powershell
git switch main
git merge --ff-only fix/claude-reset-visibility
$repoRoot = (Get-Location).Path
foreach ($test in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter 'Test-*.ps1' | Sort-Object Name) {
    & pwsh -NoProfile -File $test.FullName -RepoRoot $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "$($test.Name) failed with exit code $LASTEXITCODE" }
}
```

Expected: fast-forward成功、全テスト成功。

- [ ] **Step 6: GitHubとNotionを更新する**

```powershell
git push origin main
git rev-parse HEAD
git ls-remote origin refs/heads/main
```

ローカルとGitHubの`main` SHA一致を確認する。既存Notionページへ、原因、reset応答確認、表示優先順位修正、実機再起動、テスト結果、最終SHAを追記する。秘密情報は保存しない。
