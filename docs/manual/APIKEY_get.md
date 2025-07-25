APIを利用するための準備（所要時間：約3分）
APIを利用することで、これまでの面倒なコピー＆ペースト作業が一切不要になり、スクリプトを実行するだけで全自動でコミットメッセージと日誌が生成されるようになります。

そのために、一度だけ「APIキー」というものを取得し、あなたのPCに設定する必要があります。

APIキーとは？
一言でいうと、「あなたのプログラムが、GoogleのAIと会話することを許可する、特別な通行証」です。 この通行証をプログラムに渡しておくことで、プログラムはあなたに代わってAIと直接通信できるようになります。

ステップ1：APIキー（通行証）を取得する
Webブラウザで Google AI Studio を開きます。（Googleアカウントでのログインが必要です）
ページが表示されたら、Get API key というボタンをクリックします。
Create API key in new project というボタンをクリックします。
あなたのAPIキー（通行証）が生成され、画面に表示されます。この長い文字列が通行証の本体です。Copy ボタンをクリックして、キーをクリップボードにコピーしてください。
これで、通行証を手に入れることができました。

ステップ2：APIキー（通行証）をPCの安全な場所に保管する
取得したAPIキーは、非常に重要な個人情報です。ファイルに直接書き込むと、誤ってGitHubなどに公開してしまう危険があります。

そこで、「環境変数」という、PCのユーザーごとに用意された安全な保管庫にキーを保存します。

PowerShellを開き、以下のコマンドを1行ずつ実行してください。

まず、先ほどコピーしたAPIキーを、以下のコマンドの ここにAPIキーを貼り付け の部分にペーストして実行します。

powershell
$apiKey = "ここにAPIキーを貼り付け"
次に、そのキーをあなたのPCの環境変数（安全な保管庫）に保存します。以下のコマンドをそのまま実行してください。

powershell
[System.Environment]::SetEnvironmentVariable("GEMINI_API_KEY", $apiKey, "User")
（"User" を指定することで、この設定が今ログインしているあなた専用になり、他のユーザーやシステム全体に影響を与えないため安全です。）

設定を反映させるため、開いているPowerShellウィンドウをすべて閉じて、新しいウィンドウを開き直してください。