<#
.SYNOPSIS
    AI-assisted Git commit and devlog generation script for PowerShell.
#>

# --- Environment Setup ---
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Configuration ---
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent -Path $PSScriptRoot
$LogDir = Join-Path -Path $ProjectRoot -ChildPath "docs\devlog"
$ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "prompt-config.json"
$Today = (Get-Date).ToString("yyyy-MM-dd")
$LogFile = Join-Path -Path $LogDir -ChildPath "$(Get-Date -Format 'yyyy-MM-dd-HHmmss').md"
$EnableAutoStaging = $true

# --- Functions ---
function Edit-TextInEditor {
    param([string]$InitialContent)
    Write-Host "✏️ デフォルトのエディタで値を編集し、保存後、エディタを閉じてください。" -ForegroundColor Cyan
    $editorCommand = $env:EDITOR
    if ([string]::IsNullOrEmpty($editorCommand)) { $editorCommand = $env:VISUAL }
    if ([string]::IsNullOrEmpty($editorCommand)) {
        if ($env:OS -eq 'Windows_NT') { $editorCommand = "notepad.exe" }
        elseif ($PSVersionTable.Platform -eq 'MacOS' -or $PSVersionTable.Platform -eq 'Unix') {
            if (Get-Command open -ErrorAction SilentlyContinue) { $editorCommand = "open -W -t" }
            else {
                $editors = @("code --wait", "nano", "vim", "vi")
                $editorCommand = ($editors | ForEach-Object { if (Get-Command $_.Split(' ')[0] -ErrorAction SilentlyContinue) { $_; break } })
            }
        }
    }
    if ([string]::IsNullOrEmpty($editorCommand)) {
        Write-Error "編集に使用できるエディタが見つかりません。"; return $InitialContent
    }
    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile.FullName -Value $InitialContent -Encoding UTF8
        $editorParts = $editorCommand.Split(' ', 2); $editorExe = $editorParts[0]
        $editorArgs = if ($editorParts.Length -gt 1) { @($editorParts[1], $tempFile.FullName) } else { $tempFile.FullName }
        Start-Process -FilePath $editorExe -ArgumentList $editorArgs -Wait -PassThru -ErrorAction Stop
        return Get-Content -Path $tempFile.FullName -Raw
    } catch {
        Write-Error "エディタの起動またはファイルの読み込みに失敗しました: $_"; return $InitialContent
    } finally {
        if (Test-Path $tempFile.FullName) { Remove-Item $tempFile.FullName -Force }
    }
}

# --- Main Logic ---
Write-Host "🤖 AIによるコミットと日誌生成を開始します..." -ForegroundColor Cyan

if ($EnableAutoStaging) {
    git diff --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "🔍 未ステージの変更が検出されました。" -ForegroundColor Yellow
        git status --short
        $response = Read-Host "👉 これらの変更をすべてステージングしますか？ (y/n)"
        if ($response -match '^[Yy]') {
            Write-Host "✅ すべての変更をステージングします..." -ForegroundColor Green
            git add .
        } else {
            Write-Host "ℹ️ ステージングはスキップされました。" -ForegroundColor Yellow
        }
    }
}

Write-Host "🔍 Gitから情報を収集中..."
$gitDiff = (git diff --staged | Out-String).Trim()
if ([string]::IsNullOrEmpty($gitDiff)) {
    Write-Host '⚠️ ステージングされた変更がありません。''git add''でコミットしたい変更をステージングしてください。' -ForegroundColor Red
    exit 1
}
$currentBranch = (git rev-parse --abbrev-ref HEAD | Out-String).Trim()
$stagedFiles = (git diff --staged --name-only | Out-String).Trim().Split([System.Environment]::NewLine) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

Write-Host "🎯 このコミットの主な目標を簡潔に入力してください:" -ForegroundColor Cyan
$highLevelGoal = Read-Host

Write-Host "📝 設定ファイルとコンテキストからAIへの入力JSONを生成中..."
try {
    $configContent = Get-Content $ConfigFile -Raw -Encoding UTF8
    if ($configContent -and $configContent.StartsWith([char]0xFEFF)) {
        $configContent = $configContent.Substring(1)
    }
    $config = $configContent | ConvertFrom-Json
}
catch {
    Write-Host "❌ 設定ファイル '$ConfigFile' の読み込みまたはパースに失敗しました。" -ForegroundColor Red
    Write-Host "--- エラー詳細 ---"; Write-Host $_.Exception.Message
    exit 1
}

# [MODIFIED] Add language instruction to the main task instruction.
$langInstruction = ""
if ($config.devlog_language -eq 'japanese') {
    $langInstruction = "The entire 'devlog' object must be written in Japanese."
} else {
    $langInstruction = "The entire 'devlog' object must be written in English."
}
$fullTaskInstruction = "$($config.task_instruction) $langInstruction"


$inputJson = [PSCustomObject]@{
    system_prompt = @{ 
        persona = $config.ai_persona
        task = $fullTaskInstruction
        output_schema_definition = $config.output_schema 
    }
    user_context  = @{ 
        high_level_goal = $highLevelGoal
        git_context = @{ 
            current_branch = $currentBranch
            staged_files = $stagedFiles
            diff = $gitDiff 
        } 
    }
}
$aiPrompt = $inputJson | ConvertTo-Json -Depth 10

$aiResponse = ""
if ($config.use_api_mode) {
    Write-Host "🤖 APIを呼び出しています... ($($config.api_provider))" -ForegroundColor Cyan
    $adapterPath = Join-Path -Path $PSScriptRoot -ChildPath "api_adapters\invoke-$($config.api_provider)-api.ps1"
    if (-not (Test-Path $adapterPath)) {
        Write-Host "❌ APIアダプターのファイルが見つかりません！" -ForegroundColor Red
        exit 1
    }
    
    $tempPromptFile = $null
    try {
        $tempPromptFile = New-TemporaryFile
        Set-Content -Path $tempPromptFile.FullName -Value $aiPrompt -Encoding UTF8
        $aiResponse = & $adapterPath -PromptFilePath $tempPromptFile.FullName -ApiConfig $config
    }
    finally {
        if ($null -ne $tempPromptFile -and (Test-Path $tempPromptFile.FullName)) {
            Remove-Item -Path $tempPromptFile.FullName -Force
        }
    }

    if ($aiResponse -like "ERROR:*") {
        Write-Host "❌ API処理中にエラーが発生しました: $aiResponse" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ APIから応答を取得しました。" -ForegroundColor Green
} else {
    Set-Clipboard -Value $aiPrompt
    Write-Host "✅ AIへの指示プロンプトを生成し、クリップボードにコピーしました。" -ForegroundColor Green
    Read-Host "👆 AIが生成したJSONオブジェクトをクリップボードにコピーしてから、このウィンドウでEnterキーを押してください"
    $aiResponse = Get-Clipboard
}

if ([string]::IsNullOrWhiteSpace($aiResponse)) {
    Write-Host "❌ AIからの応答が空です。処理を中断します。" -ForegroundColor Red
    exit 1
}

Write-Host "🔄 AIのJSON応答をパースしています..."
try {
    $aiJson = $aiResponse | ConvertFrom-Json
    $commitMsg = $aiJson.commit_message.Trim()
    $devlog = $aiJson.devlog

    $logContentParts = New-Object System.Collections.ArrayList
    $logContentParts.Add("## 開発日誌: $Today") | Out-Null
    foreach ($property in $devlog.PSObject.Properties) {
        $propName = $property.Name
        $propValue = $property.Value.ToString().Trim()
        $propDescription = $config.output_schema.devlog.properties.$propName.description
        $logContentParts.Add("`n### $propDescription") | Out-Null
        $logContentParts.Add("`n$propValue") | Out-Null
    }
    $logContent = ($logContentParts -join [System.Environment]::NewLine).Trim()
}
catch {
    Write-Host "❌ AIの応答のパースに失敗しました。" -ForegroundColor Red
    Write-Host "--- エラー詳細 ---"; Write-Host $_.Exception.Message
    exit 1
}

if ([string]::IsNullOrEmpty($commitMsg) -or [string]::IsNullOrEmpty($logContent)) {
    Write-Host "❌ AIの応答に必要なキーが含まれていないか、内容が空です。" -ForegroundColor Red
    exit 1
}

Write-Host "---" -ForegroundColor DarkGray
Write-Host "🤖 AIが以下の内容を生成しました:" -ForegroundColor Green
Write-Host "Commit Message: $($commitMsg)" -ForegroundColor Yellow
Write-Host "---"
Write-Host $logContent
Write-Host "---" -ForegroundColor DarkGray

$editResponse = Read-Host '👉 この内容でコミットしますか？ 手動で編集する場合は ''e'' を入力してください (Y/n/e)'
if ($editResponse -match '^[Ee]') {
    $newCommitMsg = Read-Host "✏️ 新しいコミットメッセージを入力してください (Enterのみで現在の値を維持)"
    if (-not [string]::IsNullOrWhiteSpace($newCommitMsg)) {
        $commitMsg = $newCommitMsg
    }
    $logContent = Edit-TextInEditor -InitialContent $logContent
    Write-Host "✅ 編集内容を反映しました。"
} elseif ($editResponse -notmatch '^[Yy]?$') {
    Write-Host "❌ 処理を中断しました。" -ForegroundColor Red
    exit 0
}

if (-not (Test-Path -Path $LogDir -PathType Container)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

Write-Host "📝 開発日誌を保存します: $LogFile"
Set-Content -Path $LogFile -Value $logContent -Encoding UTF8
git add $LogFile

Write-Host "💬 コミットを実行します (Message: $commitMsg)" -ForegroundColor Cyan
$escapedCommitMsg = $commitMsg -replace '"', '`"'
git commit -m "$escapedCommitMsg"
 
$pushResponse = Read-Host "🚀 リモートリポジトリにプッシュしますか？ (y/n)"
if ($pushResponse -match '^[Yy]') {
    Write-Host "🚀 プッシュを実行します..." -ForegroundColor Cyan
    git push
} else {
    Write-Host "ℹ️ プッシュはスキップされました。" -ForegroundColor Yellow
}

Write-Host "✅ 完了しました！" -ForegroundColor Green
