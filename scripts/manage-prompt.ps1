<#
.SYNOPSIS
    Interactively manage the AI prompt configuration file (prompt-config.json), including its structure.
.DESCRIPTION
    This script allows users to safely edit the AI's persona, task instructions,
    and the output schema (devlog properties) without directly manipulating the JSON file.
#>

# --- Environment Setup ---
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Configuration & Initialization ---
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "prompt-config.json"

try {
    $configContent = Get-Content $ConfigFile -Raw -Encoding UTF8
    # Remove UTF-8 BOM if present, as it can cause issues with ConvertFrom-Json
    $utf8Bom = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::UTF8.GetPreamble())
    if ($configContent.StartsWith($utf8Bom)) {
        $configContent = $configContent.Substring($utf8Bom.Length)
    }
    if ([string]::IsNullOrWhiteSpace($configContent)) {
        throw "設定ファイル '$ConfigFile' が空か、空白文字のみで構成されています。"
    }
    $config = $configContent | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Host "❌ 設定ファイル '$ConfigFile' の読み込みまたはパースに失敗しました。" -ForegroundColor Red
    Write-Host "--- エラー詳細 ---" -ForegroundColor Yellow
    Write-Host $_.Exception.Message
    Write-Host "--------------------"
    Write-Host "ファイルが有効なJSON形式であり、BOMなしのUTF-8エンコーディングで保存されていることを確認してください。" -ForegroundColor Yellow
    exit 1
}

# --- Functions ---
function Edit-TextInEditor {
    param([string]$InitialContent)
    Write-Host "✏️ デフォルトのエディタで値を編集し、保存後、エディタを閉じてください。" -ForegroundColor Cyan

    # 1. Check for EDITOR/VISUAL environment variables (common on Linux/macOS)
    $editorCommand = $env:EDITOR
    if ([string]::IsNullOrEmpty($editorCommand)) {
        $editorCommand = $env:VISUAL
    }

    # 2. If not set, fallback to OS defaults
    if ([string]::IsNullOrEmpty($editorCommand)) {
        # Use the fundamental $env:OS for Windows detection for maximum compatibility.
        if ($env:OS -eq 'Windows_NT') {
            $editorCommand = "notepad.exe"
        }
        # For Unix-like systems, use the more modern $PSVersionTable, but handle older versions.
        elseif ($PSVersionTable.Platform -eq 'MacOS' -or $PSVersionTable.Platform -eq 'Unix') {
            if (Get-Command open -ErrorAction SilentlyContinue) {
                # 'open -t' opens with the default text editor and '-W' waits for it to close.
                $editorCommand = "open -W -t"
            }
            else { # Assume Linux if 'open' is not available
                $editors = @("code --wait", "nano", "vim", "vi")
                $editorCommand = ($editors | ForEach-Object { if (Get-Command $_.Split(' ')[0] -ErrorAction SilentlyContinue) { $_; break } })
            }
        }
    }

    if ([string]::IsNullOrEmpty($editorCommand)) {
        Write-Error "編集に使用できるエディタが見つかりません。環境変数 EDITOR を設定してください。（例: code --wait）"
        return $InitialContent # Return original content on failure
    }

    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile.FullName -Value $InitialContent -Encoding UTF8

        $editorParts = $editorCommand.Split(' ', 2)
        $editorExe = $editorParts[0]
        $editorArgs = if ($editorParts.Length -gt 1) {
            @($editorParts[1], $tempFile.FullName)
        } else {
            $tempFile.FullName
        }
        $process = Start-Process -FilePath $editorExe -ArgumentList $editorArgs -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -ne 0) {
            Write-Warning "エディタが0以外の終了コードで終了しました: $($process.ExitCode)"
        }
        return Get-Content -Path $tempFile.FullName -Raw
    } catch {
        Write-Error "エディタの起動またはファイルの読み込みに失敗しました: $_"
        return $InitialContent
    } finally {
        if (Test-Path $tempFile.FullName) { Remove-Item $tempFile.FullName -Force }
    }
}

function Select-DiaryProperty {
    param(
        [Parameter(Mandatory=$true)]
        $config,
        [Parameter(Mandatory=$true)]
        [string]$PromptMessage
    )

    # ユーザーにとって一貫した順序を提供するため、プロパティオブジェクトではなく`required`配列を基にリストを構築する
    $propertyItems = @()
    $i = 1
    foreach ($propName in $config.output_schema.devlog.required) {
        $propertyItems += [PSCustomObject]@{
            Index       = $i
            Name        = $propName
            Description = $config.output_schema.devlog.properties.$propName.description
        }
        $i++
    }

    Write-Host "`n--- 日誌項目リスト ---" -ForegroundColor Yellow
    $propertyItems.ForEach({ Write-Host "[$($_.Index)] $($_.Description) ($($_.Name))" })
    Write-Host "--------------------"

    while ($true) {
        $input = Read-Host "👉 $($PromptMessage) ('b'で戻る)"
        if ($input -eq 'b') { return $null }
        if ($input -match '^\d+$' -and [int]$input -ge 1 -and [int]$input -le $propertyItems.Count) {
            return $propertyItems[[int]$input - 1].Name
        }
        Write-Host "❌ 無効な入力です。リストに表示されている番号を入力してください。" -ForegroundColor Red
    }
}

function Manage-PersonaAndInstructions {
    param($config)
    while ($true) {
        Write-Host "`n--- ペルソナと基本指示の編集 ---" -ForegroundColor Green
        Write-Host "[1] AIのペルソナを編集する"
        Write-Host "[2] AIの基本指示を編集する"
        Write-Host "[b] メインメニューに戻る"
        $choice = Read-Host "👉 選択してください"
        switch ($choice) {
            '1' {
                $config.ai_persona = Edit-TextInEditor -InitialContent $config.ai_persona
                Write-Host "✅ ペルソナを更新しました。"
            }
            '2' {
                $config.task_instruction = Edit-TextInEditor -InitialContent $config.task_instruction
                Write-Host "✅ タスク指示を更新しました。"
            }
            'b' { return }
            default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
        }
    }
}

function Manage-DiaryStructure {
    param($config)
    while ($true) {
        Write-Host "`n--- 日誌項目の構造を編集 ---" -ForegroundColor Green
        Write-Host "[1] 新しい項目を追加する"
        Write-Host "[2] 既存の項目を削除する"
        Write-Host "[3] 既存の項目の見出し(description)を編集する"
        Write-Host "[b] 上のメニューに戻る"
        $choice = Read-Host "👉 選択してください"

        switch ($choice) {
            '1' {
                $newPropName = Read-Host "✏️ 追加したい新しい項目名を入力してください (例: test_results)"
                if ($config.output_schema.devlog.required -contains $newPropName) { Write-Host "❌ その項目は既に存在します。" -ForegroundColor Red; continue }
                $newPropDesc = Read-Host "✏️ 新しい項目の見出し(description)を入力してください"
                $newPropHint = Read-Host "✏️ 新しい項目のAIへの個別指示(prompt_hint)を入力してください"
                $newProperty = [PSCustomObject]@{ type = "string"; description = $newPropDesc; prompt_hint = $newPropHint }
                $config.output_schema.devlog.properties | Add-Member -MemberType NoteProperty -Name $newPropName -Value $newProperty
                $config.output_schema.devlog.required += $newPropName
                Write-Host "✅ 新しい項目 '$newPropName' を追加し、必須項目に設定しました。"
            }
            '2' {
                $propToDelete = Select-DiaryProperty -config $config -PromptMessage "削除したい項目の番号を入力してください"
                if ($null -ne $propToDelete) {
                    $config.output_schema.devlog.properties.PSObject.Properties.Remove($propToDelete)
                    $config.output_schema.devlog.required = $config.output_schema.devlog.required | Where-Object { $_ -ne $propToDelete }
                    Write-Host "✅ 項目 '$propToDelete' を削除し、必須項目からも削除しました。"
                }
            }
            '3' {
                $propToEdit = Select-DiaryProperty -config $config -PromptMessage "見出しを編集したい項目の番号を入力してください"
                if ($null -ne $propToEdit) {
                    $config.output_schema.devlog.properties.$propToEdit.description = Edit-TextInEditor -InitialContent $config.output_schema.devlog.properties.$propToEdit.description
                    Write-Host "✅ 見出しを更新しました。"
                }
            }
            'b' { return }
            default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
        }
    }
}

function Manage-DiaryContent {
    param($config)
    $propToEdit = Select-DiaryProperty -config $config -PromptMessage "個別指示を編集したい項目の番号を入力してください"
    if ($null -eq $propToEdit) { return }

    $originalHint = $config.output_schema.devlog.properties.$propToEdit.prompt_hint

    while ($true) {
        $requiredVariables = [regex]::Matches($originalHint, '{{.*?}}') | ForEach-Object { $_.Value }

        Write-Host "`n--- 個別指示の編集: $($propToEdit) ---" -ForegroundColor Green
        if ($requiredVariables.Count -gt 0) {
            Write-Host "以下の変数は、AIが正しく動作するために必須です。編集後も必ず含めてください。" -ForegroundColor Yellow
            $requiredVariables | ForEach-Object { Write-Host "- $_" }
        }

        $newHint = Edit-TextInEditor -InitialContent $originalHint

        $missingVariables = $requiredVariables | Where-Object { $newHint -notlike "*$_*" }

        if ($missingVariables.Count -eq 0) {
            $config.output_schema.devlog.properties.$propToEdit.prompt_hint = $newHint
            Write-Host "✅ 個別指示を更新しました。"
            return
        }

        Write-Host "❌ 必須変数が削除されているため、変更は自動的に破棄されました。" -ForegroundColor Red
        $missingVariables | ForEach-Object { Write-Host "- '$_' が見つかりません。" }
        $retry = Read-Host "👉 もう一度編集しますか？ (y/n)"
        if ($retry -notmatch '^[Yy]') {
            Write-Host "ℹ️ 編集はキャンセルされました。元の指示文が維持されます。"
            return
        }
    }
}

function Manage-DiaryItems {
    param($config)
    while ($true) {
        Write-Host "`n--- 日誌の項目を編集 ---" -ForegroundColor Green
        Write-Host "[1] 日誌項目の構造を編集する (追加/削除/見出し変更)"
        Write-Host "[2] 日誌項目の個別指示を編集する (AIの応答内容を調整)"
        Write-Host "[b] メインメニューに戻る"
        $choice = Read-Host "👉 選択してください"
        switch ($choice) {
            '1' { Manage-DiaryStructure -config $config }
            '2' { Manage-DiaryContent -config $config }
            'b' { return }
            default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
        }
    }
}

function Manage-ApiSettings {
    param($config)
    while ($true) {
        Write-Host "`n--- API設定の編集 ---" -ForegroundColor Green
        $currentMode = if ($config.use_api_mode) { "APIモード (自動)" } else { "手動モード" }
        Write-Host "現在のモード: $currentMode" -ForegroundColor Yellow
        Write-Host "[1] モードを切り替える"
        Write-Host "[b] メインメニューに戻る"
        $choice = Read-Host "👉 選択してください"
        switch ($choice) {
            '1' {
                $config.use_api_mode = -not $config.use_api_mode
                $newMode = if ($config.use_api_mode) { "APIモード (自動)" } else { "手動モード" }
                Write-Host "✅ モードを '$newMode' に切り替えました。"
            }
            'b' { return }
            default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
        }
    }
}

# --- Main Logic ---
while ($true) {
    Write-Host "`n🤖 AIプロンプト設定マネージャー" -ForegroundColor Cyan
    Write-Host "何をしますか？"
    Write-Host "[1] ペルソナと基本指示を編集する"
    Write-Host "[2] 日誌の項目を編集する"
    Write-Host "[3] API設定を編集する"
    Write-Host "[q] 保存して終了する"
    $menuChoice = Read-Host "👉 選択してください"

    switch ($menuChoice) {
        '1' { Manage-PersonaAndInstructions -config $config }
        '2' { Manage-DiaryItems -config $config }
        '3' { Manage-ApiSettings -config $config }
        'q' {
            $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
            Write-Host "✅ 設定を保存しました: $ConfigFile" -ForegroundColor Green
            exit 0
        }
        default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
    }
}