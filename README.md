# AI Usage Gauge

> **Fork notice**
> このリポジトリは [ryojihido/AI-Usage-Gauge](https://github.com/ryojihido/AI-Usage-Gauge) のフォークで、個人用にカスタマイズしたものです。
> オリジナル作者・MIT ライセンスはそのまま保持しています。
>
> **オリジナルからの変更点:**
> - `RefreshSeconds` 既定値を `60` → `180` 秒に変更（API リクエスト頻度を 1/3 に削減）
> - `Get-FillBrush` の色ロジックを残量パーセントの 5 段階信号色に変更（10% 以下: 赤 / 25% 以下: 橙 / 50% 以下: 黄 / 75% 以下: 黄緑 / 76% 以上: 緑）。短期・長期共通の判定。
> - Claude OAuth トークンの自動更新を堅牢化（標準 Claude CLI に refresh を委譲 / hidden scheduled task でローカル期限を確認 / ログオン・スリープ復帰で自己修復 / 429 バックオフ + 状態の永続化）。再ログインの手間を最小化。
> - Watchdog と診断コマンドを追加（既存の hidden refresh task から Gauge の生存確認 / Claude refresh task の修復 / トークン非表示の状態確認）。
> - 低残量/認証異常通知、stale 表示、ドラッグ位置の永続化、外部 `settings.json`、インストール/ZIP作成スクリプトを追加。
> - Graphite デザインへ刷新し、Codex は共有プラン上限の `5h` / `7d`、Claude は `5h` / `7d` / `Fable` を表示。
> - 30秒 heartbeat と確認付き自動復旧、接続中モニター内への自動復帰を追加。

---

<img width="632" height="256" alt="image" src="https://github.com/user-attachments/assets/4481dd8c-65b5-480b-b689-2a0ee7ec80b7" />

CodexPets の近くに表示する、Codex / Claude の残り使用量ゲージです。
※画像のPetsは付属していません

Codex・Work・ワークスペースエージェントなどで共有されるプラン上限を、Codex欄の `5h` / `7d` として表示します。Claude は `5h` / `7d` / `Fable` の残り目安を表示します。
起動すると CodexPets のそばに出現し、Pets の位置を追従します。
Pets が非表示でもゲージ自体は機能します。

位置はドラッグで調整できます。

## できること

- Codex・Workなどで共有されるプラン上限の `5h` / `7d` 残量を表示
- Claude の `5h` / `7d` / `Fable` 残量を表示
- 落ち着いた Graphite 配色で状態を5段階表示
- CodexPets の近くに自動配置
- CodexPets の移動に追従
- CodexPets が非表示でも単体ゲージとして動作
- ドラッグで位置調整（再起動後も位置を復元）
- モニター構成変更後もゲージ全体を接続中の画面内へ自動復帰
- API取得失敗時に古い値を `stale` として明示
- 低残量やClaude再ログイン要否をWindows通知
- ターミナルなしで起動できる VBS ランチャー付き

## 動作環境

- Windows
- PowerShell 7 for Windows
  - `pwsh` コマンドで起動できる状態が必要です。
- Codex Desktop
  - Codexゲージを使う場合は、Codex Desktopにログイン済みである必要があります。
  - Pets追従を使う場合は、Codexのpet/avatar overlayが有効である必要があります。
- Claude Code
  - Claudeゲージを使う場合は、Claude CodeにOAuthログイン済みである必要があります。
  - APIキーだけでClaude Codeを使っている環境では、Claudeゲージは表示できない場合があります。
- インターネット接続
  - Codex / Anthropic の現在のエンドポイントへアクセスします。

## 起動手順

1. このリポジトリ一式、または release ZIP をダウンロードします。
2. ZIP の場合は、すべてのファイルを同じフォルダに展開します。
3. 初回は `Start-AIUsageGauge.cmd` を実行します。

```powershell
.\Start-AIUsageGauge.cmd
```

初回に `.cmd` を使うと、PowerShell 7 が見つからない場合などのエラーが画面に表示されます。

動作確認後、ターミナルを出さずに起動したい場合は次を使います。

```powershell
.\Start-AIUsageGauge-hidden.vbs
```

PowerShellから直接起動する場合:

```powershell
pwsh -STA -ExecutionPolicy Bypass -File .\Start-AIUsageGauge.ps1
```

表示位置や更新間隔を指定する場合:

```powershell
pwsh -STA -ExecutionPolicy Bypass -File .\Start-AIUsageGauge.ps1 -Placement right -RefreshSeconds 60
```

`Start-AIUsageGauge-hidden.vbs` だけを配布・移動しても動きません。
必ず `Start-AIUsageGauge.ps1` と同じフォルダに置いてください。

インストール、デスクトップ/スタートアップショートカット作成、Claude refresh task 修復、release ZIP 作成をまとめて行う場合:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install-AIUsageGauge.ps1
```

## 設定

`settings.json` で更新間隔、配置、通知、stale 判定、位置保存を変更できます。スクリプトを直接編集する必要はありません。

```json
{
  "RefreshSeconds": 180,
  "Placement": "left",
  "EnableCodex": true,
  "EnableClaude": true,
  "EnableNotifications": true,
  "NotificationThresholdPercent": 10,
  "NotificationCooldownMinutes": 60,
  "StaleAfterMinutes": 5,
  "LogRetentionDays": 2,
  "PersistWindowPosition": true,
  "HealthHeartbeatSeconds": 30,
  "HealthStaleMinutes": 10,
  "HeartbeatConfirmationSeconds": 10,
  "ScreenMargin": 6,
  "PackageName": "AI-Usage-Gauge"
}
```

`LogRetentionDays` は `2` が既定です。ローカル日付で今日と前日分の `events.log` だけを残し、それより古い行は次回ログ書き込み時に削除します。

`HeartbeatConfirmationSeconds` は設定値として10秒ですが、実際の確認待ちは正常な30秒 heartbeat を1回以上待てるよう、`HealthHeartbeatSeconds + 5秒`（既定35秒）より短くなりません。

## Claude OAuth 自動更新

Claude Code の標準 CLI は、OAuth アクセストークンの有効期限が十分残っている間は `.credentials.json` を更新しません。AI Usage Gauge はaccess tokenが失効直前になったときだけ、CLI内部の標準refreshを利用します。

このため、AI Usage Gauge は `platform.claude.com/v1/oauth/token` を直接叩かず、期限切れ直前または期限切れ時だけ同梱の `Invoke-ClaudeOAuthRefresh.ps1` から標準 `claude.exe` を短時間起動します。通常時はローカルの `expiresAt` を読むだけで、トークン値は表示しません。

自動更新タスクを登録する場合:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install-ClaudeOAuthRefreshTask.ps1
```

登録されるタスクは、5分ごとにローカルの `expiresAt` だけを確認し、残り30秒以内または失効済みのときだけ Claude CLI を起動します。期限が十分残っている通常時は、OAuth エンドポイントも Claude CLI も呼びません。

access tokenとは別に、`/login`で作られたrefresh login自体にも期限があります。refresh tokenが有効な間は自動更新できますが、refresh loginまで期限切れになった後は、新しい認証情報を端末だけで生成することはできません。その場合はCLIの無効な再試行を止め、ゲージに `🔑 再ログイン要` を表示します。refresh loginの期限が3日以内に近づいた場合は、失効前に `login renewal due` と通知します。

ログオン時とスリープ復帰時にも同じ helper を実行します。従来の復帰イベントに加え、Surface などの Modern Standby 復帰（`Microsoft-Windows-Kernel-Power` / Event ID `507`）にも対応し、PC 再起動や長時間スリープ後に直ちに自己復旧します。タスクは `wscript.exe` 経由で非表示実行されるため、通常の期限チェックでターミナルは開きません。

## Watchdog と診断

既存の `ClaudeOAuthRefresh` scheduled task は、5分ごとに Watchdog も非表示で呼び出します。Gauge は `%LOCALAPPDATA%\AIUsageGauge\health.json` へ30秒ごとにトークンを含まない heartbeat を書きます。Watchdog は10分以上停止した heartbeat を再確認し、応答が戻らない場合だけ `Start-AIUsageGauge-hidden.vbs` から再起動します。

停止対象は、PID・プロセス開始時刻・Windows実引数を再検証し、正規のインストール先にある `-File ... Start-AIUsageGauge.ps1` を実行中の1プロセスだけです。別の `pwsh` や `powershell` は停止しません。スリープ復帰時は直ちに heartbeat を更新し、通常動作中の誤停止を防ぎます。

Watchdog を手動で実行した場合は、Claude refresh task が壊れている場合も同梱 installer で修復を試みます。scheduled task から呼ばれる通常経路では、自分自身のタスク定義を書き換えないため、権限エラーを増やしません。

状態確認は次のコマンドで実行できます。トークン値は表示しません。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Show-AIUsageGaugeStatus.ps1
```

機械読み取り用には JSON 出力もできます。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Show-AIUsageGaugeStatus.ps1 -Json
```

## 操作

- ドラッグ: ゲージ位置を調整
- 右クリック: ゲージを閉じる

Claude の認証が失効して自動更新できない場合は、Claude 欄に `🔑 再ログイン要` と表示します。その表示をクリックすると、同梱の `Claude-relogin.cmd` が現在の標準CLIを検出して `claude auth login --claudeai` を直接起動します。コマンド入力は不要ですが、Anthropic公式のブラウザ画面でアカウント承認が1回必要です。

ドラッグで移動した場合、その起動中は CodexPets からの相対位置として追従します。

## 仕組みと注意

このツールは非公式の補助ツールです。
OpenAI、Anthropic、Codex Desktop、Claude Code の公式ツールではありません。

Codex側は、ローカルの Codex ログイン情報を使って現在の使用量エンドポイントを読みます。

Claude側は、Claude Code のOAuthログイン情報を使い、公式ホストの `GET https://api.anthropic.com/api/oauth/usage` から `5h` / `7d` / `Fable` の使用率を読みます。トークン値は表示・ログ保存せず、使用量確認のためのモデルリクエストも送りません。

APIやローカル状態ファイルの仕様が変わると、予告なく動かなくなる可能性があります。

## セキュリティ

- トークンを画面に表示する処理はありません。
- トークンをGitHubへアップロードする処理はありません。
- 自分の `.codex` フォルダや `.claude` フォルダを共有しないでください。
- `auth.json`、`.credentials.json`、ログ、SQLite、Cookie、Cache、スクリーンショットなどを公開リポジトリに入れないでください。
- `%LOCALAPPDATA%\AIUsageGauge\events.log` は token-free で記録し、今日と前日分だけを残します。さらに肥大化しないようサイズ上限でもローテーションします。

## ライセンス

MIT License です。

詳細は [LICENSE](./LICENSE) を確認してください。
