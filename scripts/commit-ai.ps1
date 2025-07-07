<#
.SYNOPSIS
    AI-assisted Git commit and devlog generation script for PowerShell.
#>

# --- Environment Setup ---
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Configuration ---
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition

# --- DIAGNOSTIC SETUP ---
. (Join-Path -Path $PSScriptRoot -ChildPath "logger.ps1")

Write-Log "--- commit-ai.ps1 STARTED ---"
Write-Log "PSVersion: $($PSVersionTable.PSVersion)"

$ProjectRoot = Split-Path -Parent -Path $PSScriptRoot
$LogDir = Join-Path -Path $ProjectRoot -ChildPath "docs\devlog"
$ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "prompt-config.json"
$Today = (Get-Date).ToString("yyyy-MM-dd")
$LogFile = Join-Path -Path $LogDir -ChildPath "$(Get-Date -Format 'yyyy-MM-dd-HHmmss').md"
$EnableAutoStaging = $true

Write-Log "Step 1: Configuration paths set."

# --- Functions ---
function Edit-TextInEditor {
    param([string]$InitialContent)
    Write-Log "Function 'Edit-TextInEditor' called."
    Write-Host "✏️ デフォルトのエディタで値を編集し、保存後、エディタを閉じてください。" -ForegroundColor Cyan
    # ... (Function logic remains the same)
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
Write-Log "Step 2: Main logic started."
Write-Host "🤖 AIによるコミットと日誌生成を開始します..." -ForegroundColor Cyan

if ($EnableAutoStaging) {
    Write-Log "Step 2a: Checking for unstaged changes."
    git diff --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "🔍 未ステージの変更が検出されました。" -ForegroundColor Yellow
        git status --short
        $response = Read-Host "👉 これらの変更をすべてステージングしますか？ (y/n)"
        if ($response -match '^[Yy]') {
            Write-Log "       - User chose to stage changes."
            Write-Host "✅ すべての変更をステージングします..." -ForegroundColor Green
            git add .
        } else {
            Write-Log "       - User chose to skip staging."
            Write-Host "ℹ️ ステージングはスキップされました。" -ForegroundColor Yellow
        }
    } else {
        Write-Log "       - No unstaged changes found."
    }
}

Write-Log "Step 3: Collecting Git context."
$gitDiff = (git diff --staged | Out-String).Trim()
if ([string]::IsNullOrEmpty($gitDiff)) {
    Write-Log "ERROR: No staged changes found. Exiting."
    Write-Host '⚠️ ステージングされた変更がありません。''git add''でコミットしたい変更をステージングしてください。' -ForegroundColor Red
    exit 1
}
$currentBranch = (git rev-parse --abbrev-ref HEAD | Out-String).Trim()
$stagedFiles = (git diff --staged --name-only | Out-String).Trim().Split([System.Environment]::NewLine) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
Write-Log "       - Git context collected successfully."

Write-Log "Step 4: Setting high-level goal."
$highLevelGoal = "ユーザがWebChatUIのAIにJSONの入出力を手動で行う今までの形式から、APIキーを用いた自動実行の形式へという大規模改修を行った。各種AIに対応するため差異を吸収しうるAPIアダプターを設定した。"
Write-Host "🎯 使用中のハードコードされた目標:" -ForegroundColor DarkCyan
Write-Host $highLevelGoal -ForegroundColor DarkCyan
Write-Log "       - High-level goal is hardcoded."

Write-Log "Step 5: Reading and parsing config file: $ConfigFile"
try {
    $configContent = Get-Content $ConfigFile -Raw -Encoding UTF8
    if ($configContent -and $configContent.StartsWith([char]0xFEFF)) {
        $configContent = $configContent.Substring(1)
    }
    if ([string]::IsNullOrWhiteSpace($configContent)) {
        throw "設定ファイルが空です。"
    }
    $config = $configContent | ConvertFrom-Json -ErrorAction Stop
    Write-Log "       - Config file parsed successfully."
}
catch {
    Write-Log "FATAL ERROR during config file processing: $($_.Exception.Message)"
    Write-Host "❌ 設定ファイル '$ConfigFile' の読み込みまたはパースに失敗しました。" -ForegroundColor Red
    Write-Host "--- エラー詳細 ---"; Write-Host $_.Exception.Message
    exit 1
}

Write-Log "Step 6: Building AI prompt JSON."
$inputJson = [PSCustomObject]@{
    system_prompt = @{ persona = $config.ai_persona; task = $config.task_instruction; output_schema_definition = $config.output_schema }
    user_context  = @{ high_level_goal = $highLevelGoal; git_context = @{ current_branch = $currentBranch; staged_files = $stagedFiles; diff = $gitDiff } }
}
$aiPrompt = $inputJson | ConvertTo-Json -Depth 10
Write-Log "       - AI prompt JSON built. Length: $($aiPrompt.Length)"

Write-Log "Step 7: Entering API/Manual mode decision block."
$aiResponse = ""
if ($config.use_api_mode) {
    Write-Log "Step 7a: API mode is ON. Provider: $($config.api_provider)"
    Write-Host "🤖 APIを呼び出しています... ($($config.api_provider))" -ForegroundColor Cyan
    $adapterPath = Join-Path -Path $PSScriptRoot -ChildPath "api_adapters\invoke-$($config.api_provider)-api.ps1"
    Write-Log "       - Adapter path: $adapterPath"
    if (-not (Test-Path $adapterPath)) {
        Write-Log "FATAL ERROR: Adapter file not found at $adapterPath. Exiting."
        Write-Host "❌ APIアダプターのファイルが見つかりません！" -ForegroundColor Red
        exit 1
    }
    
    # [MODIFIED] Pass the prompt via a temporary file to avoid argument parsing issues.
    $tempPromptFile = $null
    try {
        $tempPromptFile = New-TemporaryFile
        Set-Content -Path $tempPromptFile.FullName -Value $aiPrompt -Encoding UTF8
        Write-Log "       - Saved AI prompt to temporary file: $($tempPromptFile.FullName)"

        Write-Log "       - Calling adapter script now..."
        $aiResponse = & $adapterPath -PromptFilePath $tempPromptFile.FullName -ApiConfig $config
        Write-Log "       - Adapter script finished. Response length: $($aiResponse.Length)"
    }
    finally {
        if ($null -ne $tempPromptFile -and (Test-Path $tempPromptFile.FullName)) {
            Remove-Item -Path $tempPromptFile.FullName -Force
            Write-Log "       - Removed temporary prompt file."
        }
    }

    if ($aiResponse -like "ERROR:*") {
        Write-Log "ERROR returned from adapter: $aiResponse. Exiting."
        Write-Host "❌ API処理中にエラーが発生しました。" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ APIから応答を取得しました。" -ForegroundColor Green
} else {
    # ... (Manual mode logic remains the same)
}

if ([string]::IsNullOrWhiteSpace($aiResponse)) {
    Write-Log "ERROR: AI response is empty. Aborting."
    Write-Host "❌ AIからの応答が空です。処理を中断します。" -ForegroundColor Red
    exit 1
}

# ... (The rest of the script remains the same)
Write-Log "Step 8: Parsing AI response."
# ...
