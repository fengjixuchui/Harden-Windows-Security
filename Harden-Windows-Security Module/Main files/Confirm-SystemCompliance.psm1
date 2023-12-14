function Confirm-SystemCompliance {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $false)]
        [System.Management.Automation.SwitchParameter]$ExportToCSV,
        [parameter(Mandatory = $false)]
        [System.Management.Automation.SwitchParameter]$ShowAsObjectsOnly,
        [parameter(Mandatory = $false)]
        [System.Management.Automation.SwitchParameter]$DetailedDisplay
    )
    begin {
        # Stop operation as soon as there is an error anywhere, unless explicitly specified otherwise
        $ErrorActionPreference = 'Stop'

        # Set the progress bar style to blinking yellow
        $PSStyle.Progress.Style = "$($PSStyle.Foreground.FromRGB(255,255,49))$($PSStyle.Blink)"

        # Dot-sourcing the functions.ps1 file in the current scope
        . "$psscriptroot\Functions.ps1"

        # Makes sure this cmdlet is invoked with Admin privileges
        if (-NOT (Test-IsAdmin)) {
            Throw [System.Security.AccessControl.PrivilegeNotHeldException] 'Administrator'
        }

        #Region Defining-Variables
        # Total number of Compliant values not equal to N/A
        [System.Int64]$TotalNumberOfTrueCompliantValues = 231

        # Get the current configurations and preferences of the Microsoft Defender
        New-Variable -Name 'MDAVConfigCurrent' -Value (Get-MpComputerStatus) -Force
        New-Variable -Name 'MDAVPreferencesCurrent' -Value (Get-MpPreference) -Force

        # An object to hold all the initial registry items
        [System.Object[]]$AllRegistryItems = @()

        # Import the CSV file
        [System.Object[]]$CSVResource = Import-Csv -Path "$psscriptroot\Resources\Registry resources.csv"

        # An object to store the FINAL results
        $FinalMegaObject = [PSCustomObject]@{}

        # The total number of the steps for the parent/main progress bar to render
        [System.Int16]$TotalMainSteps = 17
        [System.Int16]$CurrentMainStep = 0
        #EndRegion Defining-Variables

        #Region defining-Functions
        function ConvertFrom-IniFile {
            <#
            .SYNOPSIS
                A helper function to parse the ini file from the output of the "Secedit /export /cfg .\security_policy.inf"
            .PARAMETER IniFile
                The path to the ini file
            .INPUTS
                System.String
            .OUTPUTS
                PSCustomObject
            #>
            [CmdletBinding()]
            Param ([System.String]$IniFile)

            # Don't prompt to continue if '-Debug' is specified.
            $DebugPreference = 'Continue'

            [System.Collections.Hashtable]$IniObject = @{}
            [System.String]$SectionName = ''

            switch -regex -file $IniFile {
                '^\[(.+)\]$' {
                    # Header of the section
                    $SectionName = $matches[1]
                    #Write-Debug "Section: $SectionName"
                    $IniObject[$SectionName] = @{}
                    continue
                }
                '^(.+?)\s*=\s*(.*)$' {
                    # Name/value pair
                    [System.String]$KeyName, [System.String]$KeyValue = $matches[1..2]
                    #Write-Debug "Name: $KeyName"
                    # Write-Debug "Value: $KeyValue"
                    $IniObject[$SectionName][$KeyName] = $KeyValue
                    continue
                }
                default {
                    # Ignore blank lines or comments
                    continue
                }
            }
            return [PSCustomObject]$IniObject
        }
        function Invoke-CategoryProcessing {
            <#
            .SYNOPSIS
                A helper function for processing each item in $AllRegistryItems for each category
            .PARAMETER CatName
                Name of the hardening category to verify
            .PARAMETER Method
                The method used to verify the hardening category, which can be 'Group Policy' or 'Registry Keys'
            .INPUTS
                System.String
            .OUTPUTS
                System.Object[]
            #>
            param(
                [CmdletBinding()]

                [parameter(Mandatory = $true)]
                [ValidateNotNullOrEmpty()]
                [System.String]$CatName,

                [parameter(Mandatory = $true)]
                [ValidateSet('Group Policy', 'Registry Keys')]
                [ValidateNotNullOrEmpty()]
                [System.String]$Method
            )

            # an array to hold the output
            [System.Object[]]$Output = @()

            foreach ($Item in $AllRegistryItems | Where-Object -FilterScript { $_.category -eq $CatName } | Where-Object -FilterScript { $_.Method -eq $Method }) {

                # Initialize a flag to indicate if the key exists
                [System.Boolean]$keyExists = $false

                # Initialize a flag to indicate if the value exists and matches the type
                [System.Boolean]$ValueMatches = $false

                # Try to get the registry key
                try {
                    $regKey = Get-Item -Path $Item.regPath
                    # If no error is thrown, the key exists
                    $keyExists = $true

                    # Try to get the registry value and type
                    try {
                        $RegValue = Get-ItemPropertyValue -Path $Item.regPath -Name $Item.name
                        # If no error is thrown, the value exists

                        # Check if the value matches the expected one
                        if ($RegValue -eq $Item.value) {
                            # If it matches, set the flag to true
                            $ValueMatches = $true
                        }
                    }
                    catch {
                        # If an error is thrown, the value does not exist or is not accessible
                        # Do nothing, the flag remains false
                    }
                }
                catch {
                    # If an error is thrown, the key does not exist or is not accessible
                    # Do nothing, the flag remains false
                }

                # Create a custom object with the results for this row
                $Output += [PSCustomObject]@{
                    # Category     = $Item.category
                    # Key          = $Item.key
                    # Name         = $Item.name
                    # KeyExists    = $keyExists
                    # ValueMatches = $ValueMatches
                    # Type         = $Item.type
                    # Value        = $Item.value

                    FriendlyName = $Item.FriendlyName
                    Compliant    = $ValueMatches
                    Value        = $Item.value
                    Name         = $Item.name
                    Category     = $CatName
                    Method       = $Method
                }
            }
            return $Output
        }
        #EndRegion defining-Functions
    }

    process {

        try {
            # A global try-finally block to revert the changes made being made to the Controlled Folder Access exclusions list
            # Which is currently required for BCD NX value verification

            # backup the current allowed apps list in Controlled folder access in order to restore them at the end of the script
            # doing this so that when we Add and then Remove PowerShell executables in Controlled folder access exclusions
            # no user customization will be affected

            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Backing up Controlled Folder Access exclusion list' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.String[]]$CFAAllowedAppsBackup = (Get-MpPreference).ControlledFolderAccessAllowedApplications

            # Temporarily allow the currently running PowerShell executables to the Controlled Folder Access allowed apps
            # so that the script can run without interruption. This change is reverted at the end.
            foreach ($FilePath in (Get-ChildItem -Path "$PSHOME\*.exe" -File).FullName) {
                Add-MpPreference -ControlledFolderAccessAllowedApplications $FilePath
            }

            # Give the Defender internals time to process the updated exclusions list
            Start-Sleep -Seconds '5'

            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Gathering Security Policy Information' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            # Get the security group policies
            &'C:\Windows\System32\Secedit.exe' /export /cfg .\security_policy.inf | Out-Null

            # Storing the output of the ini file parsing function
            [PSCustomObject]$SecurityPoliciesIni = ConvertFrom-IniFile -IniFile .\security_policy.inf

            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Processing the registry CSV file' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            # Loop through each row in the CSV file and add it to the $AllRegistryItems array as a custom object
            foreach ($Row in $CSVResource) {
                $AllRegistryItems += [PSCustomObject]@{
                    FriendlyName = $Row.FriendlyName
                    category     = $Row.Category
                    key          = $Row.Key
                    value        = $Row.Value
                    name         = $Row.Name
                    type         = $Row.Type
                    regPath      = "Registry::$($Row.Key)" # Build the registry path
                    Method       = $Row.Origin
                }
            }

            #Region Microsoft-Defender-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Microsoft Defender Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            # An array to store the nested custom objects, inside the main output object
            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Microsoft Defender'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # For PowerShell Cmdlet
            $IndividualItemResult = $MDAVPreferencesCurrent.AllowSwitchToAsyncInspection
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'AllowSwitchToAsyncInspection'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'AllowSwitchToAsyncInspection'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            $IndividualItemResult = $MDAVPreferencesCurrent.oobeEnableRtpAndSigUpdate
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'oobeEnableRtpAndSigUpdate'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'oobeEnableRtpAndSigUpdate'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            $IndividualItemResult = $MDAVPreferencesCurrent.IntelTDTEnabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'IntelTDTEnabled'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'IntelTDTEnabled'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            $IndividualItemResult = $((Get-ProcessMitigation -System).aslr.ForceRelocateImages)
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Mandatory ASLR'
                Compliant    = $IndividualItemResult -eq 'on' ? $True : $false
                Value        = $IndividualItemResult
                Name         = 'Mandatory ASLR'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # Verify the NX bit as shown in bcdedit /enum or Get-BcdEntry, info about numbers and values correlation: https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/bcdosloader-nxpolicy
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Boot Configuration Data (BCD) No-eXecute (NX) Value'
                Compliant    = (((Get-BcdEntry).elements | Where-Object -FilterScript { $_.name -eq 'nx' }).value -eq '3')
                Value        = (((Get-BcdEntry).elements | Where-Object -FilterScript { $_.name -eq 'nx' }).value -eq '3')
                Name         = 'Boot Configuration Data (BCD) No-eXecute (NX) Value'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Smart App Control State'
                Compliant    = 'N/A'
                Value        = $MDAVConfigCurrent.SmartAppControlState
                Name         = 'Smart App Control State'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            try {
                $IndividualItemResult = $((Get-ScheduledTask -TaskPath '\MSFT Driver Block list update\' -TaskName 'MSFT Driver Block list update' -ErrorAction SilentlyContinue) ? $True : $false)
            }
            catch {
                # suppress any possible terminating errors
            }
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Fast weekly Microsoft recommended driver block list update'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Fast weekly Microsoft recommended driver block list update'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            [System.Collections.Hashtable]$DefenderPlatformUpdatesChannels = @{
                0 = 'NotConfigured'
                2 = 'Beta'
                3 = 'Preview'
                4 = 'Staged'
                5 = 'Broad'
                6 = 'Delayed'
            }
            # For PowerShell Cmdlet
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Microsoft Defender Platform Updates Channel'
                Compliant    = 'N/A'
                Value        = $($DefenderPlatformUpdatesChannels[[System.Int64]($MDAVPreferencesCurrent).PlatformUpdatesChannel])
                Name         = 'Microsoft Defender Platform Updates Channel'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            [System.Collections.Hashtable]$DefenderEngineUpdatesChannels = @{
                0 = 'NotConfigured'
                2 = 'Beta'
                3 = 'Preview'
                4 = 'Staged'
                5 = 'Broad'
                6 = 'Delayed'
            }
            # For PowerShell Cmdlet
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Microsoft Defender Engine Updates Channel'
                Compliant    = 'N/A'
                Value        = $($DefenderEngineUpdatesChannels[[System.Int64]($MDAVPreferencesCurrent).EngineUpdatesChannel])
                Name         = 'Microsoft Defender Engine Updates Channel'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Controlled Folder Access Exclusions'
                Compliant    = 'N/A'
                Value        = [PSCustomObject]@{
                    Count    = $MDAVPreferencesCurrent.ControlledFolderAccessAllowedApplications.count
                    Programs = $MDAVPreferencesCurrent.ControlledFolderAccessAllowedApplications
                }
                Name         = 'Controlled Folder Access Exclusions'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            $IndividualItemResult = $MDAVPreferencesCurrent.DisableRestorePoint
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Enable Restore Point scanning'
                Compliant    = ($IndividualItemResult -eq $False)
                Value        = ($IndividualItemResult -eq $False)
                Name         = 'Enable Restore Point scanning'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            $IndividualItemResult = $MDAVPreferencesCurrent.PerformanceModeStatus
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'PerformanceModeStatus'
                Compliant    = [System.Boolean]($IndividualItemResult -eq '0')
                Value        = $IndividualItemResult
                Name         = 'PerformanceModeStatus'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # For PowerShell Cmdlet
            $IndividualItemResult = $MDAVPreferencesCurrent.EnableConvertWarnToBlock
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'EnableConvertWarnToBlock'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'EnableConvertWarnToBlock'
                Category     = $CatName
                Method       = 'Cmdlet'
            }
            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Microsoft-Defender-Category

            #Region Attack-Surface-Reduction-Rules-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Attack Surface Reduction Rules Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'ASR'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')


            # Individual ASR rules verification
            [System.String[]]$Ids = $MDAVPreferencesCurrent.AttackSurfaceReductionRules_Ids
            [System.String[]]$Actions = $MDAVPreferencesCurrent.AttackSurfaceReductionRules_Actions

            # If $Ids variable is not empty, convert them to lower case because some IDs can be in upper case and result in inaccurate comparison
            if ($Ids) { $Ids = $Ids.tolower() }

            # Hashtable to store the descriptions for each ID
            [System.Collections.Hashtable]$ASRsTable = @{
                '26190899-1602-49e8-8b27-eb1d0a1ce869' = 'Block Office communication application from creating child processes'
                'd1e49aac-8f56-4280-b9ba-993a6d77406c' = 'Block process creations originating from PSExec and WMI commands'
                'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' = 'Block untrusted and unsigned processes that run from USB'
                '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' = 'Block Win32 API calls from Office macros'
                '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' = 'Block Adobe Reader from creating child processes'
                '3b576869-a4ec-4529-8536-b80a7769e899' = 'Block Office applications from creating executable content'
                'd4f940ab-401b-4efc-aadc-ad5f3c50688a' = 'Block all Office applications from creating child processes'
                '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = 'Block credential stealing from the Windows local security authority subsystem (lsass.exe)'
                'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' = 'Block executable content from email client and webmail'
                '01443614-cd74-433a-b99e-2ecdc07bfc25' = 'Block executable files from running unless they meet a prevalence; age or trusted list criterion'
                '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = 'Block execution of potentially obfuscated scripts'
                'e6db77e5-3df2-4cf1-b95a-636979351e5b' = 'Block persistence through WMI event subscription'
                '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' = 'Block Office applications from injecting code into other processes'
                '56a863a9-875e-4185-98a7-b882c64b5ce5' = 'Block abuse of exploited vulnerable signed drivers'
                'c1db55ab-c21a-4637-bb3f-a12568109d35' = 'Use advanced protection against ransomware'
                'd3e037e1-3eb8-44c8-a917-57927947596d' = 'Block JavaScript or VBScript from launching downloaded executable content'
            }

            # Loop over each ID in the hashtable
            foreach ($Name in $ASRsTable.Keys) {

                # Check if the $Ids array is not empty and current ID is present in the $Ids array
                if ($Ids -and $Ids -icontains $Name) {
                    # If yes, check if the $Actions array is not empty
                    if ($Actions) {
                        # If yes, use the index of the ID in the array to access the action value
                        $Action = $Actions[$Ids.IndexOf($Name)]
                    }
                    else {
                        # If no, assign a default action value of 0
                        $Action = 0
                    }
                }
                else {
                    # If no, assign a default action value of 0
                    $Action = 0
                }

                # Create a custom object with properties
                $NestedObjectArray += [PSCustomObject]@{
                    FriendlyName = $ASRsTable[$name]
                    Compliant    = [System.Boolean]($Action -eq 1) # Compare action value with 1 and cast to boolean
                    Value        = $Action
                    Name         = $Name
                    Category     = $CatName
                    Method       = 'Cmdlet'
                }
            }

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Attack-Surface-Reduction-Rules-Category

            #Region Bitlocker-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Bitlocker Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Bitlocker'

            # This PowerShell script can be used to find out if the DMA Protection is ON \ OFF.
            # The Script will show this by emitting True \ False for On \ Off respectively.

            # bootDMAProtection check - checks for Kernel DMA Protection status in System information or msinfo32
            [System.String]$BootDMAProtectionCheck =
            @'
  namespace SystemInfo
    {
      using System;
      using System.Runtime.InteropServices;

      public static class NativeMethods
      {
        internal enum SYSTEM_DMA_GUARD_POLICY_INFORMATION : int
        {
            /// </summary>
            SystemDmaGuardPolicyInformation = 202
        }

        [DllImport("ntdll.dll")]
        internal static extern Int32 NtQuerySystemInformation(
          SYSTEM_DMA_GUARD_POLICY_INFORMATION SystemDmaGuardPolicyInformation,
          IntPtr SystemInformation,
          Int32 SystemInformationLength,
          out Int32 ReturnLength);

        public static byte BootDmaCheck() {
          Int32 result;
          Int32 SystemInformationLength = 1;
          IntPtr SystemInformation = Marshal.AllocHGlobal(SystemInformationLength);
          Int32 ReturnLength;

          result = NativeMethods.NtQuerySystemInformation(
                    NativeMethods.SYSTEM_DMA_GUARD_POLICY_INFORMATION.SystemDmaGuardPolicyInformation,
                    SystemInformation,
                    SystemInformationLength,
                    out ReturnLength);

          if (result == 0) {
            byte info = Marshal.ReadByte(SystemInformation, 0);
            return info;
          }

          return 0;
        }
      }
    }
'@
            Add-Type -TypeDefinition $BootDMAProtectionCheck -Language CSharp
            # Returns true or false depending on whether Kernel DMA Protection is on or off
            [System.Boolean]$BootDMAProtection = ([SystemInfo.NativeMethods]::BootDmaCheck()) -ne 0

            # Get the status of Bitlocker DMA protection
            try {
                [System.Int64]$BitlockerDMAProtectionStatus = Get-ItemPropertyValue -Path 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\Microsoft\FVE' -Name 'DisableExternalDMAUnderLock' -ErrorAction SilentlyContinue
            }
            catch {
                # -ErrorAction SilentlyContinue wouldn't suppress the error if the path exists but property doesn't, so using try-catch
            }
            # Bitlocker DMA counter measure status
            # Returns true if only either Kernel DMA protection is on and Bitlocker DMA protection if off
            # or Kernel DMA protection is off and Bitlocker DMA protection is on
            [System.Boolean]$ItemState = ($BootDMAProtection -xor ($BitlockerDMAProtectionStatus -eq '1')) ? $True : $False

            # Create a custom object with 5 properties to store them as nested objects inside the main output object
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'DMA protection'
                Compliant    = $ItemState
                Value        = $ItemState
                Name         = 'DMA protection'
                Category     = $CatName
                Method       = 'Group Policy'
            }


            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # To detect if Hibernate is enabled and set to full
            if (-NOT ($MDAVConfigCurrent.IsVirtualMachine)) {
                try {
                    $IndividualItemResult = $($((Get-ItemProperty 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power' -Name 'HiberFileType' -ErrorAction SilentlyContinue).HiberFileType) -eq 2 ? $True : $False)
                }
                catch {
                    # suppress the errors if any
                }
                $NestedObjectArray += [PSCustomObject]@{
                    FriendlyName = 'Hibernate is set to full'
                    Compliant    = [System.Boolean]($IndividualItemResult)
                    Value        = [System.Boolean]($IndividualItemResult)
                    Name         = 'Hibernate is set to full'
                    Category     = $CatName
                    Method       = 'Cmdlet'
                }
            }
            else {
                $TotalNumberOfTrueCompliantValues--
            }

            # OS Drive encryption verifications
            # Check if BitLocker is on for the OS Drive
            # The ProtectionStatus remains off while the drive is encrypting or decrypting
            if ((Get-BitLockerVolume -MountPoint $env:SystemDrive).ProtectionStatus -eq 'on') {

                # Get the key protectors of the OS Drive
                [System.String[]]$KeyProtectors = (Get-BitLockerVolume -MountPoint $env:SystemDrive).KeyProtector.keyprotectortype

                # Check if TPM+PIN and recovery password are being used - Normal Security level
                if (($KeyProtectors -contains 'Tpmpin') -and ($KeyProtectors -contains 'RecoveryPassword')) {

                    $NestedObjectArray += [PSCustomObject]@{
                        FriendlyName = 'Secure OS Drive encryption'
                        Compliant    = $True
                        Value        = 'Normal Security Level'
                        Name         = 'Secure OS Drive encryption'
                        Category     = $CatName
                        Method       = 'Cmdlet'

                    }
                }

                # Check if TPM+PIN+StartupKey and recovery password are being used - Enhanced security level
                elseif (($KeyProtectors -contains 'TpmPinStartupKey') -and ($KeyProtectors -contains 'RecoveryPassword')) {

                    $NestedObjectArray += [PSCustomObject]@{
                        FriendlyName = 'Secure OS Drive encryption'
                        Compliant    = $True
                        Value        = 'Enhanced Security Level'
                        Name         = 'Secure OS Drive encryption'
                        Category     = $CatName
                        Method       = 'Cmdlet'
                    }
                }

                else {
                    $NestedObjectArray += [PSCustomObject]@{
                        FriendlyName = 'Secure OS Drive encryption'
                        Compliant    = $false
                        Value        = $false
                        Name         = 'Secure OS Drive encryption'
                        Category     = $CatName
                        Method       = 'Cmdlet'
                    }
                }
            }
            else {
                $NestedObjectArray += [PSCustomObject]@{
                    FriendlyName = 'Secure OS Drive encryption'
                    Compliant    = $false
                    Value        = $false
                    Name         = 'Secure OS Drive encryption'
                    Category     = $CatName
                    Method       = 'Cmdlet'
                }
            }
            #region Non-OS-Drive-BitLocker-Drives-Encryption-Verification
            # Get the list of non OS volumes
            [System.Object[]]$NonOSBitLockerVolumes = Get-BitLockerVolume | Where-Object -FilterScript {
                    ($_.volumeType -ne 'OperatingSystem')
            }

            # Get all the volumes and filter out removable ones
            [System.Object[]]$RemovableVolumes = Get-Volume |
            Where-Object -FilterScript { $_.DriveType -eq 'Removable' } |
            Where-Object -FilterScript { $_.DriveLetter }

            # Check if there is any removable volumes
            if ($RemovableVolumes) {

                # Get the letters of all the removable volumes
                [System.String[]]$RemovableVolumesLetters = foreach ($RemovableVolume in $RemovableVolumes) {
                    $(($RemovableVolume).DriveLetter + ':' )
                }

                # Filter out removable drives from BitLocker volumes to process
                $NonOSBitLockerVolumes = $NonOSBitLockerVolumes | Where-Object -FilterScript {
                    ($_.MountPoint -notin $RemovableVolumesLetters)
                }
            }

            # Check if there is any non-OS volumes
            if ($NonOSBitLockerVolumes) {

                # Loop through each non-OS volume and verify their encryption
                foreach ($MountPoint in $($NonOSBitLockerVolumes | Sort-Object).MountPoint) {

                    # Increase the number of available compliant values for each non-OS drive that was found
                    $TotalNumberOfTrueCompliantValues++

                    # If status is unknown, that means the non-OS volume is encrypted and locked, if it's on then it's on
                    if ((Get-BitLockerVolume -MountPoint $MountPoint).ProtectionStatus -in 'on', 'Unknown') {

                        # Check 1: if Recovery Password and Auto Unlock key protectors are available on the drive
                        [System.Object[]]$KeyProtectors = (Get-BitLockerVolume -MountPoint $MountPoint).KeyProtector.keyprotectortype
                        if (($KeyProtectors -contains 'RecoveryPassword') -or ($KeyProtectors -contains 'Password')) {

                            $NestedObjectArray += [PSCustomObject]@{
                                FriendlyName = "Secure Drive $MountPoint encryption"
                                Compliant    = $True
                                Value        = 'Encrypted'
                                Name         = "Secure Drive $MountPoint encryption"
                                Category     = $CatName
                                Method       = 'Cmdlet'
                            }
                        }
                        else {
                            $NestedObjectArray += [PSCustomObject]@{
                                FriendlyName = "Secure Drive $MountPoint encryption"
                                Compliant    = $false
                                Value        = 'Not properly encrypted'
                                Name         = "Secure Drive $MountPoint encryption"
                                Category     = $CatName
                                Method       = 'Cmdlet'
                            }
                        }
                    }
                    else {
                        $NestedObjectArray += [PSCustomObject]@{
                            FriendlyName = "Secure Drive $MountPoint encryption"
                            Compliant    = $false
                            Value        = 'Not encrypted'
                            Name         = "Secure Drive $MountPoint encryption"
                            Category     = $CatName
                            Method       = 'Cmdlet'
                        }
                    }
                }
            }
            #endregion Non-OS-Drive-BitLocker-Drives-Encryption-Verification

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Bitlocker-Category

            #Region TLS-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating TLS Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'TLS'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # ECC Curves
            [System.Object[]]$ECCCurves = Get-TlsEccCurve
            [System.Object[]]$List = ('nistP521', 'curve25519', 'NistP384', 'NistP256')
            # Make sure both arrays are completely identical in terms of members and their exact position
            # If this variable is empty that means both arrays are completely identical
            $IndividualItemResult = Compare-Object -ReferenceObject $ECCCurves -DifferenceObject $List -SyncWindow 0

            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'ECC Curves and their positions'
                Compliant    = [System.Boolean]($IndividualItemResult ? $false : $True)
                Value        = $List
                Name         = 'ECC Curves and their positions'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # Process items in Registry resources.csv file with "Registry Keys" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Registry Keys')

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion TLS-Category

            #Region LockScreen-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Lock Screen Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'LockScreen'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs'] -eq '4,120') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Machine inactivity limit'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Machine inactivity limit'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\DisableCAD'] -eq '4,0') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Interactive logon: Do not require CTRL+ALT+DEL'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Interactive logon: Do not require CTRL+ALT+DEL'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\MaxDevicePasswordFailedAttempts'] -eq '4,5') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Interactive logon: Machine account lockout threshold'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Interactive logon: Machine account lockout threshold'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\DontDisplayLockedUserId'] -eq '4,4') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Interactive logon: Display user information when the session is locked'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Interactive logon: Display user information when the session is locked'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\DontDisplayUserName'] -eq '4,1') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = "Interactive logon: Don't display username at sign-in"
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = "Interactive logon: Don't display username at sign-in"
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'System Access'['LockoutBadCount'] -eq '5') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Account lockout threshold'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Account lockout threshold'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'System Access'['LockoutDuration'] -eq '1440') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Account lockout duration'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Account lockout duration'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'System Access'['ResetLockoutCount'] -eq '1440') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Reset account lockout counter after'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Reset account lockout counter after'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\DontDisplayLastUserName'] -eq '4,1') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = "Interactive logon: Don't display last signed-in"
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = "Interactive logon: Don't display last signed-in"
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion LockScreen-Category

            #Region User-Account-Control-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating User Account Control Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'UAC'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\ConsentPromptBehaviorAdmin'] -eq '4,2') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'UAC: Behavior of the elevation prompt for administrators in Admin Approval Mode'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'UAC: Behavior of the elevation prompt for administrators in Admin Approval Mode'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }


            # This particular policy can have 2 values and they are both acceptable depending on whichever user selects
            [System.String]$ConsentPromptBehaviorUserValue = $SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\ConsentPromptBehaviorUser']
            # This option is automatically applied when UAC category is run
            if ($ConsentPromptBehaviorUserValue -eq '4,1') {
                $ConsentPromptBehaviorUserCompliance = $true
                $IndividualItemResult = 'Prompt for credentials on the secure desktop'
            }
            # This option prompts for additional confirmation before it's applied
            elseif ($ConsentPromptBehaviorUserValue -eq '4,0') {
                $ConsentPromptBehaviorUserCompliance = $true
                $IndividualItemResult = 'Automatically deny elevation requests'
            }
            # If none of them is applied then return false for compliance and N/A for value
            else {
                $ConsentPromptBehaviorUserCompliance = $false
                $IndividualItemResult = 'N/A'
            }

            # Verify a Security Group Policy setting
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'UAC: Behavior of the elevation prompt for standard users'
                Compliant    = $ConsentPromptBehaviorUserCompliance
                Value        = $IndividualItemResult
                Name         = 'UAC: Behavior of the elevation prompt for standard users'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]($($SecurityPoliciesIni.'Registry Values'['MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\ValidateAdminCodeSignatures'] -eq '4,1') ? $True : $False)
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'UAC: Only elevate executables that are signed and validated'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'UAC: Only elevate executables that are signed and validated'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion User-Account-Control-Category

            #Region Device-Guard-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Device Guard Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Device Guard'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Device-Guard-Category

            #Region Windows-Firewall-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Windows Firewall Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Windows Firewall'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Windows-Firewall-Category

            #Region Optional-Windows-Features-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Optional Windows Features Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Optional Windows Features'

            # Windows PowerShell handling Windows optional features verifications
            [System.Object[]]$Results = @()
            $Results = powershell.exe {
                [System.Boolean]$PowerShell1 = (Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2).State -eq 'Disabled'
                [System.Boolean]$PowerShell2 = (Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root).State -eq 'Disabled'
                [System.String]$WorkFoldersClient = (Get-WindowsOptionalFeature -Online -FeatureName WorkFolders-Client).state
                [System.String]$InternetPrintingClient = (Get-WindowsOptionalFeature -Online -FeatureName Printing-Foundation-Features).state
                [System.String]$WindowsMediaPlayer = (Get-WindowsCapability -Online | Where-Object -FilterScript { $_.Name -like '*Media.WindowsMediaPlayer*' }).state
                [System.String]$MDAG = (Get-WindowsOptionalFeature -Online -FeatureName Windows-Defender-ApplicationGuard).state
                [System.String]$WindowsSandbox = (Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM).state
                [System.String]$HyperV = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).state
                [System.String]$VMPlatform = (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).state
                [System.String]$WMIC = (Get-WindowsCapability -Online | Where-Object -FilterScript { $_.Name -like '*wmic*' }).state
                [System.String]$IEMode = (Get-WindowsCapability -Online | Where-Object -FilterScript { $_.Name -like '*Browser.InternetExplorer*' }).state
                [System.String]$LegacyNotepad = (Get-WindowsCapability -Online | Where-Object -FilterScript { $_.Name -like '*Microsoft.Windows.Notepad.System*' }).state
                [System.String]$LegacyWordPad = (Get-WindowsCapability -Online | Where-Object -FilterScript { $_.Name -like '*Microsoft.Windows.WordPad*' }).state
                [System.String]$PowerShellISE = (Get-WindowsCapability -Online | Where-Object -FilterScript { $_.Name -like '*Microsoft.Windows.PowerShell.ISE*' }).state
                [System.String]$StepsRecorder = (Get-WindowsCapability -Online | Where-Object -FilterScript { $_.Name -like '*App.StepsRecorder*' }).state
                # returning the output of the script block as an array
                Return $PowerShell1, $PowerShell2, $WorkFoldersClient, $InternetPrintingClient, $WindowsMediaPlayer, $MDAG, $WindowsSandbox, $HyperV, $VMPlatform, $WMIC, $IEMode, $LegacyNotepad, $LegacyWordPad, $PowerShellISE, $StepsRecorder
            }
            # Verify PowerShell v2 is disabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'PowerShell v2 is disabled'
                Compliant    = ($Results[0] -and $Results[1]) ? $True : $False
                Value        = ($Results[0] -and $Results[1]) ? $True : $False
                Name         = 'PowerShell v2 is disabled'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Work folders is disabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Work Folders client is disabled'
                Compliant    = [System.Boolean]($Results[2] -eq 'Disabled')
                Value        = [System.String]$Results[2]
                Name         = 'Work Folders client is disabled'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Internet Printing Client is disabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Internet Printing Client is disabled'
                Compliant    = [System.Boolean]($Results[3] -eq 'Disabled')
                Value        = [System.String]$Results[3]
                Name         = 'Internet Printing Client is disabled'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify the old Windows Media Player is disabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Windows Media Player (legacy) is disabled'
                Compliant    = [System.Boolean]($Results[4] -eq 'NotPresent')
                Value        = [System.String]$Results[4]
                Name         = 'Windows Media Player (legacy) is disabled'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify MDAG is enabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Microsoft Defender Application Guard is enabled'
                Compliant    = [System.Boolean]($Results[5] -eq 'Enabled')
                Value        = [System.String]$Results[5]
                Name         = 'Microsoft Defender Application Guard is enabled'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Windows Sandbox is enabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Windows Sandbox is enabled'
                Compliant    = [System.Boolean]($Results[6] -eq 'Enabled')
                Value        = [System.String]$Results[6]
                Name         = 'Windows Sandbox is enabled'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Hyper-V is enabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Hyper-V is enabled'
                Compliant    = [System.Boolean]($Results[7] -eq 'Enabled')
                Value        = [System.String]$Results[7]
                Name         = 'Hyper-V is enabled'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Virtual Machine Platform is enabled
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Virtual Machine Platform is enabled'
                Compliant    = [System.Boolean]($Results[8] -eq 'Enabled')
                Value        = [System.String]$Results[8]
                Name         = 'Virtual Machine Platform is enabled'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify WMIC is not present
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'WMIC is not present'
                Compliant    = [System.Boolean]($Results[9] -eq 'NotPresent')
                Value        = [System.String]$Results[9]
                Name         = 'WMIC is not present'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Internet Explorer mode functionality for Edge is not present
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Internet Explorer mode functionality for Edge is not present'
                Compliant    = [System.Boolean]($Results[10] -eq 'NotPresent')
                Value        = [System.String]$Results[10]
                Name         = 'Internet Explorer mode functionality for Edge is not present'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Legacy Notepad is not present
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Legacy Notepad is not present'
                Compliant    = [System.Boolean]($Results[11] -eq 'NotPresent')
                Value        = [System.String]$Results[11]
                Name         = 'Legacy Notepad is not present'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Legacy WordPad is not present
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'WordPad is not present'
                Compliant    = [System.Boolean]($Results[12] -eq 'NotPresent')
                Value        = [System.String]$Results[12]
                Name         = 'WordPad is not present'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify PowerShell ISE is not present
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'PowerShell ISE is not present'
                Compliant    = [System.Boolean]($Results[13] -eq 'NotPresent')
                Value        = [System.String]$Results[13]
                Name         = 'PowerShell ISE is not present'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Verify Steps Recorder is not present
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Steps Recorder is not present'
                Compliant    = [System.Boolean]($Results[14] -eq 'NotPresent')
                Value        = [System.String]$Results[14]
                Name         = 'Steps Recorder is not present'
                Category     = $CatName
                Method       = 'Optional Windows Features'
            }

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Optional-Windows-Features-Category

            #Region Windows-Networking-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Windows Networking Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Windows Networking'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # Check network location of all connections to see if they are public
            $Condition = Get-NetConnectionProfile | ForEach-Object -Process { $_.NetworkCategory -eq 'public' }
            [System.Boolean]$IndividualItemResult = -NOT ($Condition -contains $false) ? $True : $false

            # Verify a Security setting using Cmdlet
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Network Location of all connections set to Public'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Network Location of all connections set to Public'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # Verify a Security setting using registry
            try {
                $IndividualItemResult = [System.Boolean]((Get-ItemPropertyValue -Path 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NetBT\Parameters' -Name 'EnableLMHOSTS' -ErrorAction SilentlyContinue) -eq '0')
            }
            catch {
                # -ErrorAction SilentlyContinue wouldn't suppress the error if the path exists but property doesn't, so using try-catch
            }
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Disable LMHOSTS lookup protocol on all network adapters'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Disable LMHOSTS lookup protocol on all network adapters'
                Category     = $CatName
                Method       = 'Registry Key'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\System\CurrentControlSet\Control\SecurePipeServers\Winreg\AllowedExactPaths\Machine'] -eq '7,') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Network access: Remotely accessible registry paths'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Network access: Remotely accessible registry paths'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Verify a Security Group Policy setting
            $IndividualItemResult = [System.Boolean]$($SecurityPoliciesIni.'Registry Values'['MACHINE\System\CurrentControlSet\Control\SecurePipeServers\Winreg\AllowedPaths\Machine'] -eq '7,') ? $True : $False
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Network access: Remotely accessible registry paths and subpaths'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Network access: Remotely accessible registry paths and subpaths'
                Category     = $CatName
                Method       = 'Security Group Policy'
            }

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Windows-Networking-Category

            #Region Miscellaneous-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Miscellaneous Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Miscellaneous'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # Verify an Audit policy is enabled - only supports systems with English-US language
            if ((Get-Culture).name -eq 'en-US') {
                $IndividualItemResult = [System.Boolean](((auditpol /get /subcategory:"Other Logon/Logoff Events" /r | ConvertFrom-Csv).'Inclusion Setting' -eq 'Success and Failure') ? $True : $False)
                $NestedObjectArray += [PSCustomObject]@{
                    FriendlyName = 'Audit policy for Other Logon/Logoff Events'
                    Compliant    = $IndividualItemResult
                    Value        = $IndividualItemResult
                    Name         = 'Audit policy for Other Logon/Logoff Events'
                    Category     = $CatName
                    Method       = 'Cmdlet'
                }
            }
            else {
                $TotalNumberOfTrueCompliantValues--
            }

            # Checking if all user accounts are part of the Hyper-V security Group
            # Get all the enabled user account SIDs
            [System.Security.Principal.SecurityIdentifier[]]$EnabledUsers = (Get-LocalUser | Where-Object -FilterScript { $_.Enabled -eq 'True' }).SID
            # Get the members of the Hyper-V Administrators security group using their SID
            [System.Security.Principal.SecurityIdentifier[]]$GroupMembers = (Get-LocalGroupMember -SID 'S-1-5-32-578').SID

            # Make sure the arrays are not empty
            if (($null -ne $EnabledUsers) -and ($null -ne $GroupMembers)) {
                # only outputs data if there is a difference, so when it returns $false it means both arrays are equal
                $IndividualItemResult = [System.Boolean](-NOT (Compare-Object -ReferenceObject $EnabledUsers -DifferenceObject $GroupMembers) )
            }
            else {
                # if either of the arrays are null or empty then return false
                [System.Boolean]$IndividualItemResult = $false
            }

            # Saving the results of the Hyper-V administrators members group to the array as an object
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'All users are part of the Hyper-V Administrators group'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'All users are part of the Hyper-V Administrators group'
                Category     = $CatName
                Method       = 'Cmdlet'
            }

            # Process items in Registry resources.csv file with "Registry Keys" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Registry Keys')

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Miscellaneous-Category

            #Region Windows-Update-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Windows Update Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Windows Update'

            # Process items in Registry resources.csv file with "Group Policy" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Group Policy')

            # Verify a Security setting using registry
            try {
                $IndividualItemResult = [System.Boolean]((Get-ItemPropertyValue -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'RestartNotificationsAllowed2' -ErrorAction SilentlyContinue) -eq '1')
            }
            catch {
                # -ErrorAction SilentlyContinue wouldn't suppress the error if the path exists but property doesn't, so using try-catch
            }
            $NestedObjectArray += [PSCustomObject]@{
                FriendlyName = 'Enable restart notification for Windows update'
                Compliant    = $IndividualItemResult
                Value        = $IndividualItemResult
                Name         = 'Enable restart notification for Windows update'
                Category     = $CatName
                Method       = 'Registry Key'
            }

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Windows-Update-Category

            #Region Edge-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Edge Browser Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Edge'

            # Process items in Registry resources.csv file with "Registry Keys" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Registry Keys')

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Edge-Category

            #Region Non-Admin-Category
            $CurrentMainStep++
            Write-Progress -Id 0 -Activity 'Validating Non-Admin Category' -Status "Step $CurrentMainStep/$TotalMainSteps" -PercentComplete ($CurrentMainStep / $TotalMainSteps * 100)

            [System.Object[]]$NestedObjectArray = @()
            [System.String]$CatName = 'Non-Admin'

            # Process items in Registry resources.csv file with "Registry Keys" origin and add them to the $NestedObjectArray array as custom objects
            $NestedObjectArray += [PSCustomObject](Invoke-CategoryProcessing -catname $CatName -Method 'Registry Keys')

            # Add the array of custom objects as a property to the $FinalMegaObject object outside the loop
            Add-Member -InputObject $FinalMegaObject -MemberType NoteProperty -Name $CatName -Value $NestedObjectArray
            #EndRegion Non-Admin-Category

            if ($ExportToCSV) {
                # An array to store the content of each category
                $CsvOutPutFileContent = @()
                # Append the categories in $FinalMegaObject to the array using += operator
                $CsvOutPutFileContent += $FinalMegaObject.PSObject.Properties.Value
                # Convert the array to a CSV file and store it in the current working directory
                $CsvOutPutFileContent | ConvertTo-Csv | Out-File -FilePath '.\Compliance Check Output.CSV' -Force
            }

            if ($ShowAsObjectsOnly) {
                # return the main object that contains multiple nested objects
                return $FinalMegaObject
            }
            else {

                #Region Colors
                [System.Management.Automation.ScriptBlock]$WritePlum = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(221,160,221))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteOrchid = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(218,112,214))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteFuchsia = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(255,0,255))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteMediumOrchid = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(186,85,211))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteMediumPurple = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(147,112,219))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteBlueViolet = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(138,43,226))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$AndroidGreen = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(176,191,26))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WritePink = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(255,192,203))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteHotPink = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(255,105,180))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteDeepPink = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(255,20,147))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteMintGreen = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(152,255,152))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteOrange = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(255,165,0))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$WriteSkyBlue = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(135,206,235))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }
                [System.Management.Automation.ScriptBlock]$Daffodil = { Write-Output -InputObject "$($PSStyle.Foreground.FromRGB(255,255,49))$($PSStyle.Reverse)$($args[0])$($PSStyle.Reset)" }

                [System.Management.Automation.ScriptBlock]$WriteRainbow1 = {
                    $text = $args[0]
                    $colors = @(
                        [System.Drawing.Color]::Pink,
                        [System.Drawing.Color]::HotPink,
                        [System.Drawing.Color]::SkyBlue,
                        [System.Drawing.Color]::Pink,
                        [System.Drawing.Color]::HotPink,
                        [System.Drawing.Color]::SkyBlue,
                        [System.Drawing.Color]::Pink
                    )

                    $Output = ''
                    for ($i = 0; $i -lt $text.Length; $i++) {
                        $color = $colors[$i % $colors.Length]
                        $Output += "$($PSStyle.Foreground.FromRGB($color.R, $color.G, $color.B))$($text[$i])$($PSStyle.Reset)"
                    }
                    Write-Output -InputObject $Output
                }

                [System.Management.Automation.ScriptBlock]$WriteRainbow2 = {
                    $text = $args[0]
                    [System.Object[]]$colors = @(
                        [System.Drawing.Color]::Pink,
                        [System.Drawing.Color]::HotPink,
                        [System.Drawing.Color]::SkyBlue,
                        [System.Drawing.Color]::HotPink,
                        [System.Drawing.Color]::SkyBlue,
                        [System.Drawing.Color]::LightSkyBlue,
                        [System.Drawing.Color]::Lavender,
                        [System.Drawing.Color]::LightGreen,
                        [System.Drawing.Color]::Coral,
                        [System.Drawing.Color]::Plum,
                        [System.Drawing.Color]::Gold
                    )

                    [System.String]$Output = ''
                    for ($i = 0; $i -lt $text.Length; $i++) {
                        $color = $colors[$i % $colors.Length]
                        $Output += "$($PSStyle.Foreground.FromRGB($color.R, $color.G, $color.B))$($text[$i])$($PSStyle.Reset)"
                    }
                    Write-Output -InputObject $Output
                }
                #Endregion Colors

                # Show all properties in list
                if ($DetailedDisplay) {

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(221,160,221))"
                    & $WritePlum "`n-------------Microsoft Defender Category-------------"
                    $FinalMegaObject.'Microsoft Defender' | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(221,160,221))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(218,112,214))"
                    & $WriteOrchid "`n-------------Attack Surface Reduction Rules Category-------------"
                    $FinalMegaObject.ASR | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(218,112,214))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(255,0,255))"
                    & $WriteFuchsia "`n-------------Bitlocker Category-------------"
                    $FinalMegaObject.Bitlocker | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,0,255))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(186,85,211))"
                    & $WriteMediumOrchid "`n-------------TLS Category-------------"
                    $FinalMegaObject.TLS | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(186,85,211))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(147,112,219))"
                    & $WriteMediumPurple "`n-------------Lock Screen Category-------------"
                    $FinalMegaObject.LockScreen | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(147,112,219))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(138,43,226))"
                    & $WriteBlueViolet "`n-------------User Account Control Category-------------"
                    $FinalMegaObject.UAC | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(138,43,226))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(176,191,26))"
                    & $AndroidGreen "`n-------------Device Guard Category-------------"
                    $FinalMegaObject.'Device Guard' | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(176,191,26))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(255,192,203))"
                    & $WritePink "`n-------------Windows Firewall Category-------------"
                    $FinalMegaObject.'Windows Firewall' | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,192,203))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(135,206,235))"
                    & $WriteSkyBlue "`n-------------Optional Windows Features Category-------------"
                    $FinalMegaObject.'Optional Windows Features' | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(135,206,235))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(255,105,180))"
                    & $WriteHotPink "`n-------------Windows Networking Category-------------"
                    $FinalMegaObject.'Windows Networking' | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,105,180))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(255,20,147))"
                    & $WriteDeepPink "`n-------------Miscellaneous Category-------------"
                    $FinalMegaObject.Miscellaneous | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,20,147))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(152,255,152))"
                    & $WriteMintGreen "`n-------------Windows Update Category-------------"
                    $FinalMegaObject.'Windows Update' | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(152,255,152))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(255,165,0))"
                    & $WriteOrange "`n-------------Microsoft Edge Category-------------"
                    $FinalMegaObject.Edge | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,165,0))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method

                    # Setting the List Format Accent the same color as the category's title
                    $PSStyle.Formatting.FormatAccent = "$($PSStyle.Foreground.FromRGB(255,255,49))"
                    & $Daffodil "`n-------------Non-Admin Category-------------"
                    $FinalMegaObject.'Non-Admin' | Format-List -Property FriendlyName, @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,255,49))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    }, Value, Name, Category, Method
                }

                # Show properties that matter in a table
                else {

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(221,160,221))"
                    & $WritePlum "`n-------------Microsoft Defender Category-------------"
                    $FinalMegaObject.'Microsoft Defender' | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(221,160,221))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(218,112,214))"
                    & $WriteOrchid "`n-------------Attack Surface Reduction Rules Category-------------"
                    $FinalMegaObject.ASR | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(218,112,214))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(255,0,255))"
                    & $WriteFuchsia "`n-------------Bitlocker Category-------------"
                    $FinalMegaObject.Bitlocker | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,0,255))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(186,85,211))"
                    & $WriteMediumOrchid "`n-------------TLS Category-------------"
                    $FinalMegaObject.TLS | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(186,85,211))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(147,112,219))"
                    & $WriteMediumPurple "`n-------------Lock Screen Category-------------"
                    $FinalMegaObject.LockScreen | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(147,112,219))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(138,43,226))"
                    & $WriteBlueViolet "`n-------------User Account Control Category-------------"
                    $FinalMegaObject.UAC | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(138,43,226))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(176,191,26))"
                    & $AndroidGreen "`n-------------Device Guard Category-------------"
                    $FinalMegaObject.'Device Guard' | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(176,191,26))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(255,192,203))"
                    & $WritePink "`n-------------Windows Firewall Category-------------"
                    $FinalMegaObject.'Windows Firewall' | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,192,203))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(135,206,235))"
                    & $WriteSkyBlue "`n-------------Optional Windows Features Category-------------"
                    $FinalMegaObject.'Optional Windows Features' | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(135,206,235))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(255,105,180))"
                    & $WriteHotPink "`n-------------Windows Networking Category-------------"
                    $FinalMegaObject.'Windows Networking' | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,105,180))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(255,20,147))"
                    & $WriteDeepPink "`n-------------Miscellaneous Category-------------"
                    $FinalMegaObject.Miscellaneous | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,20,147))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(152,255,152))"
                    & $WriteMintGreen "`n-------------Windows Update Category-------------"
                    $FinalMegaObject.'Windows Update' | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(152,255,152))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(255,165,0))"
                    & $WriteOrange "`n-------------Microsoft Edge Category-------------"
                    $FinalMegaObject.Edge | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,165,0))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize

                    # Setting the Table header the same color as the category's title
                    $PSStyle.Formatting.TableHeader = "$($PSStyle.Foreground.FromRGB(255,255,49))"
                    & $Daffodil "`n-------------Non-Admin Category-------------"
                    $FinalMegaObject.'Non-Admin' | Format-Table -Property FriendlyName,
                    @{
                        Label      = 'Compliant'
                        Expression =
                        { switch ($_.Compliant) {
                                { $_ -eq $true } { $color = "$($PSStyle.Foreground.FromRGB(255,255,49))"; break } # Use PSStyle to set the color
                                { $_ -eq $false } { $color = "$($PSStyle.Foreground.FromRGB(229,43,80))$($PSStyle.Blink)"; break } # Use PSStyle to set the color
                                { $_ -eq 'N/A' } { $color = "$($PSStyle.Foreground.FromRGB(238,255,204))"; break } # Use PSStyle to set the color
                            }
                            "$color$($_.Compliant)$($PSStyle.Reset)" # Use PSStyle to reset the color
                        }

                    } , Value -AutoSize
                }

                # Counting the number of $True Compliant values in the Final Output Object
                [System.Int64]$TotalTrueCompliantValuesInOutPut = ($FinalMegaObject.'Microsoft Defender' | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 49 - 4x(N/A) = 45
                [System.Int64]($FinalMegaObject.ASR | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 17
                [System.Int64]($FinalMegaObject.Bitlocker | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 22 + Number of Non-OS drives which are dynamically increased
                [System.Int64]($FinalMegaObject.TLS | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 21
                [System.Int64]($FinalMegaObject.LockScreen | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 14
                [System.Int64]($FinalMegaObject.UAC | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 4
                [System.Int64]($FinalMegaObject.'Device Guard' | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 8
                [System.Int64]($FinalMegaObject.'Windows Firewall' | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 19
                [System.Int64]($FinalMegaObject.'Optional Windows Features' | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 14
                [System.Int64]($FinalMegaObject.'Windows Networking' | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 9
                [System.Int64]($FinalMegaObject.Miscellaneous | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 18
                [System.Int64]($FinalMegaObject.'Windows Update' | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 14
                [System.Int64]($FinalMegaObject.Edge | Where-Object -FilterScript { $_.Compliant -eq $True }).Count + # 15
                [System.Int64]($FinalMegaObject.'Non-Admin' | Where-Object -FilterScript { $_.Compliant -eq $True }).Count # 11


                #Region ASCII-Arts
                [System.String]$WhenValue1To20 = @'
                OH

                N
                　   O
                　　　 O
                　　　　 o
                　　　　　o
                　　　　　 o
                　　　　　o
                　　　　 。
                　　　 。
                　　　.
                　　　.
                　　　 .
                　　　　.

'@


                [System.String]$WhenValue21To40 = @'

‎‏‏‎‏‏‎⣿⣿⣷⡁⢆⠈⠕⢕⢂⢕⢂⢕⢂⢔⢂⢕⢄⠂⣂⠂⠆⢂⢕⢂⢕⢂⢕⢂⢕⢂
‎‏‏‎‏‏‎⣿⣿⣿⡷⠊⡢⡹⣦⡑⢂⢕⢂⢕⢂⢕⢂⠕⠔⠌⠝⠛⠶⠶⢶⣦⣄⢂⢕⢂⢕
‎‏‏‎‏‏‎⣿⣿⠏⣠⣾⣦⡐⢌⢿⣷⣦⣅⡑⠕⠡⠐⢿⠿⣛⠟⠛⠛⠛⠛⠡⢷⡈⢂⢕⢂
‎‏‏‎‏‏‎⠟⣡⣾⣿⣿⣿⣿⣦⣑⠝⢿⣿⣿⣿⣿⣿⡵⢁⣤⣶⣶⣿⢿⢿⢿⡟⢻⣤⢑⢂
‎‏‏‎‏‏‎⣾⣿⣿⡿⢟⣛⣻⣿⣿⣿⣦⣬⣙⣻⣿⣿⣷⣿⣿⢟⢝⢕⢕⢕⢕⢽⣿⣿⣷⣔
‎‏‏‎‏‏‎⣿⣿⠵⠚⠉⢀⣀⣀⣈⣿⣿⣿⣿⣿⣿⣿⣿⣿⣗⢕⢕⢕⢕⢕⢕⣽⣿⣿⣿⣿
‎‏‏‎‏‏‎⢷⣂⣠⣴⣾⡿⡿⡻⡻⣿⣿⣴⣿⣿⣿⣿⣿⣿⣷⣵⣵⣵⣷⣿⣿⣿⣿⣿⣿⡿
‎‏‏‎‏‏‎⢌⠻⣿⡿⡫⡪⡪⡪⡪⣺⣿⣿⣿⣿⣿⠿⠿⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠃
‎‏‏‎‏‏‎⠣⡁⠹⡪⡪⡪⡪⣪⣾⣿⣿⣿⣿⠋⠐⢉⢍⢄⢌⠻⣿⣿⣿⣿⣿⣿⣿⣿⠏⠈
‎‏‏‎‏‏‎⡣⡘⢄⠙⣾⣾⣾⣿⣿⣿⣿⣿⣿⡀⢐⢕⢕⢕⢕⢕⡘⣿⣿⣿⣿⣿⣿⠏⠠⠈
‎‏‏‎‏‏‎⠌⢊⢂⢣⠹⣿⣿⣿⣿⣿⣿⣿⣿⣧⢐⢕⢕⢕⢕⢕⢅⣿⣿⣿⣿⡿⢋⢜⠠⠈
‎‏‏‎‏‏‎⠄⠁⠕⢝⡢⠈⠻⣿⣿⣿⣿⣿⣿⣿⣷⣕⣑⣑⣑⣵⣿⣿⣿⡿⢋⢔⢕⣿⠠⠈
‎‏‏‎‏‏‎⠨⡂⡀⢑⢕⡅⠂⠄⠉⠛⠻⠿⢿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢋⢔⢕⢕⣿⣿⠠⠈
‎‏‏‎‏‏‎⠄⠪⣂⠁⢕⠆⠄⠂⠄⠁⡀⠂⡀⠄⢈⠉⢍⢛⢛⢛⢋⢔⢕⢕⢕⣽⣿⣿⠠⠈

'@


                [System.String]$WhenValue41To60 = @'

            ⣿⡟⠙⠛⠋⠩⠭⣉⡛⢛⠫⠭⠄⠒⠄⠄⠄⠈⠉⠛⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿
            ⣿⡇⠄⠄⠄⠄⣠⠖⠋⣀⡤⠄⠒⠄⠄⠄⠄⠄⠄⠄⠄⠄⣈⡭⠭⠄⠄⠄⠉⠙
            ⣿⡇⠄⠄⢀⣞⣡⠴⠚⠁⠄⠄⢀⠠⠄⠄⠄⠄⠄⠄⠄⠉⠄⠄⠄⠄⠄⠄⠄⠄
            ⣿⡇⠄⡴⠁⡜⣵⢗⢀⠄⢠⡔⠁⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄
            ⣿⡇⡜⠄⡜⠄⠄⠄⠉⣠⠋⠠⠄⢀⡄⠄⠄⣠⣆⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⢸
            ⣿⠸⠄⡼⠄⠄⠄⠄⢰⠁⠄⠄⠄⠈⣀⣠⣬⣭⣛⠄⠁⠄⡄⠄⠄⠄⠄⠄⢀⣿
            ⣏⠄⢀⠁⠄⠄⠄⠄⠇⢀⣠⣴⣶⣿⣿⣿⣿⣿⣿⡇⠄⠄⡇⠄⠄⠄⠄⢀⣾⣿
            ⣿⣸⠈⠄⠄⠰⠾⠴⢾⣻⣿⣿⣿⣿⣿⣿⣿⣿⣿⢁⣾⢀⠁⠄⠄⠄⢠⢸⣿⣿
            ⣿⣿⣆⠄⠆⠄⣦⣶⣦⣌⣿⣿⣿⣿⣷⣋⣀⣈⠙⠛⡛⠌⠄⠄⠄⠄⢸⢸⣿⣿
            ⣿⣿⣿⠄⠄⠄⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠇⠈⠄⠄⠄⠄⠄⠈⢸⣿⣿
            ⣿⣿⣿⠄⠄⠄⠘⣿⣿⣿⡆⢀⣈⣉⢉⣿⣿⣯⣄⡄⠄⠄⠄⠄⠄⠄⠄⠈⣿⣿
            ⣿⣿⡟⡜⠄⠄⠄⠄⠙⠿⣿⣧⣽⣍⣾⣿⠿⠛⠁⠄⠄⠄⠄⠄⠄⠄⠄⠃⢿⣿
            ⣿⡿⠰⠄⠄⠄⠄⠄⠄⠄⠄⠈⠉⠩⠔⠒⠉⠄⠄⠄⠄⠄⠄⠄⠄⠄⠄⠐⠘⣿
            ⣿⠃⠃⠄⠄⠄⠄⠄⠄⣀⢀⠄⠄⡀⡀⢀⣤⣴⣤⣤⣀⣀⠄⠄⠄⠄⠄⠄⠁⢹

'@



                [System.String]$WhenValue61To80 = @'

                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣴⣿⣿⡷⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣴⣿⡿⠋⠈⠻⣮⣳⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣠⣴⣾⡿⠋⠀⠀⠀⠀⠙⣿⣿⣤⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣤⣶⣿⡿⠟⠛⠉⠀⠀⠀⠀⠀⠀⠀⠈⠛⠛⠿⠿⣿⣷⣶⣤⣄⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⣴⣾⡿⠟⠋⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠛⠻⠿⣿⣶⣦⣄⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⣀⣠⣤⣤⣀⡀⠀⠀⣀⣴⣿⡿⠛⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠛⠿⣿⣷⣦⣄⡀⠀⠀⠀⠀⠀⠀⠀⢀⣀⣤⣄⠀⠀
                ⢀⣤⣾⡿⠟⠛⠛⢿⣿⣶⣾⣿⠟⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠛⠿⣿⣷⣦⣀⣀⣤⣶⣿⡿⠿⢿⣿⡀⠀
                ⣿⣿⠏⠀⢰⡆⠀⠀⠉⢿⣿⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠻⢿⡿⠟⠋⠁⠀⠀⢸⣿⠇⠀
                ⣿⡟⠀⣀⠈⣀⡀⠒⠃⠀⠙⣿⡆⠀⠀⠀⠀⠀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⠇⠀
                ⣿⡇⠀⠛⢠⡋⢙⡆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣾⣿⣿⠄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⠀⠀
                ⣿⣧⠀⠀⠀⠓⠛⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⠛⠋⠀⠀⢸⣧⣤⣤⣶⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀
                ⣿⣿⣤⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠉⠉⠻⣷⣶⣶⡆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣿⣿⠁⠀⠀
                ⠈⠛⠻⠿⢿⣿⣷⣶⣦⣤⣄⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣴⣿⣷⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣾⣿⡏⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠉⠙⠛⠻⠿⢿⣿⣷⣶⣦⣤⣄⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠿⠛⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⢿⣿⡄⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠙⠛⠻⠿⢿⣿⣷⣶⣦⣤⣄⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢿⣿⡄⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠉⠛⠛⠿⠿⣿⣷⣶⣶⣤⣤⣀⡀⠀⠀⠀⢀⣴⡆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢿⡿⣄
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠉⠛⠛⠿⠿⣿⣷⣶⡿⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⣿⣹
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣀⣀⠀⠀⠀⠀⠀⠀⢸⣧
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢻⣿⣆⠀⠀⠀⠀⠀⠀⢀⣀⣠⣤⣶⣾⣿⣿⣿⣿⣤⣄⣀⡀⠀⠀⠀⣿
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠻⢿⣻⣷⣶⣾⣿⣿⡿⢯⣛⣛⡋⠁⠀⠀⠉⠙⠛⠛⠿⣿⣿⡷⣶⣿

'@


                [System.String]$WhenValue81To88 = @'

                ⠀⠀⠀⠀⠀⠀⠀⠀⢀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠔⠶⠒⠉⠈⠸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠪⣦⢄⣀⡠⠁⠀⠀⠀⠀⠀⠀⠀⢀⣀⣠⣤⣤⣤⣤⣤⣄⣀⣀⣀⣀⣀⣀⣀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠈⠉⠀⠀⠀⣰⣶⣶⣦⠶⠛⠋⠉⠀⠀⠀⠀⠀⠀⠀⠉⠉⢷⡔⠒⠚⢽⠃⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣰⣿⡿⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠐⢅⢰⣾⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⣀⡴⠞⠛⠉⣿⠏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⣧⠀⠀⠀⠀⠀
                ⠀⣀⣀⣤⣤⡞⠋⠀⠀⠀⢠⡏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⡇⠀⠀⠀⠀
                ⢸⡏⠉⣴⠏⠀⠀⠀⠀⠀⢸⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⠀⠀⠀⠀
                ⠈⣧⢰⠏⠀⠀⠀⠀⠀⠀⢸⡆⠀⠀⠀⠀⠀⠀⠀⠀⠰⠯⠥⠠⠒⠄⠀⠀⠀⠀⠀⠀⢠⠀⣿⠀⠀⠀⠀
                ⠀⠈⣿⠀⠀⠀⠀⠀⠀⠀⠈⡧⢀⢻⠿⠀⠲⡟⣞⠀⠀⠀⠀⠈⠀⠁⠀⠀⠀⠀⠀⢀⠆⣰⠇⠀⠀⠀⠀
                ⠀⠀⣿⠀⠀⠀⠀⠀⠀⠀⠀⣧⡀⠃⠀⠀⠀⠱⣼⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠠⣂⡴⠋⠀⣀⡀⠀⠀
                ⠀⠀⢹⡄⠀⠀⠀⠀⠀⠀⠀⠹⣜⢄⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠒⠒⠿⡻⢦⣄⣰⠏⣿⠀⠀
                ⠀⠀⠀⢿⡢⡀⠀⠀⠀⠀⠀⠀⠙⠳⢮⣥⣤⣤⠶⠖⠒⠛⠓⠀⠀⠀⠀⠀⠀⠀⠀⠀⠑⢌⢻⣴⠏⠀⠀
                ⠀⠀⠀⠀⠻⣮⣒⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⣧⣤⣀⣀⣀⣤⡴⠖⠛⢻⡆⠀⠀⠀⠀⠀⠀⢣⢻⡄⠀⠀
                ⠀⠀⠀⠀⠀⠀⠉⠛⠒⠶⠶⡶⢶⠛⠛⠁⠀⠀⠀⠀⠀⠀⠀⢀⣀⣤⠞⠁⠀⠀⠀⠀⠀⠀⠈⢜⢧⣄⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣸⠃⠇⠀⠀⠀⠀⠀⠀⠀⠀⠈⠛⠉⢻⠀⠀⠀⠀⠀⠀⠀⢀⣀⠀⠀⠉⠈⣷
                ⠀⠀⠀⠀⠀⠀⠀⣼⠟⠷⣿⣸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⠲⠶⢶⣶⠶⠶⢛⣻⠏⠙⠛⠛⠛⠁
                ⠀⠀⠀⠀⠀⠀⠀⠈⠷⣤⣀⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⠀⠀⠀⠉⠛⠓⠚⠋⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠻⣟⡂⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢹⡟⡟⢻⡟⠛⢻⡄⠀⠀⣸⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⡄⠀⠀⠀⠈⠷⠧⠾⠀⠀⠀⠻⣦⡴⠏⠀⠀⠀⠀⠀⠀⡀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠁⠀⠀⠀⠀⠈⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀

'@


                [System.String]$WhenValueAbove88 = @'
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⢠⣶⣶⣶⣦⣤⣀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣴⣿⠟⠛⢿⣶⡄⠀⢀⣀⣤⣤⣦⣤⡀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⢠⣿⠋⠀⠀⠈⠙⠻⢿⣶⣶⣶⣶⣶⣶⣶⣿⠟⠀⠀⠀⠀⠹⣿⡿⠟⠋⠉⠁⠈⢻⣷⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⣼⡧⠀⠀⠀⠀⠀⠀⠀⠉⠁⠀⠀⠀⠀⣾⡏⠀⠀⢠⣾⢶⣶⣽⣷⣄⡀⠀⠀⠀⠈⣿⡆⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⠀⠀⠀⢸⣧⣾⠟⠉⠉⠙⢿⣿⠿⠿⠿⣿⣇⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⢸⣿⡟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠻⣷⣄⣀⣠⣼⣿⠀⠀⠀⠀⣸⣿⣦⡀⠀⠈⣿⡄⠀⠀⠀
                ⠀⠀⠀⠀⠀⢠⣾⠏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠉⠉⠉⠻⣷⣤⣤⣶⣿⣧⣿⠃⠀⣰⣿⠁⠀⠀⠀
                ⠀⠀⠀⠀⠀⣾⡏⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠹⣿⣀⠀⠀⣀⣴⣿⣧⠀⠀⠀⠀
                ⠀⠀⠀⠀⢸⣿⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠻⠿⠿⠛⠉⢸⣿⠀⠀⠀⠀
                ⢀⣠⣤⣤⣼⣿⣤⣄⠀⠀⠀⡶⠟⠻⣦⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣶⣶⡄⠀⠀⠀⠀⢀⣀⣿⣄⣀⠀⠀
                ⠀⠉⠉⠉⢹⣿⣩⣿⠿⠿⣶⡄⠀⠀⠀⠀⠀⠀⠀⢀⣤⠶⣤⡀⠀⠀⠀⠀⠀⠿⡿⠃⠀⠀⠀⠘⠛⠛⣿⠋⠉⠙⠃
                ⠀⠀⠀⣤⣼⣿⣿⡇⠀⠀⠸⣿⠀⠀⠀⠀⠀⠀⠀⠘⠿⣤⡼⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣤⣼⣿⣀⠀⠀⠀
                ⠀⠀⣾⡏⠀⠈⠙⢧⠀⠀⠀⢿⣧⣀⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⣿⠟⠙⠛⠓⠀
                ⠀⠀⠹⣷⡀⠀⠀⠀⠀⠀⠀⠈⠉⠙⠻⣷⣦⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠰⣶⣿⣯⡀⠀⠀⠀⠀
                ⠀⠀⠀⠈⠻⣷⣄⠀⠀⠀⢀⣴⠿⠿⠗⠈⢻⣧⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣤⣾⠟⠋⠉⠛⠷⠄⠀⠀
                ⠀⠀⠀⠀⠀⢸⡏⠀⠀⠀⢿⣇⠀⢀⣠⡄⢘⣿⣶⣶⣤⣤⣤⣤⣀⣤⣤⣤⣤⣶⣶⡿⠿⣿⠁⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠘⣿⡄⠀⠀⠈⠛⠛⠛⠋⠁⣼⡟⠈⠻⣿⣿⣿⣿⡿⠛⠛⢿⣿⣿⣿⣡⣾⠛⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠙⢿⣦⣄⣀⣀⣀⣀⣴⣾⣿⡁⠀⠀⠀⡉⣉⠁⠀⠀⣠⣾⠟⠉⠉⠋⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠈⠙⠛⠛⠛⠛⠉⠀⠹⣿⣶⣤⣤⣷⣿⣧⣴⣾⣿⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⠻⢦⣭⡽⣯⣡⡴⠟⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀

'@
                #Endregion ASCII-Arts

                switch ($True) {
                    ($TotalTrueCompliantValuesInOutPut -in 1..40) { & $WriteRainbow2 "$WhenValue1To20`nYour compliance score is $TotalTrueCompliantValuesInOutPut out of $TotalNumberOfTrueCompliantValues!" }
                    ($TotalTrueCompliantValuesInOutPut -in 41..80) { & $WriteRainbow1 "$WhenValue21To40`nYour compliance score is $TotalTrueCompliantValuesInOutPut out of $TotalNumberOfTrueCompliantValues!" }
                    ($TotalTrueCompliantValuesInOutPut -in 81..120) { & $WriteRainbow1 "$WhenValue41To60`nYour compliance score is $TotalTrueCompliantValuesInOutPut out of $TotalNumberOfTrueCompliantValues!" }
                    ($TotalTrueCompliantValuesInOutPut -in 121..160) { & $WriteRainbow2 "$WhenValue61To80`nYour compliance score is $TotalTrueCompliantValuesInOutPut out of $TotalNumberOfTrueCompliantValues!" }
                    ($TotalTrueCompliantValuesInOutPut -in 161..200) { & $WriteRainbow1 "$WhenValue81To88`nYour compliance score is $TotalTrueCompliantValuesInOutPut out of $TotalNumberOfTrueCompliantValues!" }
                    ($TotalTrueCompliantValuesInOutPut -gt 200) { & $WriteRainbow2 "$WhenValueAbove88`nYour compliance score is $TotalTrueCompliantValuesInOutPut out of $TotalNumberOfTrueCompliantValues!" }
                }
            }
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
            # Clean up
            Remove-Item -Path '.\security_policy.inf' -Force
        }
    }
    <#
.SYNOPSIS
    Checks the compliance of a system with the Harden Windows Security script guidelines
.LINK
    https://github.com/HotCakeX/Harden-Windows-Security/wiki/Harden%E2%80%90Windows%E2%80%90Security%E2%80%90Module
.DESCRIPTION
    Checks the compliance of a system with the Harden Windows Security script. Checks the applied Group policies, registry keys and PowerShell cmdlets used by the hardening script.
.COMPONENT
    Gpresult, Secedit, PowerShell, Registry
.FUNCTIONALITY
    Uses Gpresult and Secedit to first export the effective Group policies and Security policies, then goes through them and checks them against the Harden Windows Security's guidelines.
.EXAMPLE
    ($result.Microsoft Defender | Where-Object -FilterScript {$_.name -eq 'Controlled Folder Access Exclusions'}).value.programs

    Do this to get the Controlled Folder Access Programs list when using ShowAsObjectsOnly optional parameter to output an object
.EXAMPLE
    $result.Microsoft Defender

    Do this to only see the result for the Microsoft Defender category when using ShowAsObjectsOnly optional parameter to output an object
.PARAMETER ExportToCSV
    Export the output to a CSV file in the current working directory
.PARAMETER ShowAsObjectsOnly
    Returns a nested object instead of writing strings on the PowerShell console, it can be assigned to a variable
.PARAMETER DetailedDisplay
    Shows the output on the PowerShell console with more details and in the list format instead of table format
.INPUTS
    System.Management.Automation.SwitchParameter
.OUTPUTS
    System.String
    System.Object[]
#>
}

# Set PSReadline tab completion to complete menu for easier access to available parameters - Only for the current session
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
