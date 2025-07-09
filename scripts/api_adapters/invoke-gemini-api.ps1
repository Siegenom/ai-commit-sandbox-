#Requires -Version 5.1
<#
.SYNOPSIS
    Invokes the Google Gemini API with a structured prompt file.
.PARAMETER PromptFilePath
    Path to the temporary JSON file containing the structured prompt.
.PARAMETER ApiConfig
    A PSCustomObject containing API configuration like the API key.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PromptFilePath,

    [Parameter(Mandatory=$true)]
    [psobject]$ApiConfig
)

try {
    $structuredPrompt = Get-Content -Path $PromptFilePath -Raw | ConvertFrom-Json
} catch {
    Write-Output "ERROR: Failed to read or parse the prompt file: $PromptFilePath. Error: $($_.Exception.Message)"
    exit 1
}

# --- プロンプトの最終組み立て ---
# 構造化されたオブジェクトから各パーツを抽出し、一つのテキストブロックに結合する
$finalPromptText = @"
# Persona
$($structuredPrompt.system_prompt.persona)

# Task
$($structuredPrompt.system_prompt.task)

# Output Schema Definition
$($structuredPrompt.system_prompt.output_schema_definition | ConvertTo-Json -Depth 10 -Compress)

# High Level Goal by User
$($structuredPrompt.user_context.high_level_goal)

# Git Diff to be analyzed
```
$($structuredPrompt.user_context.git_context.diff)
```
"@

# --- APIリクエストの構築 ---
$apiKey = $ApiConfig.api_key
if ([string]::IsNullOrEmpty($apiKey)) {
    $apiKey = $env:GEMINI_API_KEY
}
if ([string]::IsNullOrEmpty($apiKey)) {
    Write-Output "ERROR: Gemini API key is not found. Please set it in prompt-config.json or as an environment variable 'GEMINI_API_KEY'."
    exit 1
}

$apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash-latest:generateContent?key=$apiKey"

$headers = @{
    "Content-Type" = "application/json"
}

$body = @{
    contents = @(
        @{
            parts = @(
                @{
                    text = $finalPromptText
                }
            )
        }
    )
} | ConvertTo-Json -Depth 10

# --- API呼び出しとリトライ処理 ---
$maxRetries = 2
$retryDelaySeconds = 3
$attempt = 0

while ($attempt -lt $maxRetries) {
    $attempt++
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $body -ContentType "application/json"
        
        $generatedText = $response.candidates[0].content.parts[0].text
        Write-Output $generatedText
        exit 0 # 成功したら終了
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.Value__
        $errorMessage = $_.Exception.Message
        
        if ($statusCode -in 500, 502, 503, 504) {
            Write-Warning "Attempt $attempt failed with status $statusCode. Retrying in $retryDelaySeconds seconds..."
            Start-Sleep -Seconds $retryDelaySeconds
        } else {
            Write-Output "ERROR: API call failed with status $statusCode. Message: $errorMessage"
            exit 1
        }
    }
}

Write-Output "ERROR: API call failed after $maxRetries attempts."
exit 1
