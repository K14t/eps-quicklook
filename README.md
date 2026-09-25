# EPS QuickLook

macOS Sonoma 以降でできなくなった「Finder で EPS を選んでスペースキーでプレビュー」を復活させる Quick Look 拡張です。Finder のアイコン（サムネイル）にも中身が表示されます。

- **Photoshop で保存した EPS** … 中に入っている画像そのものを取り出して表示します（高画質）。
- **Illustrator で保存した EPS** … EPS に埋め込まれたプレビュー画像（TIFF / XMP サムネイル）を表示します。小さい文字はつぶれることがあります。
- **PostScript を実行しません**（Ghostscript 等を使いません）。ファイルから画像データを読み出すだけなので、安全で軽量です。
- 対応 OS: macOS 12 以降（Apple シリコン / Intel 両対応）。

## インストール

1. [Releases](../../releases/latest) から `EPSQuickLook.zip` をダウンロードし、ダブルクリックで展開します。
2. `EPSQuickLook.app` を「アプリケーション」フォルダに移動します。
3. `EPSQuickLook.app` を一度開きます。
   - 「開けません」と表示されたら：**システム設定 →「プライバシーとセキュリティ」** を下までスクロールし、EPSQuickLook の **「このまま開く」** を押します（初回のみ）。
4. 「準備ができました」の画面が出たら閉じて OK です。
5. Finder で .eps ファイルを選んで **スペースキー**。上下キーで次のファイルに移れます。

表示されない場合は **システム設定 →「一般」→「ログイン項目と機能拡張」→「Quick Look」** で EPS QuickLook がオンになっているか確認してください。

## アンインストール

「アプリケーション」フォルダの `EPSQuickLook.app` をゴミ箱に入れるだけです。

## 仕組み

| 種類 | 表示に使うデータ |
| --- | --- |
| Photoshop EPS | `%ImageData:` で示される実画像（JPEG / バイナリ / ASCII hex / ASCII85） |
| DOS EPS（プレビュー付き） | 埋め込み TIFF プレビュー（パレット・グレー・RGB・白黒 2 値） |
| それ以外 | XMP の `xmpGImg:image` サムネイル |

Photoshop EPS 内の CMYK JPEG は通常の JPEG と色の極性が逆のため、起動時に macOS（ImageIO）の挙動を自動判定して補正しています。

## ビルド

GitHub Actions（`.github/workflows/build.yml`）が macOS 上でテスト・ビルド・署名（ad-hoc）を行い、`latest` リリースに `EPSQuickLook.zip` を置きます。手元でビルドする場合は Xcode と XcodeGen を用意し、ワークフローと同じコマンドを実行してください。

テスト用 EPS（`Tests/Fixtures`）は `scripts/make_fixtures.py` で生成した合成データです。

## ライセンス

MIT
