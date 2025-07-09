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
function Edit-TextInEditor { param([string]$InitialContent) } # Placeholder for brevity
function Get-HostWithHistory { param([string]$Prompt, [string]$HistoryFile) } # Placeholder for brevity
function Get-CacheKey { param([string]$GitDiff, [string]$HighLevelGoal) } # Placeholder for brevity

function Format-GitDiffForDisplay {
    Write-Host "---" -ForegroundColor DarkGray
    Write-Host "今回のコミット対象となる変更点のサマリーです：" -ForegroundColor Yellow
    
    # Get file stats (additions/deletions) using numstat
    $numstatOutput = git diff --staged --numstat
    if (-not [string]::IsNullOrWhiteSpace($numstatOutput)) {
        $numstatOutput.Split([System.Environment]::NewLine) | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return }
            $parts = $_ -split "`t"
            if ($parts.Length -eq 3) {
                $additions = $parts[0]
                $deletions = $parts[1]
                $filePath = $parts[2]
                Write-Host (" " * 2) -NoNewline
                Write-Host "+$additions " -ForegroundColor Green -NoNewline
                Write-Host "-$deletions " -ForegroundColor Red -NoNewline
                Write-Host $filePath -ForegroundColor White
            }
        }
    }
    
    Write-Host "---" -ForegroundColor DarkGray
}

# --- Main Logic ---
Write-Host "🤖 AIによるコミットと日誌生成を開始します..." -ForegroundColor Cyan

if ($Debug -and $DryRun) {
    Write-Host "⚠️ DEBUG DRY RUN MODE: Using sample data to test the full script flow." -ForegroundColor Yellow
    Write-Host "💧 日誌ファイルは一時フォルダに出力され、実際のコミットは行われません。" -ForegroundColor Cyan
} elseif ($Debug) {
    Write-Host "⚠️ DEBUG MODE: Using sample data. No files will be written, no commits will be made." -ForegroundColor Yellow
} elseif ($DryRun) {
     Write-Host "💧 DRY RUN MODE: 日誌ファイルは一時フォルダに出力されます: $LogDir" -ForegroundColor Cyan
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
    $gitDiff = "..." # Sample diff data
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
# Initialize as a Hashtable to allow adding keys
$cache = @{}
if (Test-Path $CacheFile) {
    try { 
        # Convert the PSCustomObject from JSON into a Hashtable for proper key handling
        $cache = Get-Content $CacheFile -Raw | ConvertFrom-Json -AsHashtable
    } catch { 
        $cache = @{} 
    }
}

$aiResponse = ""
# Use .ContainsKey() method for Hashtables
if ($cache.ContainsKey($cacheKey)) {
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
        system_prompt = @{ persona = $config.ai_persona; task = $fullTaskInstruction; output_schema_definition = $config.output_schema }
        user_context  = @{ high_level_goal = $highLevelGoal; git_context = @{ current_branch = $currentBranch; staged_files = $stagedFiles; diff = $gitDiff } }
    }
    $aiPrompt = $inputJson | ConvertTo-Json -Depth 20

    if ($config.use_api_mode) {
        Write-Host "🤖 APIを呼び出しています... ($($config.api_provider))" -ForegroundColor Cyan
        $adapterPath = Join-Path -Path $PSScriptRoot -ChildPath "api_adapters\invoke-$($config.api_provider)-api.ps1"
        if (-not (Test-Path $adapterPath)) { Write-Host "❌ APIアダプターのファイルが見つかりません！" -ForegroundColor Red; exit 1 }
        
        # Call the adapter with the correct parameter name
        $aiResponse = & $adapterPath -AiPrompt $aiPrompt -ApiConfig $config
        
        if ($aiResponse -like "ERROR:*") { Write-Host "❌ API処理中にエラーが発生しました: $aiResponse" -ForegroundColor Red; exit 1 }
        Write-Host "✅ APIから応答を取得しました。" -ForegroundColor Green

        # Add new response to the cache hashtable
        $cache[$cacheKey] = $aiResponse
        $cache | ConvertTo-Json -Depth 10 | Set-Content -Path $CacheFile -Encoding UTF8
    } else {
        # ... (Manual mode logic)
    }
}

# ... (Rest of the script: parsing, user confirmation, final actions)
