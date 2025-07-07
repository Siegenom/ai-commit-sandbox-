# --- SCRIPT PARAMETERS ---
param(
    [Parameter(Mandatory=$true)]
    [string]$PromptFilePath,

    [Parameter(Mandatory=$true)]
    [PSCustomObject]$ApiConfig
)

# SCRIPT-WIDE TRY/CATCH FOR DIAGNOSTICS
try {
    # --- DIAGNOSTIC SETUP ---
    . (Join-Path -Path $PSScriptRoot -ChildPath "..\logger.ps1")

    Write-Log "--- invoke-gemini-api.ps1 (Here-String Version) STARTED ---"
    
    # --- FILE READ ---
    if (-not (Test-Path $PromptFilePath)) {
        throw "Prompt file not found at path: $PromptFilePath"
    }
    $AiPrompt = Get-Content -Path $PromptFilePath -Raw -Encoding UTF8
    Write-Log "Step A1: Successfully read prompt from file. Length: $($AiPrompt.Length)"

    # --- API KEY VALIDATION ---
    $envVarName = $ApiConfig.api_key_env
    $apiKey = (Get-Item -Path "env:\$envVarName" -ErrorAction SilentlyContinue).Value
    if ([string]::IsNullOrEmpty($apiKey)) {
        throw "API key not found in environment variable '$envVarName'."
    }
    Write-Log "Step A2: API Key Found."

    # --- JSON PARSING ---
    $promptObject = $AiPrompt | ConvertFrom-Json
    Write-Log "Step A3: Incoming AiPrompt JSON parsed successfully."

    # --- REQUEST BODY CONSTRUCTION (HERE-STRING METHOD) ---
    Write-Log "Step A4: Building request body using Here-Strings for robustness."

    # Part 1: System Instruction
    $schemaJson = $promptObject.system_prompt.output_schema_definition | ConvertTo-Json -Depth 10 -Compress
    # [FIX] Use a Here-String (@''@) to safely embed multi-line text with special characters.
    $systemInstructionText = @'
$($promptObject.system_prompt.persona)

$($promptObject.system_prompt.task)

```json
$schemaJson
```
'@

    $systemInstructionPayload = @{
        parts = @(
            @{ text = $systemInstructionText }
        )
    }

    # Part 2: User Context
    # [FIX] Use a Here-String (@''@) for the user context as well.
    $stagedFilesText = $promptObject.user_context.git_context.staged_files -join [System.Environment]::NewLine
    $userContextText = @'
# User's Goal
$($promptObject.user_context.high_level_goal)

# Staged Files
$stagedFilesText

# Git Diff
```diff
$($promptObject.user_context.git_context.diff)
```
'@

    $userContentPayload = @{
        parts = @(
            @{ text = $userContextText }
        )
    }

    # Part 3: Final Assembly
    $finalPayload = @{
        systemInstruction = $systemInstructionPayload
        contents = @( $userContentPayload )
    }
    
    $requestBody = $finalPayload | ConvertTo-Json -Depth 10
    
    $logMessage = "         - Request body built. Length: {0}" -f $requestBody.Length
    Write-Log $logMessage

    # --- API CALL ---
    Write-Log "Step A5: Calling Gemini API."
    $apiUrlTemplate = '{0}?key={1}'
    $apiUrl = $apiUrlTemplate -f $ApiConfig.api_endpoints.gemini.url, $apiKey
    $headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }
    Write-Log ("         - URL: {0}" -f $apiUrl)

    $responseJson = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $requestBody -ErrorAction Stop
    Write-Log "         - API call successful."

    # --- RESPONSE PROCESSING ---
    Write-Log "Step A6: Processing API response."
    $candidate = $responseJson.candidates | Select-Object -First 1
    $part = $candidate.content.parts | Select-Object -First 1
    $generatedText = $part.text.Trim()
    if ($null -ne $generatedText) {
        $cleanedText = $generatedText -replace '(?s)^```(json)?\s*|\s*```$'
        Write-Log "         - Successfully extracted and cleaned text. Returning to caller."
        return $cleanedText
    } else {
        throw "API response did not contain the expected text content."
    }
} catch {
    $errorMessage = "FATAL ERROR in invoke-gemini-api.ps1: $($_.Exception.Message)"
    $fullError = $_ | Out-String
    Write-Log $errorMessage
    Write-Log "--- FULL EXCEPTION DETAILS (invoke-gemini-api.ps1) ---"
    Write-Log $fullError
    Write-Log "--- DIAGNOSTIC MODE ENDED DUE TO ERROR (invoke-gemini-api.ps1) ---"
    return "ERROR: $($_.Exception.Message)"
}
