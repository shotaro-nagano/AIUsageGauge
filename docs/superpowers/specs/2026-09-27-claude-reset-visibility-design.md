# Claude reset表示優先順位修正設計

## 目的

Claude APIが返している5時間枠と7日枠のreset時間を、WPFデスクトップゲージで常に確認できるようにする。ログイン更新期限の警告、クリック再ログイン、Windows通知は維持する。

## 確認した原因

公式`https://api.anthropic.com/api/oauth/usage`は、現在も`five_hour.resets_at`と`seven_day.resets_at`を返している。実機確認では両方の値が存在し、WPF側の`Convert-ClaudeUsageResponse`も秒数へ正常変換している。

表示直前に`LoginRenewalDue`が真になると、`Update-Usage`がClaudeフッターを`login renewal due`へ上書きしていた。現在のrefreshトークン期限は3日以内で、この分岐が継続的に成立している。resetが消える原因はAPIやマッピングではなく、表示優先順位である。

## 表示仕様

Claude利用量取得に成功した場合、フッターは常に次の形式を維持する。

```text
reset <5h残り時間> / <7d残り時間>
```

`LoginRenewalDue`が真の場合は、フッターを変更せずタイトルを次へ変更する。

```text
Claude rate · renew
```

この状態では`ClaudeNeedsRelogin=true`を維持するため、Claudeフッターをクリックしたときの再ログイン導線は引き続き利用できる。既存のWindows警告通知も維持する。

ログイン更新期限が近くない場合は、タイトルを従来どおり`Claude rate`とする。認証切れ、429、通信失敗、無効化状態では、既存の専用フッター表示を優先し、resetを表示しない。

## 変更範囲

- `Start-AIUsageGauge.ps1`のClaude成功時UI分岐だけを変更する。
- API、認証、refresh、利用量マッピング、画面サイズ、バー表示は変更しない。
- 稼働中ファイルにだけ存在する通知タイマーの`.GetNewClosure()`修正を追跡ソースへ取り込み、デプロイ時の退行を防ぐ。
- インストール済みファイルは、追跡ソースの検証後に置き換える。

## テスト

自動テストで次を固定する。

- Claude成功時フッターが5時間・7日のreset値を整形する。
- `LoginRenewalDue`分岐がフッターを`login renewal due`で上書きしない。
- 同分岐がタイトルを`Claude rate · renew`へ変更する。
- 同分岐がクリック再ログイン状態とWindows通知を維持する。
- 通知タイマーのコールバックが`.GetNewClosure()`で自身のタイマーを保持する。
- 既存の認証切れ、Fable、Codex、位置補正、ヘルスチェックを含む全テストが成功する。

## 実機反映

PowerShell 7で構文検証後、正規パスの`-File ...Start-AIUsageGauge.ps1`プロセスだけを停止する。検証済みスクリプトを既知のインストール先へ配置し、`Start-AIUsageGauge-hidden.vbs`から非表示で再起動する。

再起動後、デスクトップゲージが1件だけ動作し、Claudeフッターにreset時間、タイトルに更新警告が表示されることを確認する。トークン値やAuthorizationヘッダーは画面・ログ・テストへ出力しない。

## 完了条件

Claudeの5時間・7日reset時間が表示され、更新期限警告と再ログイン導線も失われない。利用者の手動再配置や設定変更は不要とする。
