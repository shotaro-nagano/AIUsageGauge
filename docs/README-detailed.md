# AI Usage Gauge

Unofficial floating usage gauge for Codex Desktop and Claude Code. It follows the Codex pet and uses a calm Graphite interface.

Languages: [English](#english) | [日本語](#日本語)

---

## English

### What It Does

AI Usage Gauge is a small always-on-top Windows overlay.

It:

- follows the Codex Desktop pet
- shows the shared Codex and Work `5h` and `7d` remaining quotas
- shows Claude `5h`, `7d`, and `Fable` remaining quotas
- updates usage periodically without increasing request frequency aggressively
- can be moved manually by dragging
- returns the full gauge to an active monitor after display changes
- writes a token-free heartbeat every 30 seconds for confirmed automatic recovery

The Codex gauge classifies the optional usage windows by duration instead of
depending on their primary/secondary order:

- an 18,000-second window as `5h`
- a 604,800-second window as `7d`

ChatGPT presents these plan limits as shared by Codex, Work, workspace agents,
and the other products listed on its usage page.

The Claude gauge performs an OAuth-authenticated `GET https://api.anthropic.com/api/oauth/usage` and reads:

- `five_hour.utilization` as the 5-hour usage
- `seven_day.utilization` as the 7-day usage
- the weekly scoped limit whose model display name is `Fable`

It displays remaining percent as:

```text
100 - used_percent
```

### Requirements

- Windows
- PowerShell 7 for Windows (`pwsh`)
- Codex Desktop app
- Codex pet/avatar overlay enabled
- A local Codex login at:

```text
C:\Users\<you>\.codex\auth.json
```

- A Codex state file at:

```text
C:\Users\<you>\.codex\.codex-global-state.json
```

Pet-following works only when Codex Desktop writes `electron-avatar-overlay-bounds` to that state file. If Codex changes its internal state format, following may stop working.

- For the Claude gauge, a local Claude Code OAuth login at:

```text
C:\Users\<you>\.claude\.credentials.json
```

If `CLAUDE_CONFIG_DIR` is set, the script reads `.credentials.json` from that directory instead.

### How To Run

Download the full repository or release ZIP. Keep these launcher files in the same folder as `Start-AIUsageGauge.ps1`.

For first run, use the terminal launcher so missing prerequisites are visible:

```powershell
.\Start-AIUsageGauge.cmd
```

No terminal window:

```powershell
.\Start-AIUsageGauge-hidden.vbs
```

With a terminal window:

```powershell
pwsh -STA -ExecutionPolicy Bypass -File .\Start-AIUsageGauge.ps1
```

Options:

```powershell
pwsh -STA -ExecutionPolicy Bypass -File .\Start-AIUsageGauge.ps1 -Placement right -RefreshSeconds 60
```

Do not distribute only `Start-AIUsageGauge-hidden.vbs`; it is only a launcher for `Start-AIUsageGauge.ps1`.

### Controls

- Left-drag: move the gauge manually
- Right-click: close the gauge

If you drag the gauge, it persists the offset relative to the pet. A 6 px margin keeps the full gauge inside the nearest active monitor.

### Automatic Recovery

The gauge writes `%LOCALAPPDATA%\AIUsageGauge\health.json` every 30 seconds. The hidden watchdog treats the UI as frozen only after 10 minutes without a heartbeat and a second confirmation. It revalidates the PID, exact process start time, Windows command-line arguments, and canonical `-File ... Start-AIUsageGauge.ps1` path immediately before stopping that one process. It never stops unrelated PowerShell processes. Resume events update the heartbeat immediately.

### Security

- The script reads your local Codex `auth.json` at refresh time.
- It uses the local Codex access token only to call the Codex usage endpoint.
- The script reads your local Claude Code `.credentials.json` at refresh time.
- It uses the Claude Code OAuth access token only for the official `/api/oauth/usage` GET.
- The usage check does not send a model request.
- If the Claude OAuth token expires, the script may refresh it and write the refreshed values back to Claude Code's credentials file.
- Access-token refresh remains automatic while the stored refresh login is valid. If that login itself expires, the gauge stops futile CLI retries, shows `relogin required`, and launches `claude auth login --claudeai` when clicked. The official browser approval cannot be automated. A warning appears three days before the stored refresh login expires.
- It does not print, upload, or commit tokens.
- Do not share your real `.codex` folder.
- Do not share your real `.claude` folder.
- Do not commit `auth.json`, logs, SQLite files, cookies, cache files, screenshots, or copied app state.
- Review scripts before running them, especially if you received them from someone else.

### Disclaimer

This is an unofficial helper and is not affiliated with, endorsed by, or supported by OpenAI.

It depends on internal Codex Desktop state files, local Claude Code credential storage, and the current ChatGPT/Codex and Anthropic API behavior:

```text
https://chatgpt.com/backend-api/wham/usage
https://api.anthropic.com/api/oauth/usage
```

These details may change without notice. The tool may stop working after a Codex Desktop, Claude Code, or API update.

---

## 日本語

### これは何？

AI Usage Gauge は、Codex Desktop のペット横に表示する、Codex Desktop と Claude Code 向けの非公式の小さな使用量ゲージです。

できること:

- Codex Desktop のペットに追従する
- Codex・Workなどで共有されるプラン上限の `5h` / `7d` の残り目安を表示する
- Claude の `5h` / `7d` / `Fable` の残り目安を表示する
- 使用量は定期更新しつつ、APIアクセスは増やしすぎない
- ドラッグで手動位置調整できる
- Graphite 配色で落ち着いて表示する
- モニター構成変更後も接続中の画面内へ自動復帰する

Codex欄は、API上のprimary/secondary順には依存せず、期間秒数で枠を分類します:

- 18,000秒の枠: `5h`
- 604,800秒の枠: `7d`

ChatGPTの使用状況画面では、これらはCodex・Work・ワークスペースエージェントなどで共有されるプラン上限として案内されています。

Claude で取得している値:

- `five_hour.utilization`: 5時間枠の使用済み率
- `seven_day.utilization`: 7日枠の使用済み率
- `limits` 内の週次 `Fable` 枠

Claude 側は、Claude Code のOAuth資格情報で `GET https://api.anthropic.com/api/oauth/usage` を呼びます。モデルリクエストは送信しません。

表示している値:

```text
100 - used_percent
```

つまり「残り%」です。

### 動作環境

- Windows
- PowerShell 7 for Windows (`pwsh`)
- Codex Desktop アプリ
- Codex のペット/アバター表示が有効
- ローカルに Codex のログイン情報があること:

```text
C:\Users\<you>\.codex\auth.json
```

- ローカルに Codex の状態ファイルがあること:

```text
C:\Users\<you>\.codex\.codex-global-state.json
```

ペット追従は、Codex Desktop がこの状態ファイルに `electron-avatar-overlay-bounds` を保存している場合に動きます。Codex 側の内部仕様が変わると、追従できなくなる可能性があります。

- Claude ゲージを使う場合、ローカルに Claude Code のOAuthログイン情報があること:

```text
C:\Users\<you>\.claude\.credentials.json
```

`CLAUDE_CONFIG_DIR` を設定している場合は、そのディレクトリの `.credentials.json` を読みます。

### 起動方法

リポジトリ一式、または release ZIP 全体をダウンロードしてください。ランチャーファイルは `Start-AIUsageGauge.ps1` と同じフォルダに置く必要があります。

初回は、前提条件不足が見えるようにターミナルありのランチャーがおすすめです:

```powershell
.\Start-AIUsageGauge.cmd
```

ターミナルを出さずに起動:

```powershell
.\Start-AIUsageGauge-hidden.vbs
```

ターミナルありで起動:

```powershell
pwsh -STA -ExecutionPolicy Bypass -File .\Start-AIUsageGauge.ps1
```

オプション指定:

```powershell
pwsh -STA -ExecutionPolicy Bypass -File .\Start-AIUsageGauge.ps1 -Placement right -RefreshSeconds 60
```

`Start-AIUsageGauge-hidden.vbs` だけを配布しても動きません。これは `Start-AIUsageGauge.ps1` を起動するためのランチャーです。

### 操作

- 左ドラッグ: ゲージを手動で動かす
- 右クリック: ゲージを閉じる

ドラッグ位置は「ペットからの相対位置」として永続化します。モニター変更時は6 pxの余白を保ち、ゲージ全体を最寄りの接続中画面へ戻します。

### 自己診断と自動復旧

ゲージは `%LOCALAPPDATA%\AIUsageGauge\health.json` へ30秒ごとにトークンを含まない heartbeat を書きます。Watchdog は10分以上止まった状態をもう一度確認し、復帰しない場合だけ再起動します。停止直前にPID、正確な開始時刻、Windows実引数、正規の `-File ... Start-AIUsageGauge.ps1` パスを再検証し、その1プロセスだけを停止します。無関係な PowerShell プロセスは停止しません。従来のスリープ復帰イベントと Modern Standby 復帰（`Microsoft-Windows-Kernel-Power` / Event ID `507`）の両方で helper を実行し、heartbeat と表示を直ちに復旧します。

### セキュリティ

- スクリプトは更新時にローカルの Codex `auth.json` を読みます。
- Codex のアクセストークンは、使用量エンドポイントを読むためだけに使います。
- スクリプトは更新時にローカルの Claude Code `.credentials.json` を読みます。
- Claude Code のOAuthアクセストークンは、公式 `/api/oauth/usage` GET のためだけに使います。
- 使用量確認ではモデルリクエストを送信しません。
- Claude のOAuthトークンが期限切れの場合、refreshして Claude Code の認証ファイルへ書き戻す場合があります。
- 保存済みrefresh loginが有効な間はaccess tokenを自動更新します。refresh login自体が期限切れになった場合は、無効なCLI再試行を止めて「再ログイン要」を表示し、クリック時に `claude auth login --claudeai` を直接起動します。公式ブラウザでのアカウント承認だけは自動化できません。期限の3日前から更新警告を表示します。
- トークンを表示、アップロード、Gitコミットする処理はありません。
- 自分の `.codex` フォルダを共有しないでください。
- 自分の `.claude` フォルダを共有しないでください。
- `auth.json`、ログ、SQLite、Cookie、Cache、スクリーンショット、コピーしたアプリ状態ファイルを Git に入れないでください。
- 誰かから受け取った場合は、実行前にスクリプトの中身を確認してください。

### 免責

これは非公式ツールです。OpenAI 公式のツールではなく、OpenAI による保証やサポートもありません。

Codex Desktop の内部状態ファイル、Claude Code のローカル認証ファイル、現在の ChatGPT/Codex と Anthropic API の挙動に依存しています。

```text
https://chatgpt.com/backend-api/wham/usage
https://api.anthropic.com/api/oauth/usage
```

これらの仕様は予告なく変わる可能性があります。Codex Desktop、Claude Code、またはAPIのアップデート後に動かなくなる場合があります。
