Function Unprotect-WindowsSecurity {
    [CmdletBinding(
        SupportsShouldProcess = $true,
        ConfirmImpact = 'High'
    )]
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.SwitchParameter]$OnlyProcessMitigations,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.SwitchParameter]$Force
    )

    begin {
        # Import functions
        . "$HardeningModulePath\Resources\Functions.ps1"

        # Defining default parameters for cmdlets
        $PSDefaultParameterValues = @{
            'Invoke-WebRequest:HttpVersion' = '3.0'
            'Invoke-WebRequest:SslProtocol' = 'Tls12,Tls13'
        }

        # Fetching Temp Directory
        [System.String]$CurrentUserTempDirectoryPath = [System.IO.Path]::GetTempPath()

        # Makes sure this cmdlet is invoked with Admin privileges
        if (-NOT (Test-IsAdmin)) {
            Throw [System.Security.AccessControl.PrivilegeNotHeldException] 'Administrator'
        }

        # The total number of the steps for the parent/main progress bar to render
        [System.Int16]$TotalMainSteps = 7
        [System.Int16]$CurrentMainStep = 0

        # do not prompt for confirmation if the -Force switch is used
        # if both -Force and -Confirm switches are used, the prompt for confirmation will still be correctly shown
        if ($Force -and -Not $Confirm) {
            $ConfirmPreference = 'None'
        }
    }

    process {
        # Prompt for confirmation before proceeding
        if ($PSCmdlet.ShouldProcess('This PC', 'Removing the Hardening Measures Applied by the Protect-WindowsSecurity Cmdlet')) {

            # doing a try-finally block on the entire script so that when CTRL + C is pressed to forcefully exit the script,
            # or break is passed, clean up will still happen for secure exit
            try {

                $CurrentMainStep++
                Write-Progress -Id 0 -Activity 'Backing up Controlled Folder Access exclusion list' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

                # backup the current allowed apps list in Controlled folder access in order to restore them at the end of the script
                # doing this so that when we Add and then Remove PowerShell executables in Controlled folder access exclusions
                # no user customization will be affected
                [System.String[]]$CFAAllowedAppsBackup = (Get-MpPreference).ControlledFolderAccessAllowedApplications

                # Temporarily allow the currently running PowerShell executables to the Controlled Folder Access allowed apps
                # so that the script can run without interruption. This change is reverted at the end.
                foreach ($FilePath in (Get-ChildItem -Path "$PSHOME\*.exe" -File).FullName) {
                    Add-MpPreference -ControlledFolderAccessAllowedApplications $FilePath
                }

                Start-Sleep -Seconds 3

                # create our working directory
                Write-Verbose -Message "Creating a working directory at $CurrentUserTempDirectoryPath\HardeningXStuff\"
                New-Item -ItemType Directory -Path "$CurrentUserTempDirectoryPath\HardeningXStuff\" -Force | Out-Null

                # working directory assignment
                [System.IO.DirectoryInfo]$WorkingDir = "$CurrentUserTempDirectoryPath\HardeningXStuff\"

                # change location to the new directory
                Write-Verbose -Message "Changing location to $WorkingDir"
                Set-Location -Path $WorkingDir

                $CurrentMainStep++
                Write-Progress -Id 0 -Activity 'Downloading the required files' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

                try {
                    # Download Registry CSV file from GitHub or Azure DevOps
                    try {
                        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/HotCakeX/Harden-Windows-Security/main/Payload/Registry.csv' -OutFile '.\Registry.csv' -ProgressAction SilentlyContinue
                    }
                    catch {
                        Write-Host -Object 'Using Azure DevOps...' -ForegroundColor Yellow
                        Invoke-WebRequest -Uri 'https://dev.azure.com/SpyNetGirl/011c178a-7b92-462b-bd23-2c014528a67e/_apis/git/repositories/5304fef0-07c0-4821-a613-79c01fb75657/items?path=/Payload/Registry.csv' -OutFile '.\Registry.csv' -ProgressAction SilentlyContinue
                    }

                    # Download Process Mitigations CSV file from GitHub or Azure DevOps
                    try {
                        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/HotCakeX/Harden-Windows-Security/main/Payload/ProcessMitigations.csv' -OutFile '.\ProcessMitigations.csv' -ProgressAction SilentlyContinue
                    }
                    catch {
                        Write-Host -Object 'Using Azure DevOps...' -ForegroundColor Yellow
                        Invoke-WebRequest -Uri 'https://dev.azure.com/SpyNetGirl/011c178a-7b92-462b-bd23-2c014528a67e/_apis/git/repositories/5304fef0-07c0-4821-a613-79c01fb75657/items?path=/Payload/ProcessMitigations.csv' -OutFile '.\ProcessMitigations.csv' -ProgressAction SilentlyContinue
                    }
                }
                catch {
                    Throw 'The required files could not be downloaded, Make sure you have Internet connection.'
                }

                # Disable Mandatory ASLR
                Set-ProcessMitigation -System -Disable ForceRelocateImages

                #region Remove-Process-Mitigations
                [System.Object[]]$ProcessMitigations = Import-Csv -Path '.\ProcessMitigations.csv' -Delimiter ','
                # Group the data by ProgramName
                [System.Object[]]$GroupedMitigations = $ProcessMitigations | Group-Object -Property ProgramName
                [System.Object[]]$AllAvailableMitigations = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\*')

                $CurrentMainStep++
                Write-Progress -Id 0 -Activity 'Removing Process Mitigations for apps' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

                # Loop through each group
                foreach ($Group in $GroupedMitigations) {
                    # To separate the filename from full path of the item in the CSV and then check whether it exists in the system registry
                    if ($Group.Name -match '\\([^\\]+)$') {
                        if ($Matches[1] -in $AllAvailableMitigations.pschildname) {
                            Remove-Item -Path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$($Matches[1])" -Recurse -Force
                        }
                    }
                    elseif ($Group.Name -in $AllAvailableMitigations.pschildname) {
                        Remove-Item -Path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$($Group.Name)" -Recurse -Force
                    }
                }
                #endregion Remove-Process-Mitigations

                # Skip these if the user only wants to remove the Process Mitigations
                if (!$OnlyProcessMitigations) {

                    $CurrentMainStep++
                    Write-Progress -Id 0 -Activity 'Deleting all group policies' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

                    if (Test-Path -Path "$env:SystemDrive\Windows\System32\GroupPolicy") {
                        Remove-Item -Path "$env:SystemDrive\Windows\System32\GroupPolicy" -Recurse -Force
                    }

                    $CurrentMainStep++
                    Write-Progress -Id 0 -Activity 'Deleting all the registry keys created by the Protect-WindowsSecurity cmdlet' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

                    [System.Object[]]$Items = Import-Csv -Path '.\Registry.csv' -Delimiter ','
                    foreach ($Item in $Items) {
                        if (Test-Path -Path $item.path) {
                            Remove-ItemProperty -Path $Item.path -Name $Item.key -Force -ErrorAction SilentlyContinue
                        }
                    }

                    # To completely remove the Edge policy since only its sub-keys are removed by the command above
                    Remove-Item -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge\TLSCipherSuiteDenyList' -Force -Recurse -ErrorAction SilentlyContinue

                    # Restore Security group policies back to their default states

                    $CurrentMainStep++
                    Write-Progress -Id 0 -Activity 'Restoring the default Security group policies' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

                    # Download LGPO program from Microsoft servers
                    Invoke-WebRequest -Uri 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip' -OutFile '.\LGPO.zip' -ProgressAction SilentlyContinue

                    # unzip the LGPO file
                    Expand-Archive -Path .\LGPO.zip -DestinationPath .\ -Force
                    .\'LGPO_30\LGPO.exe' /q /s "$HardeningModulePath\Resources\Default Security Policy.inf"

                    # Enable LMHOSTS lookup protocol on all network adapters again
                    Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NetBT\Parameters' -Name 'EnableLMHOSTS' -Value '1' -Type DWord

                    # Disable restart notification for Windows update
                    Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'RestartNotificationsAllowed2' -Value '0' -Type DWord

                    # Re-enables the XblGameSave Standby Task that gets disabled by Microsoft Security Baselines
                    SCHTASKS.EXE /Change /TN \Microsoft\XblGameSave\XblGameSaveTask /Enable | Out-Null

                    $CurrentMainStep++
                    Write-Progress -Id 0 -Activity 'Restoring Microsoft Defender configs back to their default states' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

                    # Disable the advanced new security features of the Microsoft Defender
                    Set-MpPreference -AllowSwitchToAsyncInspection $False
                    Set-MpPreference -OobeEnableRtpAndSigUpdate $False
                    Set-MpPreference -IntelTDTEnabled $False
                    Set-MpPreference -DisableRestorePoint $True
                    Set-MpPreference -PerformanceModeStatus Enabled
                    Set-MpPreference -EnableConvertWarnToBlock $False
                    # Set Microsoft Defender engine and platform update channels to NotConfigured State
                    Set-MpPreference -EngineUpdatesChannel NotConfigured
                    Set-MpPreference -PlatformUpdatesChannel NotConfigured

                    # Set Data Execution Prevention (DEP) back to its default value
                    Set-BcdElement -Element 'nx' -Type 'Integer' -Value '0'

                    # Remove the scheduled task that keeps the Microsoft recommended driver block rules updated

                    # Define the name and path of the task
                    [System.String]$taskName = 'MSFT Driver Block list update'
                    [System.String]$taskPath = '\MSFT Driver Block list update\'

                    Write-Verbose -Message "Removing the scheduled task $taskName"
                    if (Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue) {
                        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false | Out-Null
                    }

                    # Enables Multicast DNS (mDNS) UDP-in Firewall Rules for all 3 Firewall profiles
                    Get-NetFirewallRule |
                    Where-Object -FilterScript { $_.RuleGroup -eq '@%SystemRoot%\system32\firewallapi.dll,-37302' -and $_.Direction -eq 'inbound' } |
                    ForEach-Object -Process { Enable-NetFirewallRule -DisplayName $_.DisplayName }

                    # Remove any custom views added by this script for Event Viewer
                    if (Test-Path -Path "$env:SystemDrive\ProgramData\Microsoft\Event Viewer\Views\Hardening Script") {
                        Remove-Item -Path "$env:SystemDrive\ProgramData\Microsoft\Event Viewer\Views\Hardening Script" -Recurse -Force
                    }

                    # Set a tattooed Group policy for Svchost.exe process mitigations back to disabled state
                    Set-ItemProperty -Path 'Registry::\HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SCMConfig' -Name 'EnableSvchostMitigationPolicy' -Value '0' -Force -Type 'DWord' -ErrorAction SilentlyContinue
                }

                # Write in Fuchsia color
                Write-Host -Object "$($PSStyle.Foreground.FromRGB(236,68,155))Operation Completed, please restart your computer.$($PSStyle.Reset)"
            }
            finally {
                # End the progress bar and mark it as completed
                Write-Progress -Id 0 -Activity 'Completed' -Completed

                # Reverting the PowerShell executables allow listings in Controlled folder access
                foreach ($FilePath in (Get-ChildItem -Path "$PSHOME\*.exe" -File).FullName) {
                    Remove-MpPreference -ControlledFolderAccessAllowedApplications $FilePath
                }

                # restoring the original Controlled folder access allow list - if user already had added PowerShell executables to the list
                # they will be restored as well, so user customization will remain intact
                if ($null -ne $CFAAllowedAppsBackup) {
                    Set-MpPreference -ControlledFolderAccessAllowedApplications $CFAAllowedAppsBackup
                }

                # Remove the working directory
                Set-Location -Path $HOME; Remove-Item -Recurse -Path "$CurrentUserTempDirectoryPath\HardeningXStuff\" -Force -ErrorAction SilentlyContinue
            }
        }
    }

    <#
.SYNOPSIS
    Removes the hardening measures applied by Protect-WindowsSecurity cmdlet
.LINK
    https://github.com/HotCakeX/Harden-Windows-Security/wiki/Harden%E2%80%90Windows%E2%80%90Security%E2%80%90Module
.DESCRIPTION
    Removes the hardening measures applied by Protect-WindowsSecurity cmdlet
.COMPONENT
    PowerShell
.FUNCTIONALITY
    Removes the hardening measures applied by Protect-WindowsSecurity cmdlet
.PARAMETER OnlyProcessMitigations
    Only removes the Process Mitigations / Exploit Protection settings and doesn't change anything else
.PARAMETER Force
    Suppresses the confirmation prompt
.EXAMPLE
    Unprotect-WindowsSecurity

    Removes all of the security features applied by the Protect-WindowsSecurity cmdlet
.EXAMPLE
    Unprotect-WindowsSecurity -OnlyProcessMitigations

    Removes only the Process Mitigations / Exploit Protection settings and doesn't change anything else
.EXAMPLE
    Unprotect-WindowsSecurity -Force

    Removes all of the security features applied by the Protect-WindowsSecurity cmdlet without prompting for confirmation
.INPUTS
    System.Management.Automation.SwitchParameter
.OUTPUTS
    System.String
#>
}