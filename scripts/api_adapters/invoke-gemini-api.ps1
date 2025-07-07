<#
.SYNOPSIS
    Invokes the Google Gemini API to get a response for a given prompt.
.DESCRIPTION
    This script acts as an adapter for the Gemini API.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$AiPrompt,

    [Parameter(Mandatory=$true)]
    [PSCustomObject]$ApiConfig
)

$envVarName = $ApiConfig.api_key_env
$apiKey = (Get-Item -Path "env:\$envVarName" -ErrorAction SilentlyContinue).Value
if ([string]::IsNullOrEmpty($apiKey)) {
    Write-Error "API key not found. Please set the '$($ApiConfig.api_key_env)' environment variable."
    return "ERROR:API_KEY_NOT_FOUND"
}

# Parse the incoming JSON prompt
$promptObject = $AiPrompt | ConvertFrom-Json

# --- Build the request body safely, avoiding "dangerous structures" ---
# This follows the "template and data separation" pattern.

# Build the system instruction part
$schemaJson = $promptObject.system_prompt.output_schema_definition | ConvertTo-Json -Depth 10 -Compress
$systemInstructionParts = @(
    $promptObject.system_prompt.persona,
    "",
    $promptObject.system_prompt.task,
    "",
    "```json",
    $schemaJson,
    "```"
)
$systemInstructionText = $systemInstructionParts -join [System.Environment]::NewLine

# Build the user context part
$userContextParts = @(
    "# User's Goal",
    $promptObject.user_context.high_level_goal,
    "",
    "# Staged Files",
    ($promptObject.user_context.git_context.staged_files -join [System.Environment]::NewLine),
    "",
    "# Git Diff",
    "```diff",
    $promptObject.user_context.git_context.diff,
    "```"
)
$userContextText = $userContextParts -join [System.Environment]::NewLine

# Assemble the final request body
$requestBody = @{
    systemInstruction = @{
        parts = @(@{ text = $systemInstructionText })
    }
    contents = @(
        @{
            parts = @(
                @{
                    text = $userContextText
                }
            )
        }
    )
} | ConvertTo-Json -Depth 10

# --- Call the API ---
# [FIXED] Use the -f format operator for safer string construction.
# This avoids potential parsing issues with complex inline expressions like "$($...)"
$apiUrlTemplate = '{0}?key={1}'
$apiUrl = $apiUrlTemplate -f $ApiConfig.api_endpoints.gemini.url, $apiKey

$headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }

try {
    $responseJson = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $requestBody -ErrorAction Stop
    
    # [FIXED] Add more robust checks for the response structure.
    $candidate = $responseJson.candidates | Select-Object -First 1
    $part = $candidate.content.parts | Select-Object -First 1
    $generatedText = $part.text.Trim()

    if ($null -ne $generatedText) {
        # The AI might still wrap the JSON in backticks, so we need to clean it.
        return $generatedText -replace '(?s)^```(json)?\s*|\s*```$'
    } else {
        Write-Error "API response did not contain the expected text content."
        return "ERROR:API_INVALID_RESPONSE"
    }
} catch {
    Write-Error "Error calling Gemini API: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        try {
            $errorStream = $_.Exception.Response.GetResponseStream()
            $streamReader = New-Object System.IO.StreamReader($errorStream)
            $errorDetails = $streamReader.ReadToEnd()
            Write-Host "--- API Error Details ---`n$errorDetails" -ForegroundColor Red
        } catch {
            Write-Warning "Could not read the full error response body."
        }
    }
    return "ERROR:API_CALL_FAILED"
}

