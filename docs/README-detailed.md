# AI Usage Gauge

Unofficial floating usage gauge for Codex Desktop and Claude Code. It follows the Codex pet and shows the remaining short-term and longer-term usage for both tools.

Languages: [English](#english) | [日本語](#日本語)

---

## English

### What It Does

AI Usage Gauge is a small always-on-top Windows overlay.

It:

- follows the Codex Desktop pet
- shows remaining Codex and Claude usage for the 5-hour window
- shows remaining Codex longer-term usage and Claude 7-day usage
- updates usage periodically without increasing request frequency aggressively
- can be moved manually by dragging

The Codex gauge reads:

- `primary_window.used_percent` as the 5-hour usage
- `secondary_window.used_percent` as the longer-term usage

The Claude gauge sends a minimal Claude Code OAuth-authenticated Messages API request and reads:

- `anthropic-ratelimit-unified-5h-utilization` as the 5-hour usage
- `anthropic-ratelimit-unified-7d-utilization` as the 7-day usage

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

If you drag the gauge, it remembers the offset relative to the pet for the current run.

### Security

- The script reads your local Codex `auth.json` at refresh time.
- It uses the local Codex access token only to call the Codex usage endpoint.
- The script reads your local Claude Code `.credentials.json` at refresh time.
- It uses the Claude Code OAuth access token only to call the Anthropic Messages API and read rate-limit headers.
- The Claude check sends a tiny model request, so it may count as Claude usage.
- If the Claude OAuth token expires, the script may refresh it and write the refreshed values back to Claude Code's credentials file.
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
https://api.anthropic.com/v1/messages
```

These details may change without notice. The tool may stop working after a Codex Desktop, Claude Code, or API update.

---

## 日本語

### これは何？

AI Usage Gauge は、Codex Desktop のペット横に表示する、Codex Desktop と Claude Code 向けの非公式の小さな使用量ゲージです。

できること:

- Codex Desktop のペットに追従する
- Codex と Claude の短期枠（5時間）の残り目安を表示する
- Codex の長期枠と Claude の7日枠の残り目安を表示する
- 使用量は定期更新しつつ、APIアクセスは増やしすぎない
- ドラッグで手動位置調整できる

Codex で取得している値:

- `primary_window.used_percent`: 5時間枠の使用済み%
- `secondary_window.used_percent`: 長期枠の使用済み%

Claude で取得している値:

- `anthropic-ratelimit-unified-5h-utilization`: 5時間枠の使用済み率
- `anthropic-ratelimit-unified-7d-utilization`: 7日枠の使用済み率

Claude 側は、Claude Code のOAuth資格情報で最小の Messages API リクエストを送り、そのレスポンスヘッダーから読み取ります。

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

ドラッグした場合、その起動中は「ペットからの相対位置」として追従します。

### セキュリティ

- スクリプトは更新時にローカルの Codex `auth.json` を読みます。
- Codex のアクセストークンは、使用量エンドポイントを読むためだけに使います。
- スクリプトは更新時にローカルの Claude Code `.credentials.json` を読みます。
- Claude Code のOAuthアクセストークンは、Anthropic Messages API を呼び、レート制限ヘッダーを読むためだけに使います。
- Claude 側の確認は小さなモデルリクエストを送るため、Claude の使用量に含まれる可能性があります。
- Claude のOAuthトークンが期限切れの場合、refreshして Claude Code の認証ファイルへ書き戻す場合があります。
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
https://api.anthropic.com/v1/messages
```

これらの仕様は予告なく変わる可能性があります。Codex Desktop、Claude Code、またはAPIのアップデート後に動かなくなる場合があります。
