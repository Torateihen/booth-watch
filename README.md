# booth-watch

BOOTHショップの新商品・バージョンアップを検知して、DiscordのWebhookに通知する。
GitHub Actions で30分ごとに実行される。PCの電源とは無関係に動く。

## 仕組み

BOOTHの商品JSON（`https://booth.pm/ja/items/<id>.json`）を読んで、
前回の値を `state.json` に残して毎回比較している。
配布ファイル名に入っている `Ver1.4.0.zip` のようなバージョン表記を見て、
バージョンアップを判定する。

BOOTHのJSONには更新日時が無いため、この差分方式をとっている。

## 検知するもの

- 新商品
- バージョンアップ（配布ファイル名のVer表記の変化）
- 配布ファイルの差し替え
- 価格変更
- 売り切れ・販売終了
- 商品名の変更
- ショップ一覧からの消滅

商品説明の書き換えは既定では通知しない。通知したい場合は `-NotifyDescription` を付ける。

## セットアップ

1. このリポジトリの Settings → Secrets and variables → Actions で
   `BOOTH_WEBHOOK` という名前のシークレットを作り、DiscordのWebhook URLを入れる。
2. Actions タブから `BOOTH更新監視` を一度手動実行して動作を確認する。

`state.json` は実行ごとにコミットされる。これによりGitHubの
「60日間動きが無いとスケジュールが止まる」仕様も回避される。

## 別のショップを見る

`.github/workflows/booth-watch.yml` の `-Shop bbeyemtkw` を書き換える。

## 手元で試す

```powershell
./booth-watch.ps1 -DryRun
```

`-DryRun` を付けるとDiscordには投げず、画面に出すだけになる。

## 注意

- BOOTHの非公式エンドポイントを使っている。仕様変更で動かなくなる可能性はあるが、
  その場合は取得失敗のログが出るだけで、誤った通知は飛ばない。
- GitHubのcronは混雑時に数分〜30分ほど遅れることがある。
