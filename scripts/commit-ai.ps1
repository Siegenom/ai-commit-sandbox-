<#
.SYNOPSIS
    AI-assisted Git commit and devlog generation script with history and caching.
#>

# --- Environment Setup ---
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Configuration ---
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent -Path $PSScriptRoot
$LogDir = Join-Path -Path $ProjectRoot -ChildPath "docs\devlog"
$ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "prompt-config.json"
$LogFile = Join-Path -Path $LogDir -ChildPath "$(Get-Date -Format 'yyyy-MM-dd-HHmmss').md"
$EnableAutoStaging = $true

# New files for state persistence
$LastGoalFile = Join-Path -Path $PSScriptRoot -ChildPath ".last_goal.txt"
$CacheFile = Join-Path -Path $PSScriptRoot -ChildPath ".ai_cache.json"


# --- Functions ---
function Edit-TextInEditor {
    param([string]$InitialContent)
    # ... (No changes to this function)
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

    # Use PSReadLine's history capabilities by pre-filling the input buffer
    if (-not [string]::IsNullOrEmpty($history)) {
        [Microsoft.PowerShell.PSConsoleReadLine]::SetBufferState(
            -Buffer $history -Cursor ($history.Length)
        )
    }
    
    $userInput = Read-Host -Prompt $Prompt

    # Save the new input as the next session's history
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
    $combinedString = "${GitDiff}:${HighLevelGoal}"
    $sha256 = New-Object -TypeName System.Security.Cryptography.SHA256Managed
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding
    $hashBytes = $sha256.ComputeHash($utf8.GetBytes($combinedString))
    return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
}


# --- Main Logic ---
Write-Host "🤖 AIによるコミットと日誌生成を開始します..." -ForegroundColor Cyan

if ($EnableAutoStaging) {
    # ... (No changes to this section)
}

Write-Host "🔍 Gitから情報を収集中..."
$gitDiff = (git diff --staged | Out-String).Trim()
if ([string]::IsNullOrEmpty($gitDiff)) {
    Write-Host '⚠️ ステージングされた変更がありません。''git add''でコミットしたい変更をステージングしてください。' -ForegroundColor Red
    exit 1
}
# ... (rest of git info collection is unchanged)

# --- Get High-Level Goal with History ---
Write-Host "---" -ForegroundColor DarkGray
Write-Host "今回のコミット対象となる変更点は以下の通りです：" -ForegroundColor Yellow
Write-Host $gitDiff
Write-Host "---" -ForegroundColor DarkGray
$promptMessage = "🎯 上記の変更点を踏まえ、このコミットの主な目標を簡潔に入力してください (↑キーで履歴表示)"
$highLevelGoal = Get-HostWithHistory -Prompt $promptMessage -HistoryFile $LastGoalFile


# --- Check Cache for Existing AI Response ---
$cacheKey = Get-CacheKey -GitDiff $gitDiff -HighLevelGoal $highLevelGoal
$cache = @{}
if (Test-Path $CacheFile) {
    try {
        $cache = Get-Content $CacheFile -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "キャッシュファイル.ai_cache.jsonが破損しているため、無視します。"
        $cache = @{}
    }
}

$aiResponse = ""
if ($cache.Contains($cacheKey)) {
    Write-Host "✅ キャッシュされたAIの応答が見つかりました。API呼び出しをスキップします。" -ForegroundColor Green
    $aiResponse = $cache[$cacheKey]
} 

# --- If no cache, call API ---
if ([string]::IsNullOrWhiteSpace($aiResponse)) {
    Write-Host "📝 設定ファイルとコンテキストからAIへの入力JSONを生成中..."
    # ... (config loading is unchanged) ...
    $config = $configContent | ConvertFrom-Json

    # ... (input JSON construction is unchanged) ...
    $aiPrompt = $inputJson | ConvertTo-Json -Depth 20

    if ($config.use_api_mode) {
        Write-Host "🤖 APIを呼び出しています... ($($config.api_provider))" -ForegroundColor Cyan
        $adapterPath = Join-Path -Path $PSScriptRoot -ChildPath "api_adapters\invoke-$($config.api_provider)-api.ps1"
        # ... (adapter path check is unchanged) ...
        
        $aiResponse = & $adapterPath -AiPrompt $aiPrompt -ApiConfig $config
        
        if ($aiResponse -like "ERROR:*") {
            Write-Host "❌ API処理中にエラーが発生しました: $aiResponse" -ForegroundColor Red
            exit 1
        }
        Write-Host "✅ APIから応答を取得しました。" -ForegroundColor Green

        # Save the new response to the cache
        $cache[$cacheKey] = $aiResponse
        $cache | ConvertTo-Json -Depth 10 | Set-Content -Path $CacheFile -Encoding UTF8

    } else {
        # ... (Manual mode is unchanged) ...
    }
}


if ([string]::IsNullOrWhiteSpace($aiResponse)) {
    # ... (rest of the script is largely unchanged)
}

# ... (Parsing, user confirmation, commit logic)
