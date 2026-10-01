[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot,
    [string]$AccessToken = $env:ACCESS_TOKEN,
    [string]$CatalogPath,
    [string]$CodexPath = 'codex',
    [string]$PythonPath = 'python',
    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 30,
    [switch]$Check,
    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-Executable {
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$Purpose)
    $resolved = Get-Command -Name $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $resolved) { throw "$Purpose executable was not found: $Command" }
    $path = if ($resolved.Path) { [string]$resolved.Path } else { [string]$resolved.Source }
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "$Purpose command does not resolve to an executable file: $Command"
    }
    return $path
}

function New-CodexStartInfo {
    param([Parameter(Mandatory)][string]$Command)
    $path = Resolve-Executable -Command $Command -Purpose 'Codex CLI'
    $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $arguments = [Collections.Generic.List[string]]::new()
    if ($extension -eq '.ps1') {
        $startInfo.FileName = Resolve-Executable -Command 'pwsh' -Purpose 'PowerShell 7'
        [void]$arguments.Add('-NoProfile')
        [void]$arguments.Add('-File')
        [void]$arguments.Add($path)
    }
    elseif ($extension -in @('.cmd', '.bat')) {
        throw "Codex CLI resolved to a $extension wrapper. Install or select the native codex executable with -CodexPath."
    }
    else { $startInfo.FileName = $path }
    [void]$arguments.Add('app-server')
    [void]$arguments.Add('--listen')
    [void]$arguments.Add('stdio://')
    # ArgumentList exists in .NET Core (PowerShell 7), but not in Windows
    # PowerShell 5.1. Use the legacy escaped command-line string there.
    $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    }
    else {
        $quoted = foreach ($argument in $arguments) {
            if ($argument -match '[\s"]') { '"' + $argument.Replace('"', '\"') + '"' } else { $argument }
        }
        $startInfo.Arguments = ($quoted -join ' ')
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($encodingProperty in @('StandardInputEncoding', 'StandardOutputEncoding', 'StandardErrorEncoding')) {
        if ($null -ne $startInfo.PSObject.Properties[$encodingProperty]) {
            $startInfo.$encodingProperty = [Text.UTF8Encoding]::new($false)
        }
    }
    return $startInfo
}

function Get-RemainingMilliseconds {
    param([Diagnostics.Stopwatch]$Stopwatch, [int]$LimitSeconds)
    $remaining = ($LimitSeconds * 1000) - [int]$Stopwatch.ElapsedMilliseconds
    if ($remaining -le 0) { throw "Operation timed out after $LimitSeconds seconds." }
    return $remaining
}

function Read-JsonRpcResponse {
    param(
        [Diagnostics.Process]$Process, [int]$RequestId, [string]$Method,
        [Diagnostics.Stopwatch]$Stopwatch, [int]$LimitSeconds
    )
    while ($true) {
        if ($Process.HasExited) { throw "Codex app-server exited before replying to '$Method'." }
        $readTask = $Process.StandardOutput.ReadLineAsync()
        $remaining = Get-RemainingMilliseconds -Stopwatch $Stopwatch -LimitSeconds $LimitSeconds
        if (-not $readTask.Wait($remaining)) {
            throw "Codex app-server timed out while processing '$Method'."
        }
        $line = $readTask.Result
        if ($null -eq $line) { throw "Codex app-server closed its output before replying to '$Method'." }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $message = $line | ConvertFrom-Json }
        catch { throw "Codex app-server returned invalid JSON while processing '$Method'." }
        $responseId = Get-PropertyValue -InputObject $message -Name 'id'
        if ($null -eq $responseId -or [int64]$responseId -ne $RequestId) { continue }
        $rpcError = Get-PropertyValue -InputObject $message -Name 'error'
        if ($null -ne $rpcError) {
            $code = Get-PropertyValue -InputObject $rpcError -Name 'code'
            $suffix = if ($null -ne $code) { " (JSON-RPC code $code)" } else { '' }
            throw "Codex app-server request '$Method' failed$suffix."
        }
        $resultProperty = $message.PSObject.Properties['result']
        if ($null -eq $resultProperty) {
            throw "Codex app-server response to '$Method' did not contain a result."
        }
        return $resultProperty.Value
    }
}

function Send-JsonRpcRequest {
    param(
        [Diagnostics.Process]$Process, [int]$RequestId, [string]$Method,
        [AllowNull()][object]$Params, [Diagnostics.Stopwatch]$Stopwatch, [int]$LimitSeconds
    )
    $request = [ordered]@{
        jsonrpc = '2.0'; id = $RequestId; method = $Method
        params = if ($null -eq $Params) { [ordered]@{} } else { $Params }
    }
    $Process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 12 -Compress))
    $Process.StandardInput.Flush()
    return Read-JsonRpcResponse -Process $Process -RequestId $RequestId -Method $Method `
        -Stopwatch $Stopwatch -LimitSeconds $LimitSeconds
}

function Send-JsonRpcNotification {
    param([Diagnostics.Process]$Process, [string]$Method, [AllowNull()][object]$Params)
    $notification = [ordered]@{
        jsonrpc = '2.0'; method = $Method
        params = if ($null -eq $Params) { [ordered]@{} } else { $Params }
    }
    $Process.StandardInput.WriteLine(($notification | ConvertTo-Json -Depth 12 -Compress))
    $Process.StandardInput.Flush()
}

function Get-AppServerCatalog {
    param([string]$Command, [int]$LimitSeconds)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-CodexStartInfo -Command $Command
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $stderrTask = $null
    $processStarted = $false
    try {
        if (-not $process.Start()) { throw 'Codex app-server could not be started.' }
        $processStarted = $true
        # Drain stderr to avoid blocking. It can include authentication details and is never printed.
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $requestId = 1
        [void](Send-JsonRpcRequest -Process $process -RequestId $requestId -Method 'initialize' -Params ([ordered]@{
            clientInfo = [ordered]@{
                name = 'codex-token-saver'
                title = 'Codex dynamic model selection'
                version = '1.0'
            }
            capabilities = [ordered]@{}
        }) -Stopwatch $stopwatch -LimitSeconds $LimitSeconds)
        Send-JsonRpcNotification -Process $process -Method 'initialized' -Params ([ordered]@{})
        $requestId++
        $accountResult = Send-JsonRpcRequest -Process $process -RequestId $requestId -Method 'account/read' `
            -Params ([ordered]@{ refreshToken = $false }) -Stopwatch $stopwatch -LimitSeconds $LimitSeconds
        $account = Get-PropertyValue -InputObject $accountResult -Name 'account'
        $accountType = [string](Get-PropertyValue -InputObject $account -Name 'type')
        if ($accountType -notmatch '^(?i:chatgpt)$') {
            throw 'Codex CLI is not signed in with a ChatGPT account.'
        }
        $allModels = [Collections.Generic.List[object]]::new()
        $seenCursors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $cursor = $null
        do {
            $requestId++
            $parameters = [ordered]@{ limit = 100; includeHidden = $false; cursor = $cursor }
            $page = Send-JsonRpcRequest -Process $process -RequestId $requestId -Method 'model/list' `
                -Params $parameters -Stopwatch $stopwatch -LimitSeconds $LimitSeconds
            $data = Get-PropertyValue -InputObject $page -Name 'data'
            if ($null -eq $data) { throw 'Codex app-server model/list response did not contain data.' }
            foreach ($model in @($data)) { $allModels.Add($model) }
            $cursor = Get-PropertyValue -InputObject $page -Name 'nextCursor'
            if (-not [string]::IsNullOrWhiteSpace([string]$cursor) -and -not $seenCursors.Add([string]$cursor)) {
                throw 'Codex app-server returned a repeated model catalog cursor.'
            }
        } while (-not [string]::IsNullOrWhiteSpace([string]$cursor))
        return @($allModels)
    }
    catch { throw "Live Codex model discovery failed: $($_.Exception.Message)" }
    finally {
        $stopwatch.Stop()
        if ($processStarted) {
            try { $process.StandardInput.Close() } catch { }
            if (-not $process.HasExited) { try { $process.Kill($true) } catch { } }
            try { [void]$process.WaitForExit(2000) } catch { }
        }
        if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
            try { [void]$stderrTask.GetAwaiter().GetResult() } catch { }
        }
        $process.Dispose()
    }
}

function Get-CatalogArray {
    param([AllowNull()][object]$Payload)
    if ($null -eq $Payload) { throw 'The model catalog is empty.' }
    if ($Payload -is [Array]) { return @($Payload) }
    $result = Get-PropertyValue -InputObject $Payload -Name 'result'
    if ($null -ne $result) { return Get-CatalogArray -Payload $result }
    foreach ($name in @('models', 'data')) {
        $value = Get-PropertyValue -InputObject $Payload -Name $name
        if ($null -ne $value) { return @($value) }
    }
    throw 'Unsupported model catalog shape. Expected an array, .models, .data, or a JSON-RPC result containing one.'
}

function ConvertTo-NormalizedCatalog {
    param([array]$Models)
    $normalized = foreach ($item in $Models) {
        if ($null -eq $item) { continue }
        $model = Get-PropertyValue -InputObject $item -Name 'model'
        if ([string]::IsNullOrWhiteSpace([string]$model)) { $model = Get-PropertyValue $item 'slug' }
        if ([string]::IsNullOrWhiteSpace([string]$model)) { $model = Get-PropertyValue $item 'id' }
        if ([string]::IsNullOrWhiteSpace([string]$model)) { continue }
        $visibility = Get-PropertyValue -InputObject $item -Name 'visibility'
        if ($null -ne $visibility -and [string]$visibility -ne 'list') { continue }
        $hidden = Get-PropertyValue -InputObject $item -Name 'hidden'
        if ($null -ne $hidden -and [bool]$hidden) { continue }
        $effortProperty = $item.PSObject.Properties['supportedReasoningEfforts']
        $hasEffortMetadata = $null -ne $effortProperty -and $null -ne $effortProperty.Value
        $efforts = @()
        if ($hasEffortMetadata) {
            $efforts = @(foreach ($entry in @($effortProperty.Value)) {
                $effort = if ($entry -is [string]) { [string]$entry } else {
                    [string](Get-PropertyValue -InputObject $entry -Name 'reasoningEffort')
                }
                if (-not [string]::IsNullOrWhiteSpace($effort)) { $effort }
            })
        }
        [pscustomobject]@{
            Model = [string]$model
            HasEffortMetadata = $hasEffortMetadata
            SupportedEfforts = $efforts
        }
    }
    if (-not $normalized) { throw 'The model catalog did not contain any visible models.' }
    return @($normalized)
}

function Get-VersionParts {
    param([string]$Model, [string]$Family)
    $pattern = if ($Family -ieq 'gpt') {
        '^gpt-(?<version>\d+(?:\.\d+)*)(?:-[a-z][a-z0-9]*)?$'
    }
    else {
        '^gpt-(?<version>\d+(?:\.\d+)*)-' + [regex]::Escape($Family) + '$'
    }
    $match = [regex]::Match($Model, $pattern, 'IgnoreCase')
    if (-not $match.Success) { return $null }
    $parts = [Collections.Generic.List[int]]::new()
    foreach ($part in $match.Groups['version'].Value.Split('.')) {
        $parsed = 0
        if (-not [int]::TryParse($part, [ref]$parsed)) { return $null }
        $parts.Add($parsed)
    }
    if ($parts.Count -eq 1) { $parts.Add(0) }
    return @($parts)
}

function Compare-VersionParts {
    param([int[]]$Left, [int[]]$Right)
    $length = [Math]::Max($Left.Count, $Right.Count)
    for ($index = 0; $index -lt $length; $index++) {
        $leftPart = if ($index -lt $Left.Count) { $Left[$index] } else { 0 }
        $rightPart = if ($index -lt $Right.Count) { $Right[$index] } else { 0 }
        if ($leftPart -gt $rightPart) { return 1 }
        if ($leftPart -lt $rightPart) { return -1 }
    }
    return 0
}

function Select-Model {
    param([array]$Catalog, [array]$Families, [string]$ReasoningEffort, [string]$RoleName)
    foreach ($familyValue in $Families) {
        $family = [string]$familyValue
        $best = $null
        $bestVersion = $null
        foreach ($candidate in $Catalog) {
            $version = Get-VersionParts -Model $candidate.Model -Family $family
            if ($null -eq $version) { continue }
            if ($candidate.HasEffortMetadata -and $candidate.SupportedEfforts -notcontains $ReasoningEffort) { continue }
            if ($null -eq $best -or (Compare-VersionParts -Left $version -Right $bestVersion) -gt 0) {
                $best = $candidate
                $bestVersion = $version
            }
        }
        if ($null -ne $best) { return [string]$best.Model }
    }
    $visibleModels = @($Catalog | ForEach-Object { [string]$_.Model } | Sort-Object -Unique)
    $shownModels = @($visibleModels | Select-Object -First 20)
    $catalogSummary = if ($visibleModels.Count -gt 20) {
        "Visible catalog models (first 20 of $($visibleModels.Count)): $($shownModels -join ', ')"
    }
    else {
        "Visible catalog models ($($visibleModels.Count)): $($shownModels -join ', ')"
    }
    throw "No available model supports role '$RoleName' with reasoning effort '$ReasoningEffort'. Preferences: $($Families -join ', '). $catalogSummary"
}

function Get-HttpCatalog {
    param([string]$Token, [string]$Endpoint, [int]$LimitSeconds)
    if ($Endpoint -cne 'https://api.openai.com/v1/models') {
        throw 'OAuth model discovery is allowed only through https://api.openai.com/v1/models.'
    }
    try {
        return Invoke-RestMethod -Method Get -Uri $Endpoint -Headers @{ Authorization = "Bearer $Token" } `
            -MaximumRedirection 0 -TimeoutSec $LimitSeconds
    }
    catch { throw 'OAuth model discovery failed. Verify the access token and network connection.' }
}

if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
else { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path }
$runtimeRoot = Join-Path $RepoRoot '.codex'
$policyPath = Join-Path $runtimeRoot 'model-policy.json'
$rendererPath = Join-Path $runtimeRoot 'apply_models.py'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) { throw "Model policy not found: $policyPath" }
if (-not (Test-Path -LiteralPath $rendererPath -PathType Leaf)) { throw "Model renderer not found: $rendererPath" }
if ($NoBackup) { Write-Warning '-NoBackup is deprecated. Generated runtime files are managed by the renderer.' }

$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
if ((Get-PropertyValue $policy 'version') -ne 1) { throw 'Unsupported model policy version. Expected version 1.' }
$catalogPolicy = Get-PropertyValue $policy 'catalog'
$endpoint = [string](Get-PropertyValue $catalogPolicy 'endpoint')
if (-not [string]::IsNullOrWhiteSpace($CatalogPath)) {
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw "Catalog file not found: $CatalogPath" }
    $rawModels = Get-CatalogArray ((Get-Content -Raw -LiteralPath $CatalogPath) | ConvertFrom-Json)
    $catalogSource = 'file'
}
elseif (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
    $rawModels = Get-CatalogArray (Get-HttpCatalog -Token $AccessToken -Endpoint $endpoint -LimitSeconds $TimeoutSeconds)
    $catalogSource = 'oauth-endpoint'
}
else {
    $rawModels = Get-AppServerCatalog -Command $CodexPath -LimitSeconds $TimeoutSeconds
    $catalogSource = 'codex-app-server'
}

$catalog = ConvertTo-NormalizedCatalog -Models @($rawModels)
if (@($catalog | Where-Object { -not $_.HasEffortMetadata }).Count -gt 0) {
    Write-Warning 'Reasoning-effort metadata is unavailable for one or more catalog entries; configured policy efforts will be preserved.'
}
$mainPolicy = Get-PropertyValue $policy 'main'
$defaultPolicy = Get-PropertyValue $policy 'default_subagent'
$rolesPolicy = Get-PropertyValue $policy 'roles'
if ($null -eq $mainPolicy -or $null -eq $defaultPolicy -or $null -eq $rolesPolicy) {
    throw 'Model policy must define main, default_subagent, and roles.'
}
$mainEffort = [string](Get-PropertyValue $mainPolicy 'reasoning_effort')
$defaultEffort = [string](Get-PropertyValue $defaultPolicy 'reasoning_effort')
$mainModel = Select-Model -Catalog $catalog -Families @($mainPolicy.families) -ReasoningEffort $mainEffort -RoleName 'main'
$defaultModel = Select-Model -Catalog $catalog -Families @($defaultPolicy.families) -ReasoningEffort $defaultEffort -RoleName 'default_subagent'
$resolvedRoles = [ordered]@{}
foreach ($roleProperty in $rolesPolicy.PSObject.Properties) {
    $rolePolicy = $roleProperty.Value
    $roleEffort = [string](Get-PropertyValue $rolePolicy 'reasoning_effort')
    $roleModel = Select-Model -Catalog $catalog -Families @($rolePolicy.families) -ReasoningEffort $roleEffort -RoleName $roleProperty.Name
    $resolvedRoles[$roleProperty.Name] = [ordered]@{ model = $roleModel; reasoning_effort = $roleEffort }
}
$selection = [ordered]@{
    main = [ordered]@{ model = $mainModel; reasoning_effort = $mainEffort }
    default_subagent = [ordered]@{ model = $defaultModel; reasoning_effort = $defaultEffort }
    roles = $resolvedRoles
    available_models = @($catalog | ForEach-Object { $_.Model } | Sort-Object -Unique)
    catalog_source = $catalogSource
}

Write-Host "Catalog source:          $catalogSource"
Write-Host "Main model:             $mainModel ($mainEffort)"
Write-Host "Default subagent model: $defaultModel ($defaultEffort)"
foreach ($role in $resolvedRoles.GetEnumerator()) {
    Write-Host ("{0,-24} {1} ({2})" -f $role.Key, $role.Value.model, $role.Value.reasoning_effort)
}
if ($WhatIfPreference) {
    Write-Host 'What if: resolved model choices; renderer was not invoked.'
    return
}
$action = if ($Check) { 'Check generated Codex model configuration' } else { 'Render generated Codex model configuration' }
if (-not $PSCmdlet.ShouldProcess($runtimeRoot, $action)) { return }
$temporarySelection = Join-Path ([IO.Path]::GetTempPath()) ("codex-model-selection-{0}.json" -f [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($temporarySelection, ($selection | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $pythonArguments = @($rendererPath, '--selection', $temporarySelection, '--root', $runtimeRoot)
    if ($Check) { $pythonArguments += '--check' }
    & $PythonPath @pythonArguments
    $rendererExitCode = $LASTEXITCODE
    if ($rendererExitCode -ne 0) { throw "Model renderer failed with exit code $rendererExitCode." }
}
finally {
    if (Test-Path -LiteralPath $temporarySelection) { Remove-Item -LiteralPath $temporarySelection -Force }
}
Write-Host 'Model resolution complete.'
