﻿<#
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
$ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "prompt-config.json"
$Today = (Get-Date).ToString("yyyy-MM-dd")
$LogFile = Join-Path -Path $LogDir -ChildPath "$(Get-Date -Format 'yyyy-MM-dd-HHmmss').md"

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

$currentBranch = (git rev-parse --abbrev-ref HEAD | Out-String).Trim()
$stagedFiles = (git diff --staged --name-only | Out-String).Trim().Split([System.Environment]::NewLine) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

# 2. ユーザーから高レベルの目標を取得
Write-Host "🎯 このコミットの主な目標を簡潔に入力してください:" -ForegroundColor Cyan
$highLevelGoal = Read-Host

# 3. AIへの入力JSONを生成
Write-Host "📝 設定ファイルとコンテキストからAIへの入力JSONを生成中..."
if (-not (Test-Path $ConfigFile)) {
    Write-Host "❌ 設定ファイルが見つかりません: $ConfigFile" -ForegroundColor Red
    exit 1
}
$config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

# 入力用JSONオブジェクトを構築
$inputJson = [PSCustomObject]@{
    system_prompt = [PSCustomObject]@{
        persona                  = $config.ai_persona
        task                     = $config.task_instruction
        output_schema_definition = $config.output_schema
    }
    user_context  = [PSCustomObject]@{
        high_level_goal = $highLevelGoal
        git_context     = [PSCustomObject]@{
            current_branch = $currentBranch
            staged_files   = $stagedFiles
            diff           = $gitDiff
        }
    }
}

# JSONに変換
$aiPrompt = $inputJson | ConvertTo-Json -Depth 10

# 4. ユーザーにプロンプトを提示し、AIの回答を待つ
Set-Clipboard -Value $aiPrompt
Write-Host "✅ AIへの指示プロンプトを生成し、クリップボードにコピーしました。" -ForegroundColor Green
Write-Host "---"
Write-Host "（プロンプトはクリップボードにコピー済みです。AIチャットに貼り付けてください）"
Write-Host "---"
Read-Host "👆 AIが生成したJSONオブジェクトをクリップボードにコピーしてから、このウィンドウでEnterキーを押してください"

$aiResponse = Get-Clipboard

# 5. AIのJSON応答をパースする
Write-Host "🔄 AIのJSON応答をパースしています..."
try {
    $aiJson = $aiResponse | ConvertFrom-Json -ErrorAction Stop
    $commitMsg = $aiJson.commit_message.Trim()
    $devlog = $aiJson.devlog

    # 開発日誌のMarkdownコンテンツを動的に再構築
    # prompt-config.jsonのスキーマ定義に追従する
    $logContentParts = New-Object System.Collections.ArrayList
    $logContentParts.Add("開発日誌: $Today") | Out-Null

    # devlogオブジェクトのプロパティを動的にループ
    foreach ($property in $devlog.PSObject.Properties) {
        $propName = $property.Name
        $propValue = $property.Value.ToString().Trim()
        
        # prompt-config.jsonから対応するdescriptionを取得して見出しにする
        $propDescription = $config.output_schema.devlog.properties.$propName.description
        
        $logContentParts.Add("`n" + $propDescription) | Out-Null
        $logContentParts.Add($propValue) | Out-Null
    }
    $logContent = ($logContentParts -join [System.Environment]::NewLine).Trim()

}
catch {
    Write-Host "❌ AIの応答のパースに失敗しました。クリップボードの内容が有効なJSONであることを確認してください。" -ForegroundColor Red
    Write-Host "--- エラー詳細 ---"
    Write-Host $_.Exception.Message
    Write-Host "--------------------"
    exit 1
}

if ([string]::IsNullOrEmpty($commitMsg) -or [string]::IsNullOrEmpty($logContent) -or $null -eq $devlog) {
    Write-Host "❌ AIの応答に必要なキー（commit_message, devlog）が含まれていないか、内容が空です。JSONの内容を確認してください。" -ForegroundColor Red
    exit 1
}

# 6. ユーザーによる確認と編集
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
    Start-Process notepad.exe -ArgumentList $tempLogFile.FullName -Wait
    $logContent = Get-Content -Path $tempLogFile.FullName -Raw
    Remove-Item $tempLogFile.FullName
    Write-Host "✅ 編集内容を反映しました。" -ForegroundColor Green

} elseif ($editResponse -match '^[Nn]') {
    Write-Host "❌ 処理を中断しました。" -ForegroundColor Red
    exit 0
}

# 7. コミットと日誌の保存、プッシュを実行
Write-Host "📝 開発日誌を保存します: $LogFile"
Set-Content -Path $LogFile -Value $logContent -Encoding UTF8
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
