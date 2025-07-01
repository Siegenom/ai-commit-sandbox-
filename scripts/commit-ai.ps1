<#
.SYNOPSIS
    AI-assisted Git commit and devlog generation script for PowerShell.
.DESCRIPTION
    This script automates the process of creating a commit and a development log.
    It gathers context from Git, generates a prompt for an AI, retrieves the AI's response
    from the clipboard, and then performs the git commit and push operations.
#>

# --- Environment Setup ---
# コンソールの入出力エンコーディングをUTF-8に設定し、文字化けを防ぐ
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Configuration ---
# スクリプトの場所を基準にパスを自動設定
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent -Path $PSScriptRoot
$LogDir = Join-Path -Path $ProjectRoot -ChildPath "docs\devlog"
$TemplateFile = Join-Path -Path $LogDir -ChildPath "_template.md"
$Today = (Get-Date).ToString("yyyy-MM-dd")
$LogFile = Join-Path -Path $LogDir -ChildPath "$($Today).md"

# trueに設定すると、スクリプト実行時にステージングされていない変更を自動で追加するか尋ねます。
$EnableAutoStaging = $true

# --- Main Logic ---
Write-Host "🤖 AIによるコミットと日誌生成を開始します..." -ForegroundColor Cyan

if ($EnableAutoStaging) {
    # 未ステージの変更を確認し、ユーザーに追加を促す
    git diff --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "🔍 未ステージの変更が検出されました。" -ForegroundColor Yellow
        git status --short
        $response = Read-Host "👉 これらの変更をすべてステージングしますか？ (y/n)"
        if ($response -match '^[Yy]') {
            Write-Host "✅ すべての変更をステージングします..." -ForegroundColor Green
            git add .
        }
        else {
            Write-Host "ℹ️ ステージングはスキップされました。現在ステージング済みの変更のみがコミット対象になります。" -ForegroundColor Yellow
        }
    }
}

# 1. Gitからコンテキストを収集
Write-Host "🔍 Gitから情報を収集中..."
$gitDiff = (git diff --staged | Out-String).Trim()

if ([string]::IsNullOrEmpty($gitDiff)) {
    Write-Host "⚠️ ステージングされた変更がありません。'git add'でコミットしたい変更をステージングしてください。" -ForegroundColor Red
    exit 1
}

$changedFiles = (git diff --staged --name-only | ForEach-Object { "  - $_" }) -join [System.Environment]::NewLine
$currentBranch = (git rev-parse --abbrev-ref HEAD | Out-String).Trim()

# 2. テンプレートを読み込み、AIへのプロンプトを生成
if (-not (Test-Path $TemplateFile)) {
    Write-Host "❌ テンプレートファイルが見つかりません: $TemplateFile" -ForegroundColor Red
    exit 1
}
$templateContent = (Get-Content $TemplateFile -Raw -Encoding UTF8) -replace '{{DATE}}', $Today

$aiPrompt = @"
あなたは世界クラスのソフトウェアエンジニアリングアシスタントです。
以下の開発コンテキストを分析し、指定されたフォーマットでアウトプットを生成してください。

**重要: 出力フォーマット**
1行目: Conventional Commits形式のコミットメッセージのみ。
2行目: `---LOG_SEPARATOR---` という区切り文字のみ。
3行目以降: Markdown形式の開発日誌。開発日誌は、提供されたテンプレートの指示に従って記述してください。

---

### 開発コンテキスト (Development Context)
*   現在のブランチ: $($currentBranch)
*   変更されたファイル:
$($changedFiles)
*   具体的な差分 (diff):
```diff
$($gitDiff)
```

========================================

### アウトプットのテンプレート (この下に生成してください)

(ここにコミットメッセージ)
---LOG_SEPARATOR---
$($templateContent)
"@

# 3. ユーザーにプロンプトを提示し、AIの回答を待つ
Set-Clipboard -Value $aiPrompt
Write-Host "✅ AIへの指示プロンプトを生成し、クリップボードにコピーしました。" -ForegroundColor Green
Write-Host "---"
Write-Host "（プロンプトはクリップボードにコピー済みです。AIチャットに貼り付けてください）"
Write-Host "---"
Read-Host "👆 AIが生成した全文をクリップボードにコピーしてから、このウィンドウでEnterキーを押してください"

$aiResponse = Get-Clipboard

# 4. AIの応答をパースする
$responseParts = $aiResponse -split '---LOG_SEPARATOR---', 2
$commitMsg = $responseParts[0].Trim()
$logContent = $responseParts[1].Trim()

if ([string]::IsNullOrEmpty($commitMsg) -or [string]::IsNullOrEmpty($logContent)) {
    Write-Host "❌ AIの応答のパースに失敗しました。クリップボードの内容とフォーマットを確認してください。" -ForegroundColor Red
    exit 1
}

# 5. ユーザーによる確認と編集
Write-Host "---" -ForegroundColor DarkGray
Write-Host "🤖 AIが以下の内容を生成しました:" -ForegroundColor Green
Write-Host "Commit Message: $($commitMsg)" -ForegroundColor Yellow
Write-Host "---"
Write-Host $logContent
Write-Host "---" -ForegroundColor DarkGray

$editResponse = Read-Host "👉 この内容でコミットしますか？ 手動で編集する場合は 'e' を入力してください (Y/n/e)"
if ($editResponse -match '^[Ee]') {
    # 手動編集フロー
    $newCommitMsg = Read-Host "✏️ 新しいコミットメッセージを入力してください (Enterのみで現在の値を維持)"
    if (-not [string]::IsNullOrWhiteSpace($newCommitMsg)) {
        $commitMsg = $newCommitMsg
    }

    Write-Host "✏️ 開発日誌をメモ帳で開きます。編集して保存後、メモ帳を閉じてください。" -ForegroundColor Cyan
    $tempLogFile = New-TemporaryFile
    Set-Content -Path $tempLogFile.FullName -Value $logContent -Encoding UTF8
    # メモ帳でファイルを開き、プロセスが終了するまで待つ
    Start-Process notepad.exe -ArgumentList $tempLogFile.FullName -Wait
    $logContent = Get-Content -Path $tempLogFile.FullName -Raw
    Remove-Item $tempLogFile.FullName
    Write-Host "✅ 編集内容を反映しました。" -ForegroundColor Green

} elseif ($editResponse -match '^[Nn]') {
    Write-Host "❌ 処理を中断しました。" -ForegroundColor Red
    exit 0
}

# 6. コミットと日誌の保存、プッシュを実行
Write-Host "📝 開発日誌を保存します: $LogFile"
Set-Content -Path $LogFile -Value $logContent
git add $LogFile

Write-Host "💬 コミットを実行します (Message: $commitMsg)" -ForegroundColor Cyan
git commit -m $commitMsg
 
$pushResponse = Read-Host "🚀 リモートリポジトリにプッシュしますか？ (y/n)"
if ($pushResponse -match '^[Yy]') {
    Write-Host "🚀 プッシュを実行します..." -ForegroundColor Cyan
    git push
} else {
    Write-Host "ℹ️ プッシュはスキップされました。" -ForegroundColor Yellow
}

Write-Host "✅ 完了しました！" -ForegroundColor Green