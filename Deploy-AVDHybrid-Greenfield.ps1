#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Virtual Desktop (AVD) for Hybrid Environments - Greenfield Deployment

.DESCRIPTION
    Deploys all Azure infrastructure required for AVD Hybrid Environments (Public Preview).
    This script runs ONCE from your admin machine to set up:
      - Resource groups for AVD and Azure Arc
      - AVD host pool, workspace, and application group
      - Entra ID user group with correct RBAC assignments
      - Service principal for Arc onboarding
      - Host pool registration token
      - AVD-SessionHost-Config.txt output file for use with the Session Host script

    AVD Hybrid Environments allows on-premises or non-Azure VMs to act as AVD
    session hosts by connecting them to Azure via Azure Arc.

    Run section by section using F8 in PowerShell ISE or VS Code.
    Update the variables in Section 0 before running anything else.

.PARAMETER None
    All configuration is handled via variables in Section 0.

.EXAMPLE
    # Open in PowerShell ISE or VS Code, update Section 0 variables, then run F8 per section.

.NOTES
    Version:    1.0
    Author:     Dan Bowker
    Blog:       https://bowker.cloud
    GitHub:     https://github.com/bowkercloud
    
    Prerequisites:
      - Azure subscription with appropriate permissions
      - PowerShell 5.1 or later
      - Outbound internet access to Azure endpoints

    References:
      https://learn.microsoft.com/en-us/azure/virtual-desktop/deploy-azure-virtual-desktop-hybrid
      https://learn.microsoft.com/en-us/azure/azure-arc/servers/
      https://learn.microsoft.com/en-us/azure/virtual-desktop/azure-ad-joined-session-hosts

    NOTE: AVD Hybrid Environments is currently in Public Preview.
    Host pools must be configured as validation environments.
    Not recommended for production workloads until General Availability.
#>


# =============================================================================
# SECTION 0 - VARIABLES (edit these before running anything)
# =============================================================================

$TenantId        = "YOUR_TENANT_ID"          # <-- UPDATE THIS
$SubscriptionId  = "YOUR_SUBSCRIPTION_ID"    # <-- UPDATE THIS

# Resource group names
$AVD_RG          = "AVD-HostPool-RG"       # Holds the AVD host pool
$Arc_RG          = "AVD-ArcServers-RG"     # Holds the Arc-enabled session hosts

# Locations - public preview supports standard regions
$AVD_Location    = "uksouth"             # <-- UPDATE THIS
$Arc_Location    = "uksouth"             # <-- UPDATE THIS

# Host pool settings
$HostPoolName    = "AVD-HostPool"
$WorkspaceName   = "AVD-Workspace"
$AppGroupName    = "AVD-AppGroup"

# Your admin account UPN
$AdminAccount    = "YOUR_ADMIN_UPN"          # <-- UPDATE THIS e.g. admin@yourdomain.com

# Entra group for AVD users - will be created if it doesn't exist
# Members of this group will be able to access the AVD workspace and log into session hosts
$AVDUserGroupName = "AVD-Users"

# Where to save the session host config file (used by Script 2)
$OutputConfigPath = [Environment]::GetFolderPath("Desktop") + "\AVD-SessionHost-Config.txt"


# =============================================================================
# SECTION 1 - INSTALL REQUIRED MODULES
# Safe to skip if already installed.
# =============================================================================

# Ensure NuGet provider is available silently (avoids interactive prompt)
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge "2.8.5.201" })) {
    Write-Host "Installing NuGet provider..." -ForegroundColor Yellow
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Write-Host "NuGet provider installed." -ForegroundColor Green
} else {
    Write-Host "NuGet provider already installed." -ForegroundColor Green
}

$modules = @('Az.Accounts', 'Az.Resources', 'Az.DesktopVirtualization', 'Az.ConnectedMachine')
foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "Installing $m..." -ForegroundColor Yellow
        Install-Module $m -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
    } else {
        Write-Host "$m already installed." -ForegroundColor Green
    }
    Import-Module $m -ErrorAction Stop
}
Write-Host "All modules ready." -ForegroundColor Green


# =============================================================================
# SECTION 2 - AUTHENTICATE & SET SUBSCRIPTION
# A browser window will open for you to sign in.
# =============================================================================

Connect-AzAccount -TenantId $TenantId
Select-AzSubscription -SubscriptionId $SubscriptionId

# Confirm you're in the right context before proceeding
Get-AzContext | Select-Object Name, Account, Subscription


# =============================================================================
# SECTION 3 - REGISTER RESOURCE PROVIDERS
# Public preview no longer requires EUAP/canary region feature flags.
# Only the AVD and HybridCompute providers need registering.
# =============================================================================

Register-AzResourceProvider -ProviderNamespace "Microsoft.HybridCompute"
Register-AzResourceProvider -ProviderNamespace "Microsoft.DesktopVirtualization"

Write-Host "Waiting for providers to register (this can take a few minutes)..." -ForegroundColor Yellow

# -- VALIDATION: run this until both return "Registered" --
(Get-AzResourceProvider -ProviderNamespace "Microsoft.HybridCompute").RegistrationState
(Get-AzResourceProvider -ProviderNamespace "Microsoft.DesktopVirtualization").RegistrationState

Write-Host "Provider registration complete." -ForegroundColor Green


# =============================================================================
# SECTION 4 - CREATE RESOURCE GROUPS
# Skips creation if resource groups already exist.
# =============================================================================

if (Get-AzResourceGroup -Name $AVD_RG -ErrorAction SilentlyContinue) {
    Write-Host "Resource group $AVD_RG already exists. Skipping." -ForegroundColor Green
} else {
    New-AzResourceGroup -Name $AVD_RG -Location $AVD_Location
    Write-Host "Created AVD resource group: $AVD_RG in $AVD_Location" -ForegroundColor Green
}

if (Get-AzResourceGroup -Name $Arc_RG -ErrorAction SilentlyContinue) {
    Write-Host "Resource group $Arc_RG already exists. Skipping." -ForegroundColor Green
} else {
    New-AzResourceGroup -Name $Arc_RG -Location $Arc_Location
    Write-Host "Created Arc resource group: $Arc_RG in $Arc_Location" -ForegroundColor Green
}


# =============================================================================
# SECTION 5 - ASSIGN RBAC ROLES TO YOUR ACCOUNT
# Skips assignment if role already exists.
# =============================================================================

$avdRole = Get-AzRoleAssignment -SignInName $AdminAccount `
    -RoleDefinitionName "Desktop Virtualization Contributor" `
    -ResourceGroupName $AVD_RG -ErrorAction SilentlyContinue
if ($avdRole) {
    Write-Host "Desktop Virtualization Contributor already assigned. Skipping." -ForegroundColor Green
} else {
    New-AzRoleAssignment `
        -RoleDefinitionName "Desktop Virtualization Contributor" `
        -SignInName $AdminAccount `
        -ResourceGroupName $AVD_RG
    Write-Host "Desktop Virtualization Contributor assigned." -ForegroundColor Green
}

$arcRole = Get-AzRoleAssignment -SignInName $AdminAccount `
    -RoleDefinitionName "Azure Connected Machine Onboarding" `
    -ResourceGroupName $Arc_RG -ErrorAction SilentlyContinue
if ($arcRole) {
    Write-Host "Azure Connected Machine Onboarding already assigned. Skipping." -ForegroundColor Green
} else {
    New-AzRoleAssignment `
        -RoleDefinitionName "Azure Connected Machine Onboarding" `
        -SignInName $AdminAccount `
        -ResourceGroupName $Arc_RG
    Write-Host "Azure Connected Machine Onboarding assigned." -ForegroundColor Green
}

Write-Host "RBAC roles confirmed." -ForegroundColor Green


# =============================================================================
# SECTION 6 - CREATE AVD HOST POOL, WORKSPACE AND APP GROUP
#
# NOTE: Public preview requires the host pool to be set as a validation
#       environment. Do not use for production workloads until GA.
# =============================================================================

# The standard Az.DesktopVirtualization cmdlet uses an older API version that
# does not support managed identity assignment. We use Invoke-AzRestMethod with
# the 2024-04-08-preview API which supports the ManagedIdentity feature.

# -- Host Pool --
$existingHP = Get-AzWvdHostPool -Name $HostPoolName -ResourceGroupName $AVD_RG -ErrorAction SilentlyContinue
if ($existingHP) {
    Write-Host "Host pool $HostPoolName already exists. Skipping creation." -ForegroundColor Green
    $hostPoolApiPath = "/subscriptions/$SubscriptionId/resourceGroups/$AVD_RG/providers/Microsoft.DesktopVirtualization/hostPools/$($HostPoolName)?api-version=2024-04-08-preview"
    $hostPool = (Invoke-AzRestMethod -Method GET -Path $hostPoolApiPath).Content | ConvertFrom-Json
} else {
    $hostPoolBody = @{
        location   = $AVD_Location
        identity   = @{ type = "SystemAssigned" }
        properties = @{
            hostPoolType          = "Pooled"
            loadBalancerType      = "BreadthFirst"
            maxSessionLimit       = 10
            preferredAppGroupType = "Desktop"
            validationEnvironment = $true        # Required for AVD Hybrid public preview
        }
    } | ConvertTo-Json -Depth 5

    $hostPoolApiPath = "/subscriptions/$SubscriptionId/resourceGroups/$AVD_RG/providers/Microsoft.DesktopVirtualization/hostPools/$($HostPoolName)?api-version=2024-04-08-preview"
    $response = Invoke-AzRestMethod -Method PUT -Path $hostPoolApiPath -Payload $hostPoolBody

    if ($response.StatusCode -notin 200, 201) {
        Write-Host "Host pool creation failed: $($response.Content)" -ForegroundColor Red
        throw "Stopping - host pool was not created successfully."
    }

    $hostPool = ($response.Content | ConvertFrom-Json)
    Write-Host "Host pool created: $HostPoolName" -ForegroundColor Green
}

# -- Workspace --
$existingWS = Get-AzWvdWorkspace -Name $WorkspaceName -ResourceGroupName $AVD_RG -ErrorAction SilentlyContinue
if ($existingWS) {
    Write-Host "Workspace $WorkspaceName already exists. Skipping." -ForegroundColor Green
    $workspace = $existingWS
} else {
    $workspace = New-AzWvdWorkspace `
        -ResourceGroupName $AVD_RG `
        -Name              $WorkspaceName `
        -Location          $AVD_Location
    Write-Host "Workspace created: $WorkspaceName (Id: $($workspace.Id))" -ForegroundColor Green
}

# -- Application Group --
$existingAG = Get-AzWvdApplicationGroup -Name $AppGroupName -ResourceGroupName $AVD_RG -ErrorAction SilentlyContinue
if ($existingAG) {
    Write-Host "Application group $AppGroupName already exists. Skipping." -ForegroundColor Green
    $appGroup = $existingAG
} else {
    $appGroup = New-AzWvdApplicationGroup `
        -ResourceGroupName    $AVD_RG `
        -Name                 $AppGroupName `
        -Location             $AVD_Location `
        -ApplicationGroupType "Desktop" `
        -HostPoolArmPath      $hostPool.id

    Update-AzWvdWorkspace `
        -ResourceGroupName         $AVD_RG `
        -Name                      $workspace.Name `
        -ApplicationGroupReference $appGroup.Id

    Write-Host "Application group created and linked to workspace." -ForegroundColor Green
}


# =============================================================================
# SECTION 7 - GRANT HOST POOL MANAGED IDENTITY READER ACCESS ON ARC RG
# The host pool identity needs Reader on the Arc RG to see session host status.
# =============================================================================

$HP_PRINCIPAL_ID = (Get-AzWvdHostPool -Name $HostPoolName -ResourceGroupName $AVD_RG).IdentityPrincipalId
if (-not $HP_PRINCIPAL_ID) {
    $HP_PRINCIPAL_ID = $hostPool.identity.principalId
}

$readerRole = Get-AzRoleAssignment -ObjectId $HP_PRINCIPAL_ID `
    -RoleDefinitionName "Reader" `
    -ResourceGroupName $Arc_RG -ErrorAction SilentlyContinue
if ($readerRole) {
    Write-Host "Reader role already assigned to host pool managed identity. Skipping." -ForegroundColor Green
} else {
    New-AzRoleAssignment `
        -ObjectId           $HP_PRINCIPAL_ID `
        -RoleDefinitionName "Reader" `
        -ResourceGroupName  $Arc_RG
    Write-Host "Reader role assigned to host pool managed identity on Arc RG." -ForegroundColor Green
}


# =============================================================================
# SECTION 8 - CREATE SERVICE PRINCIPAL FOR ARC ONBOARDING
# Creates a service principal and saves all session host config to a file
# on your Desktop. Copy that file to each VM before running Script 2.
# =============================================================================

# Always create a fresh SP secret to avoid stale credential issues.
# If an SP with this name already exists, a new credential is added and the config file updated.
$SPName     = "AVD-ArcOnboarding-SP"
$existingSP = Get-AzADServicePrincipal -DisplayName $SPName -ErrorAction SilentlyContinue | Select-Object -First 1

if ($existingSP) {
    Write-Host "Service principal $SPName already exists. Generating fresh secret..." -ForegroundColor Yellow
    # Remove all existing credentials and add a fresh one to avoid confusion
    Get-AzADSpCredential -ObjectId $existingSP.Id -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-AzADSpCredential -ObjectId $existingSP.Id -KeyId $_.KeyId -ErrorAction SilentlyContinue
    }
    $newCred  = New-AzADSpCredential -ObjectId $existingSP.Id
    $SPAppId  = $existingSP.AppId
    $SPSecret = $newCred.SecretText
    Write-Host "Fresh secret generated for existing SP." -ForegroundColor Green
} else {
    $SP       = New-AzADServicePrincipal -DisplayName $SPName
    $SPAppId  = $SP.AppId
    $SPSecret = $SP.PasswordCredentials.SecretText
    Write-Host "Service principal created: $SPName" -ForegroundColor Green
}

# Wait for SP to propagate in Entra before assigning roles
# Without this, role assignment can return BadRequest as the SP isn't visible yet
Write-Host "Waiting 15 seconds for service principal to propagate in Entra..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

$spRole = Get-AzRoleAssignment -ApplicationId $SPAppId `
    -RoleDefinitionName "Azure Connected Machine Onboarding" `
    -ResourceGroupName $Arc_RG -ErrorAction SilentlyContinue
if ($spRole) {
    Write-Host "Arc Onboarding role already assigned to SP. Skipping." -ForegroundColor Green
} else {
    New-AzRoleAssignment `
        -ApplicationId      $SPAppId `
        -RoleDefinitionName "Azure Connected Machine Onboarding" `
        -ResourceGroupName  $Arc_RG
    Write-Host "Arc Onboarding role assigned to SP." -ForegroundColor Green
}
Write-Host "SP ready. AppId: $SPAppId" -ForegroundColor Green

# Generate a registration token valid for 24 hours
$expiresUtc = (Get-Date).ToUniversalTime().AddHours(24).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
$regInfo    = New-AzWvdRegistrationInfo `
                  -ResourceGroupName $AVD_RG `
                  -HostPoolName      $HostPoolName `
                  -ExpirationTime    $expiresUtc
$token = $regInfo.Token

# Save all config needed by Script 2 to a file on your Desktop
$configContent = @"
# =====================================================================
# AVD Hybrid - Session Host Configuration
# Generated: $(Get-Date)
# Copy these values into Section 0 of Deploy-AVDHybrid-SessionHost.ps1
# =====================================================================

TenantId         = $TenantId
SubscriptionId   = $SubscriptionId
Arc_RG           = $Arc_RG
Arc_Location     = $Arc_Location
AVD_RG           = $AVD_RG
HostPoolName     = $HostPoolName
SPAppId          = $SPAppId
SPSecret         = $SPSecret
RegistrationToken = $token
TokenExpiry      = $(((Get-Date).AddHours(24)).ToString("yyyy-MM-dd HH:mm:ss")) UTC

# NOTE: Registration token expires in 24 hours.
# If it expires before you run Script 2, re-run Section 8 of the Greenfield
# script to generate a new token and update this file.
"@

$configContent | Out-File -FilePath $OutputConfigPath -Encoding UTF8
Write-Host "`nSession host config saved to: $OutputConfigPath" -ForegroundColor Green
Write-Host "Copy this file to each session host VM before running Script 2." -ForegroundColor Yellow
Write-Host "`nSP AppId:  $SPAppId" -ForegroundColor Yellow
Write-Host "SP Secret: $SPSecret" -ForegroundColor Yellow


# =============================================================================
# SECTION 9 - CREATE AVD USERS GROUP AND ASSIGN ACCESS
# Creates an Entra group for AVD users, assigns it to the app group,
# and grants the Virtual Machine User Login role on the Arc RG so members
# can log into Entra-joined session hosts.
# =============================================================================

# -- Create or retrieve the Entra group --
$avdGroup = Get-AzADGroup -DisplayName $AVDUserGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($avdGroup) {
    Write-Host "Entra group $AVDUserGroupName already exists. Skipping creation." -ForegroundColor Green
} else {
    $avdGroup = New-AzADGroup -DisplayName $AVDUserGroupName -MailNickname ($AVDUserGroupName -replace "\s","")
    Write-Host "Entra group created: $AVDUserGroupName" -ForegroundColor Green
}

# Wait for group to propagate in Entra before assigning roles
# Without this, role assignment can return BadRequest as the group isn't visible yet
Write-Host "Waiting 15 seconds for Entra group to propagate..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# -- Assign the group to the AVD application group --
$existingAppGroupRole = Get-AzRoleAssignment `
    -ObjectId           $avdGroup.Id `
    -RoleDefinitionName "Desktop Virtualization User" `
    -ResourceGroupName  $AVD_RG -ErrorAction SilentlyContinue
if ($existingAppGroupRole) {
    Write-Host "Desktop Virtualization User already assigned to $AVDUserGroupName. Skipping." -ForegroundColor Green
} else {
    New-AzRoleAssignment `
        -ObjectId           $avdGroup.Id `
        -RoleDefinitionName "Desktop Virtualization User" `
        -ResourceGroupName  $AVD_RG
    Write-Host "Desktop Virtualization User role assigned to $AVDUserGroupName." -ForegroundColor Green
}

# -- Grant VM User Login role on Arc RG so group members can log into session hosts --
$existingVMRole = Get-AzRoleAssignment `
    -ObjectId           $avdGroup.Id `
    -RoleDefinitionName "Virtual Machine User Login" `
    -ResourceGroupName  $Arc_RG -ErrorAction SilentlyContinue
if ($existingVMRole) {
    Write-Host "Virtual Machine User Login already assigned to $AVDUserGroupName. Skipping." -ForegroundColor Green
} else {
    New-AzRoleAssignment `
        -ObjectId           $avdGroup.Id `
        -RoleDefinitionName "Virtual Machine User Login" `
        -ResourceGroupName  $Arc_RG
    Write-Host "Virtual Machine User Login role assigned to $AVDUserGroupName on Arc RG." -ForegroundColor Green
}

Write-Host "`nTo add users: go to Entra ID > Groups > $AVDUserGroupName > Members > Add." -ForegroundColor Cyan


# =============================================================================
# SECTION 10 - SET HOST POOL RDP PROPERTIES FOR ENTRA-JOINED HOSTS
# Adds targetisaadjoined:i:1 so users can connect from non-Entra-joined devices.
# =============================================================================

$rdpPatchBody = @{
    properties = @{
        customRdpProperty = "targetisaadjoined:i:1;"
    }
} | ConvertTo-Json -Depth 5

$hostPoolApiPath = "/subscriptions/$SubscriptionId/resourceGroups/$AVD_RG/providers/Microsoft.DesktopVirtualization/hostPools/$($HostPoolName)?api-version=2024-04-08-preview"
$rdpResult = Invoke-AzRestMethod -Method PATCH -Path $hostPoolApiPath -Payload $rdpPatchBody

if ($rdpResult.StatusCode -in 200, 201) {
    Write-Host "Host pool RDP property set: targetisaadjoined:i:1" -ForegroundColor Green
} else {
    Write-Host "Failed to set RDP property: $($rdpResult.Content)" -ForegroundColor Red
}

Write-Host "`nGreenfield deployment complete. Run Deploy-AVDHybrid-SessionHost.ps1 on each VM." -ForegroundColor Green
