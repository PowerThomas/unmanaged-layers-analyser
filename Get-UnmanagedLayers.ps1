<#PSScriptInfo
.VERSION 1.0.0
.GUID 7844f1fb-6004-4a9f-81fb-a7faeddaff22
.AUTHOR PowerThomas
.COPYRIGHT (c) 2026 PowerThomas. All rights reserved.
.TAGS PowerPlatform Dataverse PowerShell UnmanagedLayers ALM SolutionLayers
.LICENSEURI https://github.com/PowerThomas/unmanaged-layers-analyser/blob/master/LICENSE
.PROJECTURI https://github.com/PowerThomas/unmanaged-layers-analyser
.RELEASENOTES
    1.0.0 - Initial release.
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Detects unmanaged layers in a Power Platform / Dataverse solution.
.DESCRIPTION
    Interactive script:
      1. Select an environment
      2. Select a solution
      3. All unmanaged ("Active") layers are retrieved and displayed
      4. Optional CSV export
.NOTES
    Requires: Azure CLI (https://aka.ms/installazurecliwindows)
    Authentication: via 'az login' — works with Conditional Access policies
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Constants ──────────────────────────────────────────────────────────

# Resource URLs for az account get-access-token
$script:ADMIN_API_RESOURCE  = 'https://service.powerapps.com/'
$script:ADMIN_API_BASE      = 'https://api.bap.microsoft.com'
$script:DATAVERSE_VERSION = 'v9.2'
$script:BATCH_SIZE        = 50

# componenttype integer → human-readable name
$script:COMPONENT_TYPE_MAP = @{
    1   = 'Entity';              2   = 'Attribute';              3   = 'Relationship'
    4   = 'AttributePicklistValue'; 5 = 'AttributeLookupValue';  6   = 'ViewAttribute'
    7   = 'LocalizedLabel';      9   = 'OptionSet';              10  = 'EntityRelationship'
    13  = 'ManagedProperty';     14  = 'EntityKey';              16  = 'Privilege'
    20  = 'Role';                21  = 'RolePrivilege';          22  = 'DisplayString'
    24  = 'Form';                26  = 'SavedQuery';             29  = 'Workflow'
    31  = 'Report';              36  = 'EmailTemplate';          44  = 'DuplicateRule'
    47  = 'AttributeMap';        48  = 'RibbonCommand';          50  = 'RibbonCustomization'
    55  = 'RibbonDiff';          59  = 'SavedQueryVisualization'; 60 = 'SystemForm'
    61  = 'WebResource';         62  = 'SiteMap';                63  = 'ConnectionRole'
    66  = 'CustomControl';       70  = 'FieldSecurityProfile';   71  = 'FieldPermission'
    90  = 'PluginType';          91  = 'PluginAssembly';         92  = 'SDKMessageProcessingStep'
    95  = 'ServiceEndpoint';     152 = 'SLA';                    153 = 'SLAItem'
    161 = 'MobileOfflineProfile'; 300 = 'CanvasApp';             371 = 'Connector'
    380 = 'EnvironmentVariableDefinition'; 381 = 'EnvironmentVariableValue'
    401 = 'AIProject';           402 = 'AIConfiguration'
}

#endregion

#region ── UI helpers ─────────────────────────────────────────────────────────

function Write-Banner {
    Write-Host ''
    Write-Host '  ╔══════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '  ║     Unmanaged Layers Analyser  —  Power Platform     ║' -ForegroundColor Cyan
    Write-Host '  ╚══════════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Section {
    param([string]$Title)
    $bar = '─' * ($Title.Length + 4)
    Write-Host ''
    Write-Host "  ┌$bar┐" -ForegroundColor DarkCyan
    Write-Host "  │  $Title  │" -ForegroundColor Cyan
    Write-Host "  └$bar┘" -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-Step    { param([string]$Msg) Write-Host "  ▸ $Msg" -ForegroundColor DarkCyan }
function Write-Ok      { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warning2 { param([string]$Msg) Write-Host "  ! $Msg" -ForegroundColor Yellow }

function Invoke-MenuChoice {
    param([string]$Prompt, [int]$Min, [int]$Max)
    while ($true) {
        Write-Host "  $Prompt" -ForegroundColor White -NoNewline
        $raw = Read-Host
        if ($raw -match '^\d+$') {
            $n = [int]$raw
            if ($n -ge $Min -and $n -le $Max) { return $n }
        }
        Write-Warning2 "Enter a number between $Min and $Max."
    }
}

function Get-ComponentTypeName {
    param([int]$Code)
    if ($script:COMPONENT_TYPE_MAP.ContainsKey($Code)) { return $script:COMPONENT_TYPE_MAP[$Code] }
    return "Type($Code)"
}

#endregion

#region ── Azure CLI auth ────────────────────────────────────────────────────

function Assert-AzureCli {
    # Check if az is available
    if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
        throw "Azure CLI not found. Install from: https://aka.ms/installazurecliwindows"
    }

    # Check if the user is logged in
    $account = az account show --output json 2>$null | ConvertFrom-Json
    if (-not $account) {
        Write-Warning2 'Not logged in to Azure CLI. Starting az login...'
        az login --output none
        if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
    }

    Write-Ok "Logged in as: $($account.user.name)  (tenant: $($account.tenantId))"
}

function Get-AccessToken {
    <#
    .SYNOPSIS
        Retrieves an access token via Azure CLI for the specified resource URL.
        Works with Conditional Access policies because az login has already been performed on the device.
    #>
    param([string]$Resource)

    $result = az account get-access-token --resource $Resource --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az account get-access-token failed for resource '$Resource': $result"
    }
    return ($result | ConvertFrom-Json).accessToken
}

#endregion

#region ── REST helpers ───────────────────────────────────────────────────────

function New-ApiHeaders {
    param([string]$Token)
    return @{
        Authorization    = "Bearer $Token"
        Accept           = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }
}

function Invoke-DataverseGet {
    <#
    .SYNOPSIS
        Executes a GET request against the Dataverse Web API with automatic paging.
    #>
    param(
        [string]$BaseUrl,
        [hashtable]$Headers,
        [switch]$AllPages
    )
    $all  = [System.Collections.Generic.List[object]]::new()
    $url  = $BaseUrl
    do {
        $resp = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get -ErrorAction Stop
        if ($resp.PSObject.Properties['value'] -and $resp.value) { $all.AddRange([object[]]$resp.value) }
        $nextLink = $resp.PSObject.Properties['@odata.nextLink']
        $url = if ($AllPages -and $nextLink -and $nextLink.Value) { $nextLink.Value } else { $null }
    } while ($url)

    return $all
}

#endregion

#region ── Environment ────────────────────────────────────────────────────────

function Get-Environments {
    param([string]$Token)
    Write-Step 'Retrieving environments via Power Platform Admin API...'
    $headers = New-ApiHeaders -Token $Token
    $url = "$script:ADMIN_API_BASE/providers/Microsoft.BusinessAppPlatform/environments" +
           '?api-version=2016-11-01&$expand=properties'
    $raw = Invoke-DataverseGet -BaseUrl $url -Headers $headers

    $envs = $raw |
        Where-Object {
            # Safe property check: Set-StrictMode would otherwise throw on missing properties
            # (non-Dataverse environments such as Teams environments have no linkedEnvironmentMetadata)
            $meta = $_.properties.PSObject.Properties['linkedEnvironmentMetadata']
            $meta -and $meta.Value -and $meta.Value.PSObject.Properties['instanceUrl'] -and $meta.Value.instanceUrl
        } |
        ForEach-Object {
            [PSCustomObject]@{
                Id          = $_.name
                DisplayName = $_.properties.displayName
                OrgUrl      = $_.properties.linkedEnvironmentMetadata.instanceUrl.TrimEnd('/')
                Location    = $_.location
                Type        = $_.properties.environmentSku
            }
        } |
        Sort-Object DisplayName

    return $envs
}

function Select-Environment {
    param([object[]]$Envs)
    Write-Section 'Select an environment'
    for ($i = 0; $i -lt $Envs.Count; $i++) {
        $e = $Envs[$i]
        Write-Host ("  [{0,2}]  {1,-48} {2}" -f ($i + 1), $e.DisplayName, $e.Type) -ForegroundColor White
    }
    Write-Host ''
    $idx = Invoke-MenuChoice -Prompt "Environment (1-$($Envs.Count)): " -Min 1 -Max $Envs.Count
    return $Envs[$idx - 1]
}

#endregion

#region ── Solution ───────────────────────────────────────────────────────────

function Get-Solutions {
    param([string]$OrgUrl, [string]$Token)
    Write-Step 'Retrieving solutions...'
    $headers = New-ApiHeaders -Token $Token
    $url = "$OrgUrl/api/data/$script:DATAVERSE_VERSION/solutions" +
           '?$select=solutionid,uniquename,friendlyname,version' +
           '&$filter=ismanaged eq true and isvisible eq true' +
           '&$orderby=friendlyname asc'
    return Invoke-DataverseGet -BaseUrl $url -Headers $headers
}

function Select-Solution {
    param([object[]]$Solutions)
    Write-Section 'Select a solution'
    for ($i = 0; $i -lt $Solutions.Count; $i++) {
        $s = $Solutions[$i]
        Write-Host ("  [{0,2}]  {1,-50} v{2}" -f ($i + 1), $s.friendlyname, $s.version) -ForegroundColor White
    }
    Write-Host ''
    $idx = Invoke-MenuChoice -Prompt "Solution (1-$($Solutions.Count)): " -Min 1 -Max $Solutions.Count
    return $Solutions[$idx - 1]
}

#endregion

#region ── Layer detection ────────────────────────────────────────────────────

function Get-SolutionComponentIds {
    param([string]$OrgUrl, [string]$SolutionId, [string]$Token)
    Write-Step 'Retrieving solution components...'
    $headers = New-ApiHeaders -Token $Token
    $url = "$OrgUrl/api/data/$script:DATAVERSE_VERSION/solutioncomponents" +
           "?`$select=objectid,componenttype&`$filter=_solutionid_value eq $SolutionId"
    $components = Invoke-DataverseGet -BaseUrl $url -Headers $headers -AllPages
    Write-Ok "$($components.Count) component(s) in the solution."
    return $components
}

function Get-UnmanagedLayers {
    <#
    .SYNOPSIS
        Queries all layers per component (type + id, no solutionname filter).
        Filters client-side on 'Active' = unmanaged, stores managed layer as _baseJson for diff.
    #>
    param([string]$OrgUrl, [object[]]$Components, [string]$Token)

    if ($Components.Count -eq 0) { return @() }

    $headers = New-ApiHeaders -Token $Token
    $select  = 'msdyn_name,msdyn_componentid,msdyn_solutioncomponentname,msdyn_solutionname,' +
               'msdyn_order,msdyn_publishername,msdyn_changes,msdyn_componentjson'
    $results = [System.Collections.Generic.List[object]]::new()
    $total   = $Components.Count
    $done    = 0
    $errCnt  = 0

    foreach ($comp in $Components) {
        $done++
        $id       = $comp.objectid
        $typeName = Get-ComponentTypeName -Code ([int]$comp.componenttype)

        # type + id returns all layers (managed + unmanaged) without solutionname filter
        $filter = "msdyn_solutioncomponentname eq '$typeName' and msdyn_componentid eq '$id'"
        $url    = "$OrgUrl/api/data/$script:DATAVERSE_VERSION/msdyn_componentlayers" +
                  "?`$select=$select&`$filter=$filter"

        try {
            $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
            $val  = $resp.PSObject.Properties['value']
            if ($val -and $val.Value) {
                $allLayers     = @($val.Value)
                $unmanagedLayer = $allLayers | Where-Object { $_.msdyn_solutionname -eq 'Active' }
                # Managed layer with highest order = the direct base layer
                $baseLayer     = $allLayers |
                    Where-Object { $_.msdyn_solutionname -ne 'Active' } |
                    Sort-Object   msdyn_order |
                    Select-Object -Last 1

                foreach ($ul in $unmanagedLayer) {
                    $ul | Add-Member -NotePropertyName '_baseJson' `
                        -NotePropertyValue ($baseLayer.PSObject.Properties['msdyn_componentjson']?.Value) `
                        -Force
                    $ul | Add-Member -NotePropertyName '_baseSolution' `
                        -NotePropertyValue ($baseLayer.PSObject.Properties['msdyn_solutionname']?.Value) `
                        -Force
                    $results.Add($ul)
                }
            }
        }
        catch {
            $errCnt++
            if ($errCnt -le 3) {
                Write-Warning2 "Query error ($typeName): $($_.ErrorDetails.Message ?? $_.Exception.Message)"
            }
        }

        $pct = [Math]::Round(($done / $total) * 100)
        Write-Progress -Activity 'Detecting unmanaged layers...' `
            -Status "$done / $total  ($($results.Count) layers found)" `
            -PercentComplete $pct
    }
    Write-Progress -Activity 'Detecting unmanaged layers...' -Completed
    if ($errCnt -gt 0) { Write-Warning2 "$errCnt component(s) could not be retrieved." }
    return @($results)
}

#endregion

#region ── Output ─────────────────────────────────────────────────────────────

function Get-LayerAttributes {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @{} }
    try {
        $lookup = @{}
        ($Json | ConvertFrom-Json).Attributes | ForEach-Object { $lookup[$_.Key] = $_.Value }
        return $lookup
    }
    catch { return @{} }
}

function Get-ChangedAttributes {
    param([string]$ChangesJson)
    if ([string]::IsNullOrWhiteSpace($ChangesJson)) { return @() }
    try {
        $obj = $ChangesJson | ConvertFrom-Json
        return $obj.Attributes | ForEach-Object { [PSCustomObject]@{ Attribute = $_.Key; Value = $_.Value } }
    }
    catch { return @() }
}

function Show-Diff {
    param([object[]]$Layers)
    Write-Host ''
    foreach ($layer in ($Layers | Sort-Object msdyn_solutioncomponentname, msdyn_name)) {
        $changes  = Get-ChangedAttributes $layer.msdyn_changes
        if ($changes.Count -eq 0) { continue }

        $baseAttrs = Get-LayerAttributes ($layer.PSObject.Properties['_baseJson']?.Value)
        $baseSol   = $layer.PSObject.Properties['_baseSolution']?.Value
        if (-not $baseSol) { $baseSol = 'managed' }

        # Header
        $typeLabel = $layer.msdyn_solutioncomponentname
        $nameLabel = $layer.msdyn_name
        Write-Host "  diff  [$typeLabel]  $nameLabel" -ForegroundColor White
        Write-Host ("  " + ('=' * 60)) -ForegroundColor DarkGray
        Write-Host ("  --- $baseSol") -ForegroundColor Red
        Write-Host ("  +++ Unmanaged (Active)  publisher: $($layer.msdyn_publishername)") -ForegroundColor Green
        Write-Host ("  " + ('-' * 60)) -ForegroundColor DarkGray

        foreach ($change in $changes) {
$key     = $change.Attribute
        $newVal  = if ($null -ne $change.Value) { $change.Value } else { '(null)' }
        $oldVal  = if ($baseAttrs.ContainsKey($key)) {
                       if ($null -ne $baseAttrs[$key]) { $baseAttrs[$key] } else { '(null)' }
                   } else { '(unknown)' }

            $pad = [Math]::Max(60, $key.Length + 2)
            Write-Host ("  - {0,-45} {1}" -f $key, $oldVal) -ForegroundColor Red
            Write-Host ("  + {0,-45} {1}" -f $key, $newVal) -ForegroundColor Green
            Write-Host ''
        }
    }
}

function Show-Results {
    param([object[]]$Layers, [string]$SolutionDisplayName)
    Write-Section "Results -- $SolutionDisplayName"

    if ($Layers.Count -eq 0) {
        Write-Ok 'No unmanaged layers found. The solution is clean.'
        Write-Host ''
        return
    }

    Write-Host ("  Total found: {0} unmanaged layer(s)`n" -f $Layers.Count) -ForegroundColor Yellow

    $table = $Layers |
        Sort-Object msdyn_solutioncomponentname, msdyn_name |
        Select-Object `
            @{ N = 'Type';        E = { $_.msdyn_solutioncomponentname } },
            @{ N = 'Name';        E = { $_.msdyn_name } },
            @{ N = 'Publisher';   E = { $_.msdyn_publishername } },
            @{ N = 'LayerOrder';  E = { $_.msdyn_order } },
            @{ N = 'Changes'; E = { (Get-ChangedAttributes $_.msdyn_changes).Count } }

    $table | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }

    # Samenvatting per componenttype
    Write-Host '  Summary by type:' -ForegroundColor DarkCyan
    $Layers |
        Group-Object msdyn_solutioncomponentname |
        Sort-Object Count -Descending |
        ForEach-Object {
            Write-Host ("    {0,-38} {1,4} layer(s)" -f $_.Name, $_.Count) -ForegroundColor Gray
        }
    Write-Host ''

    # Diff
    Write-Host '  Show diff? ' -ForegroundColor White -NoNewline
    $showDiff = Read-Host '[Y/N]'
    if ($showDiff -match '^[YyJj]') { Show-Diff -Layers $Layers }
}

function Export-ToCsv {
    param([object[]]$Layers, [string]$SolutionUniqueName)
    if ($Layers.Count -eq 0) { return }

    Write-Host ''
    Write-Host '  Export to CSV? ' -ForegroundColor White -NoNewline
    $answer = Read-Host '[Y/N]'
    if ($answer -notmatch '^[YyJj1]') { return }

    $stamp   = Get-Date -Format 'yyyyMMdd-HHmm'
    $safeName = $SolutionUniqueName -replace '[^a-zA-Z0-9\-_]', '_'
    $default  = "unmanaged-layers_${safeName}_${stamp}.csv"

    Write-Host "  File name [$default]: " -NoNewline -ForegroundColor White
    $fileName = Read-Host
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = $default }

    $pad = Join-Path (Get-Location) $fileName
    $Layers |
        Select-Object `
            @{ N = 'ComponentType';       E = { $_.msdyn_solutioncomponentname } },
            @{ N = 'ComponentName';       E = { $_.msdyn_name } },
            @{ N = 'ComponentId';         E = { $_.msdyn_componentid } },
            @{ N = 'Publisher';           E = { $_.msdyn_publishername } },
            @{ N = 'LayerOrder';          E = { $_.msdyn_order } },
            @{ N = 'SolutionName';        E = { $_.msdyn_solutionname } },
            @{ N = 'ChangedAttributes';   E = {
                (Get-ChangedAttributes $_.msdyn_changes | ForEach-Object { "$($_.Attribute)=$($_.Value)" }) -join '; '
            }} |
        Export-Csv -Path $pad -NoTypeInformation -Encoding UTF8

    Write-Ok "Exported to: $pad"
}

function Remove-UnmanagedLayers {
    <#
    .SYNOPSIS
        Removes unmanaged layers via the Dataverse action RemoveActiveCustomization.
        Requires double confirmation and displays a clear warning.
    #>
    param([string]$OrgUrl, [object[]]$Layers, [string]$Token, [string]$SolutionDisplayName)

    if ($Layers.Count -eq 0) { return }

    Write-Host ''
    Write-Host '  +---------------------------------------------------------+' -ForegroundColor Yellow
    Write-Host '  |  WARNING: destructive action                            |' -ForegroundColor Yellow
    Write-Host '  |  This permanently removes the unmanaged layers.         |' -ForegroundColor Yellow
    Write-Host '  |  Do NOT run this in production without approval.        |' -ForegroundColor Yellow
    Write-Host '  +---------------------------------------------------------+' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  $($Layers.Count) layer(s) will be removed from solution: $SolutionDisplayName" -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  Remove all unmanaged layers? " -ForegroundColor White -NoNewline
    $check1 = Read-Host '[Y/N]'
    if ($check1 -notmatch '^[YyJj]') {
        Write-Ok 'Removal cancelled.'
        return
    }

    Write-Host ''
    Write-Host "  Confirm by typing the solution name exactly:" -ForegroundColor Red
    Write-Host "  > $SolutionDisplayName" -ForegroundColor White
    $confirmed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Host "  [$attempt/3]: " -ForegroundColor Red -NoNewline
        $check2 = Read-Host
        if ($check2 -eq $SolutionDisplayName) { $confirmed = $true; break }
        if ($attempt -lt 3) { Write-Warning2 "Name does not match, please try again." }
    }
    if (-not $confirmed) {
        Write-Ok 'Removal cancelled (solution name not entered correctly).'
        return
    }

    Write-Section 'Removing unmanaged layers'

    $postHeaders = @{
        Authorization      = "Bearer $Token"
        'Content-Type'     = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }
    $actionUrl = "$OrgUrl/api/data/$script:DATAVERSE_VERSION/RemoveActiveCustomization"

    $total   = $Layers.Count
    $done    = 0
    $success = 0
    $failed  = 0

    foreach ($layer in $Layers) {
        $done++
        $compName = $layer.msdyn_solutioncomponentname
        $compId   = $layer.msdyn_componentid
        $compDisp = $layer.msdyn_name

        $body = @{
            LogicalName = $compName.ToLower()
            Id          = $compId
        } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri $actionUrl -Headers $postHeaders -Method Post -Body $body -ErrorAction Stop
            $success++
        }
        catch {
            $failed++
            Write-Warning2 "Failed ($compName / $compDisp): $($_.ErrorDetails.Message ?? $_.Exception.Message)"
        }

        $pct = [Math]::Round(($done / $total) * 100)
        Write-Progress -Activity 'Removing layers...' `
            -Status "$done / $total  (OK: $success  Failed: $failed)" `
            -PercentComplete $pct
    }
    Write-Progress -Activity 'Removing layers...' -Completed

    Write-Host ''
    Write-Ok   "Removed:  $success layer(s)"
    if ($failed -gt 0) { Write-Warning2 "Failed:   $failed layer(s)  (see warnings above)" }

    if ($success -gt 0) {
        Write-Host ''
        Write-Host '  Publish the environment now? (recommended after removal)' -ForegroundColor White -NoNewline
        $pub = Read-Host ' [Y/N]'
        if ($pub -match '^[YyJj]') {
            Write-Step 'Publishing...'
            try {
                $pubPayload = @{ ParameterXml = '' } | ConvertTo-Json
                Invoke-RestMethod -Uri "$OrgUrl/api/data/$script:DATAVERSE_VERSION/PublishAllXml" `
                    -Headers $postHeaders -Method Post -Body $pubPayload -ErrorAction Stop
                Write-Ok 'Published.'
            }
            catch { Write-Warning2 "Publish failed: $($_.ErrorDetails.Message ?? $_.Exception.Message)" }
        }
    }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

function Invoke-Main {
    Write-Banner

    # ── Step 1: Azure CLI available and logged in
    Write-Step 'Checking Azure CLI...'
    Assert-AzureCli

    # ── Step 2: Token for Power Platform Admin API
    Write-Step 'Retrieving token for Power Platform Admin API...'
    $adminToken = Get-AccessToken -Resource $script:ADMIN_API_RESOURCE
    Write-Ok 'Token received.'

    # ── Step 3: Retrieve and select environment
    $envs = Get-Environments -Token $adminToken
    if ($envs.Count -eq 0) {
        Write-Warning2 'No environments found. Check your permissions in the Power Platform Admin portal.'
        return
    }
    Write-Ok "$($envs.Count) environment(s) found."

    $selectedEnv = Select-Environment -Envs $envs
    Write-Ok "Environment: $($selectedEnv.DisplayName)"
    Write-Host "             $($selectedEnv.OrgUrl)" -ForegroundColor DarkGray

    # ── Step 4: Dataverse token for selected environment
    Write-Step "Retrieving Dataverse token for $($selectedEnv.DisplayName)..."
    $dataverseToken = Get-AccessToken -Resource $selectedEnv.OrgUrl
    Write-Ok 'Dataverse token received.'

    # ── Step 5: Retrieve and select solution
    $solutions = Get-Solutions -OrgUrl $selectedEnv.OrgUrl -Token $dataverseToken
    if ($solutions.Count -eq 0) {
        Write-Warning2 'No managed solutions found in this environment.'
        return
    }
    Write-Ok "$($solutions.Count) solution(s) found."

    $selectedSol = Select-Solution -Solutions $solutions
    Write-Ok "Solution: $($selectedSol.friendlyname) (v$($selectedSol.version))"

    # ── Step 6: Retrieve components
    $components = Get-SolutionComponentIds `
        -OrgUrl     $selectedEnv.OrgUrl `
        -SolutionId $selectedSol.solutionid `
        -Token      $dataverseToken

    if ($components.Count -eq 0) {
        Write-Warning2 'Solution contains no components.'
        return
    }

    # ── Step 7: Detect unmanaged layers
    Write-Step "Detecting unmanaged layers for $($components.Count) component(s)..."
    $layers = @(Get-UnmanagedLayers -OrgUrl $selectedEnv.OrgUrl -Components $components -Token $dataverseToken)
    Write-Ok "$($layers.Count) unmanaged layer(s) detected."

    # ── Step 8: Display and export
    Show-Results  -Layers $layers -SolutionDisplayName $selectedSol.friendlyname
    Export-ToCsv  -Layers $layers -SolutionUniqueName  $selectedSol.uniquename

    # ── Step 9: Optional removal
    Remove-UnmanagedLayers -OrgUrl $selectedEnv.OrgUrl -Layers $layers -Token $dataverseToken -SolutionDisplayName $selectedSol.friendlyname
}

try {
    Invoke-Main
}
catch {
    Write-Host ''
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    }
    exit 1
}

#endregion
