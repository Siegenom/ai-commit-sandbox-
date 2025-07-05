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

if (-not (Test-Path $ConfigFile)) {
    Write-Host "❌ 設定ファイルが見つかりません: $ConfigFile" -ForegroundColor Red
    exit 1
}
$config = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

# --- Functions ---
function Edit-TextInNotepad {
    param([string]$InitialContent)
    Write-Host "✏️ メモ帳で値を編集し、保存後、メモ帳を閉じてください。" -ForegroundColor Cyan
    $tempFile = New-TemporaryFile
    Set-Content -Path $tempFile.FullName -Value $InitialContent -Encoding UTF8
    Start-Process notepad.exe -ArgumentList $tempFile.FullName -Wait
    $newValue = Get-Content -Path $tempFile.FullName -Raw
    Remove-Item $tempFile.FullName
    return $newValue.Trim()
}

function Manage-PersonaAndInstructions {
    param($config)
    Write-Host "--- AIペルソナの編集 ---" -ForegroundColor Green
    $config.ai_persona = Edit-TextInNotepad -InitialContent $config.ai_persona
    Write-Host "--- タスク指示の編集 ---" -ForegroundColor Green
    $config.task_instruction = Edit-TextInNotepad -InitialContent $config.task_instruction
    Write-Host "✅ ペルソナと指示を更新しました。"
}

function Manage-OutputSchema {
    param($config)
    while ($true) {
        Write-Host "`n--- 出力スキーマ（日誌項目）の編集 ---" -ForegroundColor Green
        $properties = $config.output_schema.devlog.properties.PSObject.Properties | ForEach-Object { $_.Name }
        Write-Host "現在の日誌項目:" -ForegroundColor Yellow
        $properties | ForEach-Object { Write-Host "- $_" }

        Write-Host "`n何をしますか？"
        Write-Host "[1] 既存の項目の説明を編集"
        Write-Host "[2] 新しい項目を追加"
        Write-Host "[3] 既存の項目を削除"
        Write-Host "[b] 前のメニューに戻る"
        $choice = Read-Host "👉 選択してください"

        switch ($choice) {
            '1' {
                $propToEdit = Read-Host "✏️ 説明を編集したい項目名を入力してください"
                if ($properties -contains $propToEdit) {
                    $currentDesc = $config.output_schema.devlog.properties.$propToEdit.description
                    Write-Host "現在の説明: $currentDesc"
                    $newDesc = Read-Host "新しい説明を入力してください"
                    $config.output_schema.devlog.properties.$propToEdit.description = $newDesc
                    Write-Host "✅ 説明を更新しました。"
                } else {
                    Write-Host "❌ そのような項目はありません。" -ForegroundColor Red
                }
            }
            '2' {
                $newPropName = Read-Host "✏️ 追加したい新しい項目名を入力してください (例: test_results)"
                if ($properties -contains $newPropName) {
                    Write-Host "❌ その項目は既に存在します。" -ForegroundColor Red
                    continue
                }
                $newPropDesc = Read-Host "✏️ 新しい項目の説明を入力してください (これが日誌の見出しになります)"
                $newProperty = [PSCustomObject]@{
                    type        = "string"
                    description = $newPropDesc
                }
                $config.output_schema.devlog.properties | Add-Member -MemberType NoteProperty -Name $newPropName -Value $newProperty
                Write-Host "✅ 新しい項目 '$newPropName' を追加しました。"
            }
            '3' {
                $propToDelete = Read-Host "✏️ 削除したい項目名を入力してください"
                if ($properties -contains $propToDelete) {
                    $config.output_schema.devlog.properties.PSObject.Properties.Remove($propToDelete)
                    Write-Host "✅ 項目 '$propToDelete' を削除しました。"
                } else {
                    Write-Host "❌ そのような項目はありません。" -ForegroundColor Red
                }
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
    Write-Host "[1] AIのペルソナと基本指示を編集する"
    Write-Host "[2] AIの出力形式（日誌の項目）を編集する"
    Write-Host "[q] 保存して終了する"
    $menuChoice = Read-Host "👉 選択してください"

    switch ($menuChoice) {
        '1' { Manage-PersonaAndInstructions -config $config }
        '2' { Manage-OutputSchema -config $config }
        'q' {
            $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
            Write-Host "✅ 設定を保存しました: $ConfigFile" -ForegroundColor Green
            exit 0
        }
        default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
    }
}