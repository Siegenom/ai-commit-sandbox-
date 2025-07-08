<#
.SYNOPSIS
    Interactively manage the AI prompt configuration presets.
.DESCRIPTION
    This script allows users to safely edit the AI's persona, task instructions,
    output schema, and API settings. It supports saving and loading named presets, ensuring
    that valuable configurations are not lost. All edits are made to an in-memory
    working copy and are only saved to the main 'prompt-config.json' upon quitting.
#>

# --- Environment Setup ---
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Configuration & Initialization ---
$PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "prompt-config.json"
$DefaultConfigFile = Join-Path -Path $PSScriptRoot -ChildPath "prompt-config.default.json"
$PresetsDir = Join-Path -Path $PSScriptRoot -ChildPath "presets"

# --- Create Presets Directory If It Doesn't Exist ---
if (-not (Test-Path -Path $PresetsDir -PathType Container)) {
    New-Item -Path $PresetsDir -ItemType Directory -Force | Out-Null
}

# --- Robust File Reading into a Working Copy ---
$WorkingConfig = $null
try {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "🔧 設定ファイルが見つかりません。デフォルト設定をコピーします。" -ForegroundColor Yellow
        Copy-Item -Path $DefaultConfigFile -Destination $ConfigFile -Force
    }
    $configContent = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($configContent)) {
        throw "設定ファイル '$ConfigFile' が空です。"
    }
    $WorkingConfig = $configContent | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Host "❌ 設定ファイル '$ConfigFile' の読み込みまたはパースに失敗しました。" -ForegroundColor Red
    Write-Host "--- エラー詳細 ---" -ForegroundColor Yellow; Write-Host $_.Exception.Message
    exit 1
}

# --- Functions (Original and New) ---

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

function Select-DiaryProperty {
    param([Parameter(Mandatory=$true)]$config, [Parameter(Mandatory=$true)][string]$PromptMessage)
    $propertyItems = @()
    $i = 1
    if ($null -ne $config.output_schema.devlog.properties) {
        foreach ($propName in $config.output_schema.devlog.required) {
            $propertyItems += [PSCustomObject]@{ Index = $i; Name = $propName; Description = $config.output_schema.devlog.properties.$propName.description }
            $i++
        }
    }
    if ($propertyItems.Count -eq 0) {
        Write-Host "`n--- 日誌項目がありません ---" -ForegroundColor Yellow
        Read-Host "何かキーを押して戻ってください..."
        return $null
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
        Write-Host "❌ 無効な入力です。" -ForegroundColor Red
    }
}

function Manage-PersonaAndInstructions {
    param($config)
    while ($true) {
        Write-Host "`n--- ペルソナと基本指示の編集 ---" -ForegroundColor Green
        Write-Host "[1] AIのペルソナを編集する"
        Write-Host "[2] AIの基本指示を編集する"
        Write-Host "[b] 前のメニューに戻る"
        $choice = Read-Host "👉 選択してください"
        switch ($choice) {
            '1' {
                $original = $config.ai_persona
                $new = Edit-TextInEditor -InitialContent $original
                if ($new -ne $original) {
                    $config.ai_persona = $new
                    Write-Host "✅ ペルソナが更新されました:" -ForegroundColor Green
                    Write-Host "---" -ForegroundColor DarkGray
                    Write-Host $new -ForegroundColor Gray
                    Write-Host "---" -ForegroundColor DarkGray
                } else {
                    Write-Host "ℹ️ 変更はありませんでした。" -ForegroundColor Yellow
                }
            }
            '2' {
                $original = $config.task_instruction
                $new = Edit-TextInEditor -InitialContent $original
                if ($new -ne $original) {
                    $config.task_instruction = $new
                    Write-Host "✅ タスク指示が更新されました:" -ForegroundColor Green
                    Write-Host "---" -ForegroundColor DarkGray
                    Write-Host $new -ForegroundColor Gray
                    Write-Host "---" -ForegroundColor DarkGray
                } else {
                    Write-Host "ℹ️ 変更はありませんでした。" -ForegroundColor Yellow
                }
            }
            'b' { return $config }
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
        Write-Host "[b] 前のメニューに戻る"
        $choice = Read-Host "👉 選択してください"
        switch ($choice) {
            '1' {
                $newPropName = Read-Host "✏️ 追加したい新しい項目名を入力してください (例: test_results)"
                if ([string]::IsNullOrWhiteSpace($newPropName)) { Write-Host "❌ 項目名は空にできません。" -ForegroundColor Red; continue }
                if ($config.output_schema.devlog.properties.PSObject.Properties[$newPropName]) { Write-Host "❌ その項目は既に存在します。" -ForegroundColor Red; continue }
                $newPropDesc = Read-Host "✏️ 新しい項目の見出し(description)を入力してください"
                $newPropHint = Read-Host "✏️ 新しい項目のAIへの個別指示(prompt_hint)を入力してください"
                $newProperty = [PSCustomObject]@{ type = "string"; description = $newPropDesc; prompt_hint = $newPropHint }
                $config.output_schema.devlog.properties | Add-Member -MemberType NoteProperty -Name $newPropName -Value $newProperty
                if ($null -eq $config.output_schema.devlog.required) { $config.output_schema.devlog.required = @() }
                $config.output_schema.devlog.required += $newPropName
                Write-Host "✅ 新しい項目 '$newPropName' を追加しました。" -ForegroundColor Green
            }
            '2' {
                $propToDelete = Select-DiaryProperty -config $config -PromptMessage "削除したい項目の番号を入力してください"
                if ($null -ne $propToDelete) {
                    $config.output_schema.devlog.properties.PSObject.Properties.Remove($propToDelete)
                    $config.output_schema.devlog.required = $config.output_schema.devlog.required | Where-Object { $_ -ne $propToDelete }
                    Write-Host "✅ 項目 '$propToDelete' を削除しました。" -ForegroundColor Green
                }
            }
            '3' {
                $propToEdit = Select-DiaryProperty -config $config -PromptMessage "見出しを編集したい項目の番号を入力してください"
                if ($null -ne $propToEdit) {
                    $original = $config.output_schema.devlog.properties.$propToEdit.description
                    $new = Edit-TextInEditor -InitialContent $original
                    if ($new -ne $original) {
                        $config.output_schema.devlog.properties.$propToEdit.description = $new
                        Write-Host "✅ 見出しが更新されました: $new" -ForegroundColor Green
                    } else {
                        Write-Host "ℹ️ 変更はありませんでした。" -ForegroundColor Yellow
                    }
                }
            }
            'b' { return $config }
            default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
        }
    }
}

function Manage-DiaryContent {
    param($config)
    $propToEdit = Select-DiaryProperty -config $config -PromptMessage "個別指示を編集したい項目の番号を入力してください"
    if ($null -eq $propToEdit) { return $config }
    $originalHint = $config.output_schema.devlog.properties.$propToEdit.prompt_hints.japanese
    while ($true) {
        $masterHint = $config.output_schema.devlog.properties.$propToEdit.prompt_hints.english
        $requiredVariables = [regex]::Matches($masterHint, '{{.*?}}') | ForEach-Object { $_.Value }
        Write-Host "`n--- 個別指示の編集: $($propToEdit) (日本語) ---" -ForegroundColor Green
        if ($requiredVariables.Count -gt 0) {
            Write-Host "以下の変数は、AIが正しく動作するために必須です。編集後も必ず含めてください。" -ForegroundColor Yellow
            $requiredVariables | ForEach-Object { Write-Host "- $_" }
        }
        $newHint = Edit-TextInEditor -InitialContent $originalHint
        $missingVariables = $requiredVariables | Where-Object { $newHint -notlike "*$_*" }
        if ($missingVariables.Count -eq 0) {
            if ($newHint -ne $originalHint) {
                $config.output_schema.devlog.properties.$propToEdit.prompt_hints.japanese = $newHint
                Write-Host "✅ 個別指示 (日本語) が更新されました。" -ForegroundColor Green
            } else {
                Write-Host "ℹ️ 変更はありませんでした。" -ForegroundColor Yellow
            }
            return $config
        }
        Write-Host "❌ 必須変数が削除されているため、変更は自動的に破棄されました。" -ForegroundColor Red
        $missingVariables | ForEach-Object { Write-Host "- '$_' が見つかりません。" }
        $retry = Read-Host "👉 もう一度編集しますか？ (y/n)"
        if ($retry -notmatch '^[Yy]') {
            Write-Host "ℹ️ 編集はキャンセルされました。"
            return $config
        }
    }
}

function Manage-DiaryItems {
    param($config)
    while ($true) {
        Write-Host "`n--- 日誌の項目を編集 ---" -ForegroundColor Green
        Write-Host "[1] 日誌項目の構造を編集する (追加/削除/見出し変更)"
        Write-Host "[2] 日誌項目の個別指示を編集する (AIの応答内容を調整)"
        Write-Host "[b] 前のメニューに戻る"
        $choice = Read-Host "👉 選択してください"
        switch ($choice) {
            '1' { $config = Manage-DiaryStructure -config $config }
            '2' { $config = Manage-DiaryContent -config $config }
            'b' { return $config }
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
        Write-Host "[b] 前のメニューに戻る"
        $choice = Read-Host "👉 選択してください"
        switch ($choice) {
            '1' {
                $config.use_api_mode = -not $config.use_api_mode
                $newMode = if ($config.use_api_mode) { "APIモード (自動)" } else { "手動モード" }
                Write-Host "✅ モードを '$newMode' に切り替えました。" -ForegroundColor Green
            }
            'b' { return $config }
            default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
        }
    }
}

function Save-Preset {
    param([Parameter(Mandatory=$true)]$ConfigObject)
    $presetName = Read-Host "💾 保存するプリセット名を入力してください"
    if ([string]::IsNullOrWhiteSpace($presetName)) {
        Write-Host "❌ プリセット名は空にできません。キャンセルされました。" -ForegroundColor Red; return
    }
    $fileName = -join ($presetName.ToCharArray() | Where-Object { $_ -notin [System.IO.Path]::GetInvalidFileNameChars() })
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        Write-Host "❌ ファイル名として有効な文字がありません。キャンセルされました。" -ForegroundColor Red; return
    }
    $presetPath = Join-Path -Path $PresetsDir -ChildPath "$($fileName).json"
    if (Test-Path $presetPath) {
        $confirm = Read-Host "⚠️ プリセット '$presetName' は既に存在します。上書きしますか？ (y/n)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "ℹ️ 操作はキャンセルされました。"; return
        }
    }
    try {
        $jsonOutput = $ConfigObject | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($presetPath, $jsonOutput, [System.Text.Encoding]::UTF8)
        Write-Host "✅ プリセット '$presetName' を保存しました。" -ForegroundColor Green
    } catch {
        Write-Host "❌ プリセットの保存中にエラーが発生しました。" -ForegroundColor Red
    }
}

function Load-Preset {
    $presets = Get-ChildItem -Path $PresetsDir -Filter "*.json" | Select-Object @{N="Name"; E={$_.BaseName}}, FullName
    if ($presets.Count -eq 0) {
        Write-Host "📂 保存されているプリセットがありません。" -ForegroundColor Yellow; return $null
    }
    Write-Host "`n--- プリセット一覧 ---" -ForegroundColor Yellow
    for ($i = 0; $i -lt $presets.Count; $i++) { Write-Host "[$($i+1)] $($presets[$i].Name)" }
    Write-Host "--------------------"
    while ($true) {
        $input = Read-Host "👉 読み込むプリセットの番号を入力してください ('b'で戻る)"
        if ($input -eq 'b') { return $null }
        if ($input -match '^\d+$' -and [int]$input -ge 1 -and [int]$input -le $presets.Count) {
            $selectedPresetPath = $presets[[int]$input - 1].FullName
            try {
                $presetContent = [System.IO.File]::ReadAllText($selectedPresetPath, [System.Text.Encoding]::UTF8)
                Write-Host "✅ プリセットを読み込みました。現在の編集内容は上書きされます。" -ForegroundColor Green
                return $presetContent | ConvertFrom-Json
            } catch {
                Write-Host "❌ プリセット '$($presets[[int]$input - 1].Name)' の読み込みに失敗しました。" -ForegroundColor Red; return $null
            }
        }
        Write-Host "❌ 無効な入力です。" -ForegroundColor Red
    }
}

# --- Main Loop ---
while ($true) {
    Write-Host "`n🎨 AIプロンプト・プリセット管理" -ForegroundColor Cyan
    Write-Host "何をしますか？"
    Write-Host "[1] ペルソナと基本指示を編集する"
    Write-Host "[2] 日誌の項目を編集する"
    Write-Host "[3] API設定を編集する"
    Write-Host "---"
    Write-Host "[s] 現在の編集内容を新しいプリセットとして保存する"
    Write-Host "[l] 保存したプリセットを読み込む"
    Write-Host "[r] 初期設定ファイルから復元する (編集内容は破棄されます)"
    Write-Host "---"
    Write-Host "[q] 現在の編集内容を保存して終了する"
    Write-Host "[q!] 保存せずに終了する"
    $menuChoice = Read-Host "👉 選択してください"
    switch ($menuChoice) {
        '1' { $WorkingConfig = Manage-PersonaAndInstructions -config $WorkingConfig }
        '2' { $WorkingConfig = Manage-DiaryItems -config $WorkingConfig }
        '3' { $WorkingConfig = Manage-ApiSettings -config $WorkingConfig }
        's' { Save-Preset -ConfigObject $WorkingConfig }
        'l' { 
            $loadedPreset = Load-Preset
            if ($null -ne $loadedPreset) { $WorkingConfig = $loadedPreset }
        }
        'r' {
             if (-not (Test-Path $DefaultConfigFile)) {
                Write-Host "❌ 初期設定ファイルが見つかりません: $DefaultConfigFile" -ForegroundColor Red
                continue
            }
            $confirm = Read-Host "❓ 初期設定を復元しますか？現在の編集内容はすべて破棄されます。 (y/n)"
            if ($confirm -match '^[Yy]') {
                try {
                    $defaultContent = [System.IO.File]::ReadAllText($DefaultConfigFile, [System.Text.Encoding]::UTF8)
                    $WorkingConfig = $defaultContent | ConvertFrom-Json -ErrorAction Stop
                    Write-Host "✅ 初期設定を読み込みました。" -ForegroundColor Green
                } catch {
                    Write-Host "❌ 初期設定ファイルの読み込みに失敗しました。" -ForegroundColor Red
                }
            } else {
                Write-Host "ℹ️ 操作はキャンセルされました。"
            }
        }
        'q' {
            $jsonOutput = $WorkingConfig | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($ConfigFile, $jsonOutput, [System.Text.Encoding]::UTF8)
            Write-Host "✅ 設定を '$ConfigFile' に保存しました。" -ForegroundColor Green
            exit 0
        }
        'q!' {
             Write-Host "🛑 保存せずに終了します。" -ForegroundColor Yellow
             exit 0
        }
        default { Write-Host "❌ 無効な選択です。" -ForegroundColor Red }
    }
}
