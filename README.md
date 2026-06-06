# AI Usage Gauge

> **Fork notice**
> このリポジトリは [ryojihido/AI-Usage-Gauge](https://github.com/ryojihido/AI-Usage-Gauge) のフォークで、個人用にカスタマイズしたものです。
> オリジナル作者・MIT ライセンスはそのまま保持しています。
>
> **オリジナルからの変更点:**
> - `RefreshSeconds` 既定値を `60` → `180` 秒に変更（API リクエスト頻度を 1/3 に削減）
> - `Get-FillBrush` の色ロジックを残量パーセントの 5 段階信号色に変更（10% 以下: 赤 / 25% 以下: 橙 / 50% 以下: 黄 / 75% 以下: 黄緑 / 76% 以上: 緑）。短期・長期共通の判定。
> - Claude OAuth トークンの自動更新を堅牢化（先回り refresh / 失効30分前に更新、429 バックオフ + 状態の永続化で再起動しても連打しない、refresh 前にファイル再読込）。再ログインの手間を最小化。

---

<img width="632" height="256" alt="image" src="https://github.com/user-attachments/assets/4481dd8c-65b5-480b-b689-2a0ee7ec80b7" />

CodexPets の近くに表示する、Codex / Claude の残り使用量ゲージです。
※画像のPetsは付属していません

Codex / Claude それぞれについて、短期枠（5時間）と長期枠（週/7日相当）の残り目安を表示します。
起動すると CodexPets のそばに出現し、Pets の位置を追従します。
Pets が非表示でもゲージ自体は機能します。

位置はドラッグで調整できます。

## できること

- Codex の短期枠（5時間）・長期枠の残り目安を表示
- Claude の短期枠（5時間）・7日枠の残り目安を表示
- CodexPets の近くに自動配置
- CodexPets の移動に追従
- CodexPets が非表示でも単体ゲージとして動作
- ドラッグで位置調整
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

## Claude OAuth 自動更新

Claude Code の標準 CLI は、OAuth アクセストークンの有効期限が十分残っている間は `.credentials.json` を更新しません。確認した Claude Code 2.1.149 では、残り時間が短いときだけ CLI 内部の refresh が動く挙動でした。

このため、AI Usage Gauge は `platform.claude.com/v1/oauth/token` を直接叩かず、期限切れ直前または期限切れ時だけ同梱の `Invoke-ClaudeOAuthRefresh.ps1` から標準 `claude.exe` を短時間起動します。通常時はローカルの `expiresAt` を読むだけで、トークン値は表示しません。

自動更新タスクを登録する場合:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install-ClaudeOAuthRefreshTask.ps1
```

登録されるタスクは、5分ごとにローカル期限を確認し、残り30秒以内または失効済みのときだけ Claude CLI を起動します。スリープ復帰イベントでも同じ helper を実行します。タスクは `wscript.exe` 経由で非表示実行されるため、通常の期限チェックでターミナルは開きません。

## 操作

- ドラッグ: ゲージ位置を調整
- 右クリック: ゲージを閉じる

Claude の認証が失効して自動更新できない場合は、Claude 欄に `🔑 再ログイン要` と表示します。その表示をクリックすると、デスクトップの `Claude再ログイン.lnk` または同梱の `Claude-relogin.cmd` を起動します。

ドラッグで移動した場合、その起動中は CodexPets からの相対位置として追従します。

## 仕組みと注意

このツールは非公式の補助ツールです。
OpenAI、Anthropic、Codex Desktop、Claude Code の公式ツールではありません。

Codex側は、ローカルの Codex ログイン情報を使って現在の使用量エンドポイントを読みます。

Claude側は、Claude Code のOAuthログイン情報を使って最小の Messages API リクエストを送り、返ってくる rate-limit ヘッダーから残量を推定します。
そのため、Claude側の確認は小さなClaude使用量としてカウントされる可能性があります。

APIやローカル状態ファイルの仕様が変わると、予告なく動かなくなる可能性があります。

## セキュリティ

- トークンを画面に表示する処理はありません。
- トークンをGitHubへアップロードする処理はありません。
- 自分の `.codex` フォルダや `.claude` フォルダを共有しないでください。
- `auth.json`、`.credentials.json`、ログ、SQLite、Cookie、Cache、スクリーンショットなどを公開リポジトリに入れないでください。

## ライセンス

MIT License です。

詳細は [LICENSE](./LICENSE) を確認してください。
