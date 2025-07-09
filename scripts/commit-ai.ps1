#Requires -Version 5.1
<#
.SYNOPSIS
    AI-assisted Git commit and devlog generation script with history and caching.
.PARAMETER Debug
    If specified, the script runs in debug mode, using sample data instead of
    actual git diff. When used alone, it exits before writing files or committing.
.PARAMETER DryRun
    If specified, the script performs a "dry run". It will write log files to a
    temporary directory and simulate the commit using 'git commit --dry-run'.
    When combined with -Debug, it allows testing the full script flow with sample data.
#>
param(
    [switch]$Debug,
    [switch]$DryRun
)

# --- Environment Setup ---
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Configuration ---
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent -Path $PSScriptRoot

if ($DryRun) {
    $TempDir = Join-Path $env:TEMP "ai-commit-dry-run"
    if (-not (Test-Path $TempDir)) { New-Item -Path $TempDir -ItemType Directory | Out-Null }
    $LogDir = $TempDir
} else {
    $LogDir = Join-Path -Path $ProjectRoot -ChildPath "docs\devlog"
}

$ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "prompt-config.json"
$LogFile = Join-Path -Path $LogDir -ChildPath "$(Get-Date -Format 'yyyy-MM-dd-HHmmss').md"
$EnableAutoStaging = $true
$LastGoalFile = Join-Path -Path $PSScriptRoot -ChildPath ".last_goal.txt"
$CacheFile = Join-Path -Path $PSScriptRoot -ChildPath ".ai_cache.json"

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
    if ([string]::IsNullOrEmpty($editorCommand)) { Write-Error "編集に使用できるエディタが見つかりません。"; return $InitialContent }
    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile.FullName -Value $InitialContent -Encoding UTF8
        $editorParts = $editorCommand.Split(' ', 2); $editorExe = $editorParts[0]
        $editorArgs = if ($editorParts.Length -gt 1) { @($editorParts[1], $tempFile.FullName) } else { $tempFile.FullName }
        Start-Process -FilePath $editorExe -ArgumentList $editorArgs -Wait
        return Get-Content -Path $tempFile.FullName -Raw -Encoding UTF8
    } catch {
        Write-Error "エディタの起動またはファイルの読み込みに失敗しました: $_"; return $InitialContent
    } finally {
        if (Test-Path $tempFile.FullName) { Remove-Item $tempFile.FullName -Force }
    }
}

function Get-HostWithHistory {
    param(
        [string]$Prompt,
        [string]$HistoryFile
    )
    $history = ""
    if (Test-Path $HistoryFile) {
        $history = Get-Content $HistoryFile -Raw -ErrorAction SilentlyContinue
    }
    if ((-not [string]::IsNullOrEmpty($history)) -and (Get-Module -ListAvailable -Name PSReadLine)) {
        try {
            [Microsoft.PowerShell.PSConsoleReadLine]::SetBufferState($history, $history.Length)
        }
        catch {}
    }
    $userInput = Read-Host -Prompt $Prompt
    if (-not [string]::IsNullOrWhiteSpace($userInput)) {
        Set-Content -Path $HistoryFile -Value $userInput -Encoding UTF8
    }
    return $userInput
}

function Get-CacheKey {
    param(
        [string]$GitDiff,
        [string]$HighLevelGoal
    )
    if ([string]::IsNullOrEmpty($GitDiff) -or [string]::IsNullOrEmpty($HighLevelGoal)) {
        return $null
    }
    $combinedString = "${GitDiff}:${HighLevelGoal}"
    $sha256 = New-Object -TypeName System.Security.Cryptography.SHA256Managed
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding
    $hashBytes = $sha256.ComputeHash($utf8.GetBytes($combinedString))
    return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
}

function Format-GitDiffForDisplay {
    Write-Host "---" -ForegroundColor DarkGray
    Write-Host "今回のコミット対象となる変更点のサマリーです：" -ForegroundColor Yellow
    
    $numstatOutput = git diff --staged --numstat
    if (-not [string]::IsNullOrWhiteSpace($numstatOutput)) {
        $numstatOutput.Split([System.Environment]::NewLine) | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return }
            $parts = $_ -split "`t"
            if ($parts.Length -eq 3) {
                Write-Host (" " * 2) -NoNewline
                Write-Host "+$($parts[0]) " -ForegroundColor Green -NoNewline
                Write-Host "-$($parts[1]) " -ForegroundColor Red -NoNewline
                Write-Host $parts[2] -ForegroundColor White
            }
        }
    }
    
    Write-Host "---" -ForegroundColor DarkGray
}

function ConvertFrom-AiResponse {
    param([string]$AiResponse)
    if ([string]::IsNullOrWhiteSpace($AiResponse)) {
        Write-Error "AIからの応答が空です。"
        return $null
    }
    try {
        $jsonContent = $AiResponse -replace '(?ms)^```json\s*|\s*```$'
        return $jsonContent | ConvertFrom-Json
    } catch {
        Write-Error "AI応答のJSONパースに失敗しました: $($_.Exception.Message)"
        Write-Host "--- AI Raw Response ---" -ForegroundColor DarkGray
        Write-Host $AiResponse
        Write-Host "-----------------------" -ForegroundColor DarkGray
        return $null
    }
}

function ConvertTo-DevlogMarkdown {
    param($DevlogObject)
    
    $markdown = @"
## ✅ やったこと (Accomplishments)
- $($DevlogObject.accomplishments -join "`n- ")

## 📚 学びと発見 (Learnings & Discoveries)
- $($DevlogObject.learnings_and_discoveries -join "`n- ")

## 😌 今の気分 (Current Mood) 
- $($DevlogObject.current_mood)

## 😠 ぼやき (Grumble / Vent)
- $($DevlogObject.grumble_or_vent)

## 🚀 次にやること (Issues or Next)
- $($DevlogObject.issues_or_next -join "`n- ")
"@
    return $markdown
}


# --- Main Logic ---
Write-Host "🤖 AIによるコミットと日誌生成を開始します..." -ForegroundColor Cyan

if ($Debug -and $DryRun) {
    Write-Host "⚠️ デバッグ・ドライランモード: サンプルデータで全工程をテストします。" -ForegroundColor Yellow
    Write-Host "💧 日誌ファイルは一時フォルダに出力され、実際のコミットは行われません。" -ForegroundColor Cyan
} elseif ($Debug) {
    Write-Host "⚠️ デバッグモード: サンプルデータを使用します。ファイル書き込みやコミットは行いません。" -ForegroundColor Yellow
} elseif ($DryRun) {
     Write-Host "💧 ドライランモード: 日誌ファイルは一時フォルダに出力されます: $LogDir" -ForegroundColor Cyan
}

if ($EnableAutoStaging -and -not $Debug) {
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
$gitDiff = ""
$currentBranch = "debug-branch"
$stagedFiles = @("sample/file1.txt", "sample/file2.js")

if ($Debug) {
    $gitDiff = "diff --git a/sample.txt b/sample.txt`n--- a/sample.txt`n+++ b/sample.txt`n@@ -1 +1 @@`n-hello`n+hello world"
} else {
    $gitDiff = (git diff --staged | Out-String).Trim()
    if ([string]::IsNullOrEmpty($gitDiff)) {
        Write-Host '⚠️ ステージングされた変更がありません。''git add''でコミットしたい変更をステージングしてください。' -ForegroundColor Red
        Write-Host '💡 デバッグ用にスクリプトをテストしたい場合は、-Debug パラメータを付けて実行してください。' -ForegroundColor Cyan
        exit 1
    }
    $currentBranch = (git rev-parse --abbrev-ref HEAD | Out-String).Trim()
    $stagedFiles = (git diff --staged --name-only | Out-String).Trim().Split([System.Environment]::NewLine) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

Format-GitDiffForDisplay
$promptMessage = "🎯 上記の変更点を踏まえ、このコミットの主な目標を簡潔に入力してください (↑キーで履歴表示)"
$highLevelGoal = Get-HostWithHistory -Prompt $promptMessage -HistoryFile $LastGoalFile

$cacheKey = Get-CacheKey -GitDiff $gitDiff -HighLevelGoal $highLevelGoal
$cache = [hashtable]@{}
if (Test-Path $CacheFile) {
    try { 
        $cache = Get-Content $CacheFile -Raw | ConvertFrom-Json -AsHashtable
    } catch { 
        $cache = [hashtable]@{}
    }
}

$aiResponse = ""
if (-not [string]::IsNullOrEmpty($cacheKey) -and $cache.ContainsKey($cacheKey)) {
    Write-Host "✅ キャッシュされたAIの応答が見つかりました。API呼び出しをスキップします。" -ForegroundColor Green
    $aiResponse = $cache[$cacheKey]
} 

if ([string]::IsNullOrWhiteSpace($aiResponse)) {
    Write-Host "📝 設定ファイルとコンテキストからAIへの入力JSONを生成中..."
    try {
        $configContent = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
        $config = $configContent | ConvertFrom-Json
    } catch {
        Write-Host "❌ 設定ファイル '$ConfigFile' の読み込みまたはパースに失敗しました。" -ForegroundColor Red; exit 1
    }
    
    $langInstruction = if ($config.devlog_language -eq 'japanese') { "The entire 'devlog' object must be written in Japanese." } else { "The entire 'devlog' object must be written in English." }
    $fullTaskInstruction = "$($config.task_instruction) $langInstruction"

    $inputJson = [PSCustomObject]@{
        system_prompt = @{ 
            persona = $config.ai_persona; 
            task = $fullTaskInstruction; 
            output_schema_definition = $config.output_schema 
        }
        user_context  = @{ 
            high_level_goal = $highLevelGoal; 
            git_context = @{ 
                current_branch = $currentBranch; 
                staged_files = $stagedFiles; 
                diff = $gitDiff 
            } 
        }
    }
    $aiPrompt = $inputJson | ConvertTo-Json -Depth 20

    if ($config.use_api_mode) {
        Write-Host "🤖 APIを呼び出しています... ($($config.api_provider))" -ForegroundColor Cyan
        $adapterPath = Join-Path -Path $PSScriptRoot -ChildPath "api_adapters\invoke-$($config.api_provider)-api.ps1"
        if (-not (Test-Path $adapterPath)) { Write-Host "❌ APIアダプターのファイルが見つかりません！" -ForegroundColor Red; exit 1 }
        
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
        
        if ($aiResponse -like "ERROR:*") { Write-Host "❌ API処理中にエラーが発生しました: $aiResponse" -ForegroundColor Red; exit 1 }
        Write-Host "✅ APIから応答を取得しました。" -ForegroundColor Green

        if (-not [string]::IsNullOrEmpty($cacheKey)) {
            $cache[$cacheKey] = $aiResponse
            $cache | ConvertTo-Json -Depth 10 | Set-Content -Path $CacheFile -Encoding UTF8
        }
    } else {
        Write-Warning "APIモードが無効です。手動モードは現在実装されていません。"
        exit 1
    }
}

# --- 応答の解析とユーザー確認 ---
$parsedResponse = ConvertFrom-AiResponse -AiResponse $aiResponse
if ($null -eq $parsedResponse) { exit 1 }

# === プロパティ名 (キー) を修正 ===
if (-not $parsedResponse.PSObject.Properties.Name.Contains('commit_message') -or [string]::IsNullOrWhiteSpace($parsedResponse.commit_message)) {
    Write-Error "AIの応答からコミットメッセージを取得できませんでした。スクリプトを中止します。"
    Write-Host "--- AI Raw Response ---" -ForegroundColor DarkGray
    Write-Host $aiResponse
    Write-Host "-----------------------" -ForegroundColor DarkGray
    exit 1
}

$commitMessage = $parsedResponse.commit_message
# =================================

$devLogObject = $parsedResponse.devLog 

while ($true) {
    $devLogContent = ConvertTo-DevlogMarkdown -DevlogObject $devLogObject

    Write-Host "`n--- 生成されたコミットメッセージ ---" -ForegroundColor Green
    Write-Host $commitMessage
    Write-Host "------------------------------------`n" -ForegroundColor Green

    Write-Host "--- 生成された日誌 ---" -ForegroundColor Cyan
    Write-Host $devLogContent
    Write-Host "------------------------`n" -ForegroundColor Cyan

    $choice = Read-Host "👉 この内容でよろしいですか？ (y:コミット実行 / e:編集 / n:中止)"
    if ($choice -match '^[Yy]') {
        break
    } elseif ($choice -match '^[Ee]') {
        $commitMessage = Edit-TextInEditor -InitialContent $commitMessage
        Write-Warning "日誌の編集は現在サポートされていません。コミットメッセージのみ編集されました。"
    } else {
        Write-Host "❌ 操作を中止しました。" -ForegroundColor Red
        exit 0
    }
}

# --- 最終処理 ---
if ($Debug -and -not $DryRun) {
    Write-Host "✅ [DEBUG MODE] 処理が正常に完了しました。ファイル書き込みとコミットはスキップされました。" -ForegroundColor Green
    exit 0
}

try {
    $finalLogContent = ConvertTo-DevlogMarkdown -DevlogObject $devLogObject
    Set-Content -Path $LogFile -Value $finalLogContent -Encoding UTF8
    Write-Host "✅ 日誌を保存しました: $LogFile" -ForegroundColor Green
} catch {
    Write-Error "日誌ファイルの書き込みに失敗しました: $_"
    exit 1
}

try {
    if ($DryRun) {
        Write-Host "💧 [DRY RUN] git commit --dry-run を実行します..." -ForegroundColor Cyan
        git commit --dry-run -m "$commitMessage" 
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ ドライランコミットが正常にシミュレートされました。" -ForegroundColor Green
        }
        if (Test-Path $LogFile) {
            Write-Host "🗑️ 一時的な日誌ファイルを削除します: $LogFile"
            Remove-Item $LogFile -Force
        }
    } else {
        Write-Host "🚀 コミットを実行します..." -ForegroundColor Green
        git commit -m "$commitMessage" 
        if ($LASTEXITCODE -eq 0) {
            Write-Host "🎉 コミットが正常に完了しました。'git push' を実行して変更をリモートに反映させてください。" -ForegroundColor Magenta
        }
    }
} catch {
    Write-Error "git commit の実行に失敗しました: $_"
}
