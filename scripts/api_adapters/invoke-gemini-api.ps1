# --- SCRIPT PARAMETERS ---
param(
    [Parameter(Mandatory=$true)]
    [string]$PromptFilePath,

    [Parameter(Mandatory=$true)]
    [PSCustomObject]$ApiConfig
)

try {
    # --- FILE READ ---
    if (-not (Test-Path $PromptFilePath)) {
        throw "Prompt file not found at path: $PromptFilePath"
    }
    $AiPrompt = Get-Content -Path $PromptFilePath -Raw -Encoding UTF8

    # --- API KEY VALIDATION ---
    $envVarName = $ApiConfig.api_key_env
    $apiKey = (Get-Item -Path "env:\$envVarName" -ErrorAction SilentlyContinue).Value
    if ([string]::IsNullOrEmpty($apiKey)) {
        throw "API key not found in environment variable '$envVarName'."
    }

    # --- JSON PARSING ---
    $promptObject = $AiPrompt | ConvertFrom-Json

    # --- REQUEST BODY CONSTRUCTION ---
    
    # Part 1: System Instruction
    $schemaJson = $promptObject.system_prompt.output_schema_definition | ConvertTo-Json -Depth 10 -Compress
    
    # Use a literal here-string (@'...'@) as a template for robustness.
    # This prevents the PowerShell parser from misinterpreting characters within the variables.
    $systemInstructionTemplate = @'
{0}

{1}

```json
{2}
```
'@
    $systemInstructionText = $systemInstructionTemplate -f $promptObject.system_prompt.persona, $promptObject.system_prompt.task, $schemaJson

    $systemInstructionPayload = @{
        parts = @(
            @{ text = $systemInstructionText }
        )
    }

    # Part 2: User Context
    $stagedFilesText = $promptObject.user_context.git_context.staged_files -join [System.Environment]::NewLine
    $userContextTemplate = @'
# User's Goal
{0}

# Staged Files
{1}

# Git Diff
```diff
{2}
```
'@
    $userContextText = $userContextTemplate -f $promptObject.user_context.high_level_goal, $stagedFilesText, $promptObject.user_context.git_context.diff

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
    
    # --- API CALL ---
    $apiUrlTemplate = '{0}?key={1}'
    $apiUrl = $apiUrlTemplate -f $ApiConfig.api_endpoints.gemini.url, $apiKey
    $headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }

    $responseJson = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $requestBody -ErrorAction Stop

    # --- RESPONSE PROCESSING ---
    $candidate = $responseJson.candidates | Select-Object -First 1
    $part = $candidate.content.parts | Select-Object -First 1
    $generatedText = $part.text.Trim()
    if ($null -ne $generatedText) {
        $cleanedText = $generatedText -replace '(?s)^```(json)?\s*|\s*```$'
        return $cleanedText
    } else {
        throw "API response did not contain the expected text content."
    }
} catch {
    $errorMessage = "FATAL ERROR in invoke-gemini-api.ps1: $($_.Exception.Message)"
    # Return a formatted error string that the calling script can reliably check.
    return "ERROR: $errorMessage"
}
