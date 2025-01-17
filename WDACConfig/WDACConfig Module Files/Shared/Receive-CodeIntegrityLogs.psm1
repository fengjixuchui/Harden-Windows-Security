Function Receive-CodeIntegrityLogs {
    <#
    .SYNOPSIS
        A resilient function that:
        Retrieves the Code Integrity Operational logs
        Fixes the paths to the files that are being logged
        Separates events based on their type: Audit or Blocked
        Separates events based on their file paths: existing or deleted
        Finds correlated events with ID 3089 and adds them to the main event (IDs 3076 and 3077)
        Replaces many numbers in the logs with user-friendly strings
        De-duplicates the logs
        Then processes the output based on different criteria
    .PARAMETER Date
        The date from which the logs should be collected. If not specified, all logs will be collected.
        It accepts empty strings, nulls, and whitespace and they are treated as not specified.
    .PARAMETER Type
        The type of logs to be collected. Audit or Blocked. The default value is 'Audit'
    .PARAMETER PostProcessing
        How to process the output for different scenarios
        OnlyExisting: Returns only the logs of files that exist on the disk
        OnlyDeleted: Returns only the hash details of files that do not exist on the disk
        Separate: Returns the file paths of files that exist on the disk and the hash details of files that do not exist on the disk, separately in a nested object
    .PARAMETER PolicyNames
        The names of the policies to filter the logs by
    .INPUTS
        System.String
        System.String[]
    .OUTPUTS
        PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [Parameter(Mandatory = $false)]
        [System.String]$Date,

        [ValidateSet('Audit', 'Blocked')]
        [Parameter(Mandatory = $false)]
        [System.String]$Type = 'Audit',

        [ValidateSet('OnlyExisting', 'OnlyDeleted' , 'Separate')]
        [parameter(mandatory = $false)]
        [System.String]$PostProcessing,

        [AllowEmptyString()]
        [AllowNull()]
        [parameter(mandatory = $false)]
        [System.String[]]$PolicyNames
    )

    Begin {
        # Importing the $PSDefaultParameterValues to the current session, prior to everything else
        . "$ModuleRootPath\CoreExt\PSDefaultParameterValues.ps1"

        # Importing the required sub-modules
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Get-GlobalRootDrives.psm1" -Force

        #Region Application Control event tags intelligence

        # Requested and Validated Signing Level Mappings: https://learn.microsoft.com/en-us/windows/security/application-security/application-control/windows-defender-application-control/operations/event-tag-explanations#requested-and-validated-signing-level
        [System.Collections.Hashtable]$ReqValSigningLevels = @{
            [System.UInt16]0  = "Signing level hasn't yet been checked"
            [System.UInt16]1  = 'File is unsigned or has no signature that passes the active policies'
            [System.UInt16]2  = 'Trusted by Windows Defender Application Control policy'
            [System.UInt16]3  = 'Developer signed code'
            [System.UInt16]4  = 'Authenticode signed'
            [System.UInt16]5  = 'Microsoft Store signed app PPL (Protected Process Light)'
            [System.UInt16]6  = 'Microsoft Store-signed'
            [System.UInt16]7  = 'Signed by an Antimalware vendor whose product is using AMPPL'
            [System.UInt16]8  = 'Microsoft signed'
            [System.UInt16]11 = 'Only used for signing of the .NET NGEN compiler'
            [System.UInt16]12 = 'Windows signed'
            [System.UInt16]14 = 'Windows Trusted Computing Base signed'
        }

        # SignatureType Mappings: https://learn.microsoft.com/en-us/windows/security/application-security/application-control/windows-defender-application-control/operations/event-tag-explanations#signaturetype
        [System.Collections.Hashtable]$SignatureTypeTable = @{
            [System.UInt16]0 = "Unsigned or verification hasn't been attempted"
            [System.UInt16]1 = 'Embedded signature'
            [System.UInt16]2 = 'Cached signature; presence of a CI EA means the file was previously verified'
            [System.UInt16]3 = 'Cached catalog verified via Catalog Database or searching catalog directly'
            [System.UInt16]4 = 'Uncached catalog verified via Catalog Database or searching catalog directly'
            [System.UInt16]5 = 'Successfully verified using an EA that informs CI that catalog to try first'
            [System.UInt16]6 = 'AppX / MSIX package catalog verified'
            [System.UInt16]7 = 'File was verified'
        }

        # VerificationError mappings: https://learn.microsoft.com/en-us/windows/security/application-security/application-control/windows-defender-application-control/operations/event-tag-explanations#verificationerror
        [System.Collections.Hashtable]$VerificationErrorTable = @{
            [System.UInt16]0  =	'Successfully verified signature.'
            [System.UInt16]1  =	'File has an invalid hash.'
            [System.UInt16]2  =	'File contains shared writable sections.'
            [System.UInt16]3  =	"File isn't signed."
            [System.UInt16]4  =	'Revoked signature.'
            [System.UInt16]5  =	'Expired signature.'
            [System.UInt16]6  =	"File is signed using a weak hashing algorithm, which doesn't meet the minimum policy."
            [System.UInt16]7  =	'Invalid root certificate.'
            [System.UInt16]8  =	'Signature was unable to be validated; generic error.'
            [System.UInt16]9  =	'Signing time not trusted.'
            [System.UInt16]10 =	'The file must be signed using page hashes for this scenario.'
            [System.UInt16]11 =	'Page hash mismatch.'
            [System.UInt16]12 =	'Not valid for a PPL (Protected Process Light).'
            [System.UInt16]13 =	'Not valid for a PP (Protected Process).'
            [System.UInt16]14 =	'The signature is missing the required ARM processor EKU.'
            [System.UInt16]15 =	'Failed WHQL check.'
            [System.UInt16]16 =	'Default policy signing level not met.'
            [System.UInt16]17 =	"Custom policy signing level not met; returned when signature doesn't validate against an SBCP-defined set of certs."
            [System.UInt16]18 =	'Custom signing level not met; returned if signature fails to match CISigners in UMCI.'
            [System.UInt16]19 =	'Binary is revoked based on its file hash.'
            [System.UInt16]20 =	"SHA1 cert hash's timestamp is missing or after valid cutoff as defined by Weak Crypto Policy."
            [System.UInt16]21 =	'Failed to pass Windows Defender Application Control policy.'
            [System.UInt16]22 =	'Not Isolated User Mode (IUM) signed; indicates an attempt to load a standard Windows binary into a virtualization-based security (VBS) trustlet.'
            [System.UInt16]23 =	"Invalid image hash. This error can indicate file corruption or a problem with the file's signature. Signatures using elliptic curve cryptography (ECC), such as ECDSA, return this VerificationError."
            [System.UInt16]24 =	'Flight root not allowed; indicates trying to run flight-signed code on production OS.'
            [System.UInt16]25 =	'Anti-cheat policy violation.'
            [System.UInt16]26 =	'Explicitly denied by WDAC policy.'
            [System.UInt16]27 =	'The signing chain appears to be tampered / invalid.'
            [System.UInt16]28 =	'Resource page hash mismatch.'
        }

        #EndRegion Application Control event tags intelligence

        # Validate the date provided if it's not null or empty or whitespace
        if (-NOT ([System.String]::IsNullOrWhiteSpace($Date))) {
            if (-NOT ([System.DateTime]::TryParse($Date, [ref]$Date))) {
                Throw 'The date provided is not in a valid DateTime type.'
            }
        }

        Try {
            # Set a flag indicating that the alternative drive letter mapping method is not necessary unless the primary method fails
            [System.Boolean]$AlternativeDriveLetterFix = $false

            # Get the local disks mappings
            [System.Object[]]$DriveLettersGlobalRootFix = Get-GlobalRootDrives
        }
        catch {
            Write-Verbose -Verbose -Message 'Receive-CodeIntegrityLogs: Could not get the drive mappings from the system using the primary method, trying the alternative method now'

            # Set the flag to true indicating the alternative method is being used
            $AlternativeDriveLetterFix = $true

            # Create a hashtable of partition numbers and their associated drive letters
            [System.Collections.Hashtable]$DriveLetterMappings = @{}

            # Get all partitions and filter out the ones that don't have a drive letter and then add them to the hashtable with the partition number as the key and the drive letter as the value
            foreach ($Drive in (Get-Partition | Where-Object -FilterScript { $_.DriveLetter })) {
                $DriveLetterMappings[[System.String]$Drive.PartitionNumber] = [System.String]$Drive.DriveLetter
            }
        }

        Try {
            Write-Verbose -Message 'Receive-CodeIntegrityLogs: Collecting the Code Integrity Operational logs'
            [System.Diagnostics.Eventing.Reader.EventLogRecord[]]$RawEventLogs = Get-WinEvent -FilterHashtable @{LogName = 'Microsoft-Windows-CodeIntegrity/Operational' }
        }
        catch {
            Throw "Receive-CodeIntegrityLogs: Could not collect the Code Integrity Operational logs, the number of logs collected is $($RawEventLogs.Count)"
        }

        [Microsoft.PowerShell.Commands.GroupInfo[]]$GroupedEvents = $RawEventLogs | Group-Object -Property ActivityId
        Write-Verbose -Message "Receive-CodeIntegrityLogs: Grouped the logs by ActivityId. The total number of groups is $($GroupedEvents.Count) and the total number of logs in the groups is $($GroupedEvents.Group.Count)"

        # Create a collection to store the packages of logs
        [PSCustomObject[]]$EventPackageCollections = @()

        # Loop over each group of logs
        Foreach ($RawLogGroup in $GroupedEvents) {

            # Process Audit events
            if ($RawLogGroup.Group.Id -contains '3076') {

                # Finding the main event in the group
                [System.Diagnostics.Eventing.Reader.EventLogRecord]$AuditTemp = $RawLogGroup.Group | Where-Object -FilterScript { $_.Id -eq '3076' }

                # If the main event is older than the specified date, skip it
                if (-NOT ([System.String]::IsNullOrWhiteSpace($Date))) {
                    if ($AuditTemp.TimeCreated -lt $Date) {
                        continue
                    }
                }

                # Add the main event along with the correlated events to the collection
                $EventPackageCollections += [PSCustomObject]@{
                    MainEventData        = $AuditTemp
                    CorrelatedEventsData = $RawLogGroup.Group | Where-Object -FilterScript { $_.Id -eq '3089' }
                    Type                 = 'Audit'
                }
            }

            # Process Blocked events
            if ($RawLogGroup.Group.Id -contains '3077') {

                # Finding the main event in the group
                [System.Diagnostics.Eventing.Reader.EventLogRecord]$BlockedTemp = $RawLogGroup.Group | Where-Object -FilterScript { $_.Id -eq '3077' }

                # If the main event is older than the specified date, skip it
                if (-NOT ([System.String]::IsNullOrWhiteSpace($Date))) {
                    if ($BlockedTemp.TimeCreated -lt $Date) {
                        continue
                    }
                }

                # Add the main event along with the correlated events to the collection
                $EventPackageCollections += [PSCustomObject]@{
                    MainEventData        = $BlockedTemp
                    CorrelatedEventsData = $RawLogGroup.Group | Where-Object -FilterScript { $_.Id -eq '3089' }
                    Type                 = 'Blocked'
                }
            }
        }

        #Region Output objects definition based on type
        # They return all the logs without post-processing
        [PSCustomObject[]]$OutputAudit = @()
        [PSCustomObject[]]$OutputBlocked = @()

        # They only return the logs of files that exist on the disk
        [PSCustomObject[]]$OutputExistingAudit = @()
        [PSCustomObject[]]$OutputExistingBlocked = @()

        # They only return the hash details of files no longer on the disk
        [PSCustomObject[]]$OutputDeletedAudit = @()
        [PSCustomObject[]]$OutputDeletedBlocked = @()

        # They return FilePaths of files on the disk and hash details of files not on the disk
        $OutputSeparatedAudit = [PSCustomObject]@{
            AvailableFilesPaths = [System.IO.FileInfo[]]@()
            DeletedFileHashes   = [PSCustomObject[]]@()
        }
        $OutputSeparatedBlocked = [PSCustomObject]@{
            AvailableFilesPaths = [System.IO.FileInfo[]]@()
            DeletedFileHashes   = [PSCustomObject[]]@()
        }
        #Endregion Output objects definition based on type
    }

    Process {

        # Loop over each event package in the collection
        foreach ($EventPackage in $EventPackageCollections) {

            # Extract the main event data
            [System.Diagnostics.Eventing.Reader.EventLogRecord]$Event = $EventPackage.MainEventData

            # Convert the main event data to XML object
            $Xml = [System.Xml.XmlDocument]$Event.ToXml()

            # Place each event data in a hashtable and repackage it into a custom object at the end for further processing
            [PSCustomObject[]]$ProcessedEvents = $Xml.event.EventData.data | ForEach-Object -Begin { $Hash = @{} } -Process { $Hash[$_.name] = $_.'#text' } -End { [pscustomobject]$Hash }

            # Loop over each event data object
            foreach ($Log in $ProcessedEvents) {

                # Add the TimeCreated property to the $Log object
                $Log | Add-Member -NotePropertyName 'TimeCreated' -NotePropertyValue $Event.TimeCreated
                # Add the ActivityId property to the $Log object
                $Log | Add-Member -NotePropertyName 'ActivityId' -NotePropertyValue $Event.ActivityId
                # Add the UserId property to the $Log object
                $Log | Add-Member -NotePropertyName 'UserId' -NotePropertyValue $Event.UserId

                # Filter the logs based on the policy that generated them
                if (-NOT ([System.String]::IsNullOrWhiteSpace($PolicyNames))) {
                    if ($Log.PolicyName -notin $PolicyNames) {
                        continue
                    }
                }

                # Define the regex pattern for the device path
                [System.Text.RegularExpressions.Regex]$Pattern = '\\Device\\HarddiskVolume(?<HardDiskVolumeNumber>\d+)\\(?<RemainingPath>.*)$'

                # replace the device path with the drive letter if it matches the pattern
                if ($Log.'File Name' -match $Pattern) {

                    # Use the primary method to fix the drive letter mappings
                    if ($AlternativeDriveLetterFix -eq $false) {

                        [System.UInt32]$HardDiskVolumeNumber = $Matches['HardDiskVolumeNumber']
                        [System.String]$RemainingPath = $Matches['RemainingPath']
                        [PSCustomObject]$GetLetter = $DriveLettersGlobalRootFix | Where-Object -FilterScript { $_.DevicePath -eq "\Device\HarddiskVolume$HardDiskVolumeNumber" }
                        [System.IO.FileInfo]$UsablePath = "$($GetLetter.DriveLetter)$RemainingPath"
                        $Log.'File Name' = $Log.'File Name' -replace $Pattern, $UsablePath
                    }
                    # Use the alternative method to fix the drive letter mappings
                    else {
                        $Log.'File Name' = $Log.'File Name' -replace "\\Device\\HarddiskVolume$($Matches['HardDiskVolumeNumber'])", "$($DriveLetterMappings[$Matches['HardDiskVolumeNumber']]):"
                    }
                }
                # sometimes the file name begins with System32 so we prepend the Windows directory to create a full resolvable path
                # https://learn.microsoft.com/en-us/dotnet/api/system.string.startswith
                elseif ($Log.'File Name'.StartsWith('System32', $true, [System.Globalization.CultureInfo]::InvariantCulture)) {
                    $Log.'File Name' = Join-Path -Path $Env:WinDir -ChildPath ($Log.'File Name')
                }

                # Replace these numbers in the logs with user-friendly strings that represent the signature level at which the code was verified
                $Log.'Requested Signing Level' = $ReqValSigningLevels[[System.UInt16]$Log.'Requested Signing Level']
                $Log.'Validated Signing Level' = $ReqValSigningLevels[[System.UInt16]$Log.'Validated Signing Level']

                # Replace the SI Signing Scenario numbers with a user-friendly string
                $Log.'SI Signing Scenario' = $Log.'SI Signing Scenario' -eq '0' ? 'Kernel-Mode' : 'User-Mode'

                # Translate the SID to a UserName
                Try {
                    [System.Security.Principal.SecurityIdentifier]$ObjSID = New-Object -TypeName System.Security.Principal.SecurityIdentifier($Log.UserId)
                    $Log.UserId = [System.String]($ObjSID.Translate([System.Security.Principal.NTAccount])).Value
                }
                Catch {
                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Could not translate the SID $($Log.UserId) to a username."
                }

                # If there are correlated events, then process them
                if ($null -ne $EventPackage.CorrelatedEventsData) {

                    # Store the unique publisher name in an array
                    [System.String[]]$Publishers = @()

                    # Store the correlated logs in an array - these logs are processed into a custom object
                    [PSCustomObject[]]$CorrelatedLogs = @()

                    foreach ($CorrelatedEvent in $EventPackage.CorrelatedEventsData) {

                        # Convert the main event data to XML object
                        $XmlCorrelated = [System.Xml.XmlDocument]$CorrelatedEvent.ToXml()

                        # Place each event data in a hashtable and repackage it into a custom object at the end for further processing
                        [PSCustomObject[]]$ProcessedCorrelatedEvents = $XmlCorrelated.event.EventData.data | ForEach-Object -Begin { $Hash = @{} } -Process { $Hash[$_.name] = $_.'#text' } -End { [pscustomobject]$Hash }

                        # Loop over each event data object
                        foreach ($CorrelatedLog in $ProcessedCorrelatedEvents) {

                            # Replace the properties with their user-friendly strings
                            $CorrelatedLog.SignatureType = $SignatureTypeTable[[System.UInt16]$CorrelatedLog.SignatureType]
                            $CorrelatedLog.ValidatedSigningLevel = $ReqValSigningLevels[[System.UInt16]$CorrelatedLog.ValidatedSigningLevel]
                            $CorrelatedLog.VerificationError = $VerificationErrorTable[[System.UInt16]$CorrelatedLog.VerificationError]

                            # Add the Correlated Log to the array of Correlated Logs
                            $CorrelatedLogs += $CorrelatedLog

                            # Add the unique publisher name to the array of Publishers
                            if ($CorrelatedLog.PublisherName -notin $Publishers) {
                                $Publishers += $CorrelatedLog.PublisherName
                            }
                        }
                    }

                    Write-Debug -Message "Receive-CodeIntegrityLogs: The number of unique publishers in the correlated events is $($Publishers.Count)"
                    $Log | Add-Member -NotePropertyName 'Publishers' -NotePropertyValue $Publishers

                    # De-Duplicate the correlated logs based on specific properties
                    $CorrelatedLogs = $CorrelatedLogs | Group-Object -Property PublisherTBSHash, PublisherName, IssuerTBSHash, IssuerName |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Debug -Message "Receive-CodeIntegrityLogs: The number of correlated events is $($CorrelatedLogs.Count)"
                    $Log | Add-Member -NotePropertyName 'SignerInfo' -NotePropertyValue $CorrelatedLogs
                }

                # Add the Type property to the log object
                $Log | Add-Member -NotePropertyName 'Type' -NotePropertyValue $EventPackage.Type

                #Region Post-processing for the logs

                if ($Log.Type -eq 'Audit') {

                    # Add the log to the output object if it has Audit type
                    $OutputAudit += $Log

                    # If the file the log is referring to is currently on the disk
                    if (Test-Path -Path $Log.'File Name') {
                        $OutputExistingAudit += $Log
                        $OutputSeparatedAudit.AvailableFilesPaths += $Log.'File Name'
                    }
                    # If the file is not currently on the disk, extract its hashes from the log
                    else {
                        $TempDeletedOutputAudit = $Log | Select-Object -Property FileVersion, 'File Name', PolicyGUID, 'SHA256 Hash', 'SHA256 Flat Hash', 'SHA1 Hash', 'SHA1 Flat Hash'

                        $OutputDeletedAudit += $TempDeletedOutputAudit
                        $OutputSeparatedAudit.DeletedFileHashes += $TempDeletedOutputAudit
                    }
                }
                elseif ($Log.Type -eq 'Blocked') {

                    # Add the log to the output object if it has Blocked type
                    $OutputBlocked += $Log

                    # If the file the log is referring to is currently on the disk
                    if (Test-Path -Path $Log.'File Name') {
                        $OutputExistingBlocked += $Log
                        $OutputSeparatedBlocked.AvailableFilesPaths += $Log.'File Name'
                    }
                    # If the file is not currently on the disk, extract its hashes from the log
                    else {
                        $TempDeletedOutputBlocked = $Log | Select-Object -Property FileVersion, 'File Name', PolicyGUID, 'SHA256 Hash', 'SHA256 Flat Hash', 'SHA1 Hash', 'SHA1 Flat Hash'

                        $OutputDeletedBlocked += $TempDeletedOutputBlocked
                        $OutputSeparatedBlocked.DeletedFileHashes += $TempDeletedOutputBlocked
                    }
                }

                #Endregion Post-processing for the logs
            }
        }
    }

    End {
        Switch ($PostProcessing) {
            'Separate' {
                if ($Type -eq 'Audit') {
                    # De-duplication
                    $OutputSeparatedAudit.AvailableFilesPaths = $OutputSeparatedAudit.AvailableFilesPaths | Select-Object -Unique

                    $OutputSeparatedAudit.DeletedFileHashes = $OutputSeparatedAudit.DeletedFileHashes | Group-Object -Property 'File Name', ProductName, FileVersion, OriginalFileName, FileDescription, InternalName, PackageFamilyName, Publishers, 'SHA256 Hash', 'SHA256 Flat Hash' |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Returning $($OutputSeparatedAudit.AvailableFilesPaths.Count) Audit Code Integrity logs for files on the disk and $($OutputSeparatedAudit.DeletedFileHashes.Count) for the files not on the disk, in a nested object."
                    Return $OutputSeparatedAudit
                }
                else {
                    # De-duplication
                    $OutputSeparatedBlocked.AvailableFilesPaths = $OutputSeparatedBlocked.AvailableFilesPaths | Select-Object -Unique

                    $OutputSeparatedBlocked.DeletedFileHashes = $OutputSeparatedBlocked.DeletedFileHashes | Group-Object -Property 'File Name', ProductName, FileVersion, OriginalFileName, FileDescription, InternalName, PackageFamilyName, Publishers, 'SHA256 Hash', 'SHA256 Flat Hash' |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Returning $($OutputSeparatedBlocked.AvailableFilesPaths.Count) Blocked Code Integrity logs for files on the disk and $($OutputSeparatedBlocked.DeletedFileHashes.Count) for the files not on the disk, in a nested object."
                    Return $OutputSeparatedBlocked
                }
            }
            'OnlyExisting' {
                if ($Type -eq 'Audit') {
                    # De-duplication
                    $OutputExistingAudit = $OutputExistingAudit | Group-Object -Property 'File Name', ProductName, FileVersion, OriginalFileName, FileDescription, InternalName, PackageFamilyName, Publishers, 'SHA256 Hash', 'SHA256 Flat Hash' |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Returning $($OutputExistingAudit.Count) Audit Code Integrity logs for files on the disk."
                    Return $OutputExistingAudit
                }
                else {
                    # De-duplication
                    $OutputExistingBlocked = $OutputExistingBlocked | Group-Object -Property 'File Name', ProductName, FileVersion, OriginalFileName, FileDescription, InternalName, PackageFamilyName, Publishers, 'SHA256 Hash', 'SHA256 Flat Hash' |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Returning $($OutputExistingBlocked.Count) Blocked Code Integrity logs for files on the disk."
                    Return $OutputExistingBlocked
                }
            }
            'OnlyDeleted' {
                if ($Type -eq 'Audit') {
                    # De-duplication
                    $OutputDeletedAudit = $OutputDeletedAudit | Group-Object -Property 'File Name', ProductName, FileVersion, OriginalFileName, FileDescription, InternalName, PackageFamilyName, Publishers, 'SHA256 Hash', 'SHA256 Flat Hash' |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Returning $($OutputDeletedAudit.Count) Audit Code Integrity logs for files not on the disk."
                    Return $OutputDeletedAudit
                }
                else {
                    # De-duplication
                    $OutputDeletedBlocked = $OutputDeletedBlocked | Group-Object -Property 'File Name', ProductName, FileVersion, OriginalFileName, FileDescription, InternalName, PackageFamilyName, Publishers, 'SHA256 Hash', 'SHA256 Flat Hash' |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Returning $($OutputDeletedBlocked.Count) Blocked Code Integrity logs for files not on the disk."
                    Return $OutputDeletedBlocked
                }
            }
            Default {
                if ($Type -eq 'Audit') {
                    # De-duplication
                    $OutputAudit = $OutputAudit | Group-Object -Property 'File Name', ProductName, FileVersion, OriginalFileName, FileDescription, InternalName, PackageFamilyName, Publishers, 'SHA256 Hash', 'SHA256 Flat Hash' |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Returning $($OutputAudit.Count) Audit Code Integrity logs."
                    Return $OutputAudit
                }
                else {
                    # De-duplication
                    $OutputBlocked = $OutputBlocked | Group-Object -Property 'File Name', ProductName, FileVersion, OriginalFileName, FileDescription, InternalName, PackageFamilyName, Publishers, 'SHA256 Hash', 'SHA256 Flat Hash' |
                    ForEach-Object -Process { $_.Group[0] }

                    Write-Verbose -Message "Receive-CodeIntegrityLogs: Returning $($OutputBlocked.Count) Blocked Code Integrity logs."
                    Return $OutputBlocked
                }
            }
        }
    }
}
Export-ModuleMember -Function 'Receive-CodeIntegrityLogs'

# SIG # Begin signature block
# MIILkgYJKoZIhvcNAQcCoIILgzCCC38CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD+k6SyPzW8azo6
# gxH4PNwR1xpSh9r5XlH9lrym/I7OSaCCB9AwggfMMIIFtKADAgECAhMeAAAABI80
# LDQz/68TAAAAAAAEMA0GCSqGSIb3DQEBDQUAME8xEzARBgoJkiaJk/IsZAEZFgNj
# b20xIjAgBgoJkiaJk/IsZAEZFhJIT1RDQUtFWC1DQS1Eb21haW4xFDASBgNVBAMT
# C0hPVENBS0VYLUNBMCAXDTIzMTIyNzExMjkyOVoYDzIyMDgxMTEyMTEyOTI5WjB5
# MQswCQYDVQQGEwJVSzEeMBwGA1UEAxMVSG90Q2FrZVggQ29kZSBTaWduaW5nMSMw
# IQYJKoZIhvcNAQkBFhRob3RjYWtleEBvdXRsb29rLmNvbTElMCMGCSqGSIb3DQEJ
# ARYWU3B5bmV0Z2lybEBvdXRsb29rLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBAKb1BJzTrpu1ERiwr7ivp0UuJ1GmNmmZ65eckLpGSF+2r22+7Tgm
# pEifj9NhPw0X60F9HhdSM+2XeuikmaNMvq8XRDUFoenv9P1ZU1wli5WTKHJ5ayDW
# k2NP22G9IPRnIpizkHkQnCwctx0AFJx1qvvd+EFlG6ihM0fKGG+DwMaFqsKCGh+M
# rb1bKKtY7UEnEVAsVi7KYGkkH+ukhyFUAdUbh/3ZjO0xWPYpkf/1ldvGes6pjK6P
# US2PHbe6ukiupqYYG3I5Ad0e20uQfZbz9vMSTiwslLhmsST0XAesEvi+SJYz2xAQ
# x2O4n/PxMRxZ3m5Q0WQxLTGFGjB2Bl+B+QPBzbpwb9JC77zgA8J2ncP2biEguSRJ
# e56Ezx6YpSoRv4d1jS3tpRL+ZFm8yv6We+hodE++0tLsfpUq42Guy3MrGQ2kTIRo
# 7TGLOLpayR8tYmnF0XEHaBiVl7u/Szr7kmOe/CfRG8IZl6UX+/66OqZeyJ12Q3m2
# fe7ZWnpWT5sVp2sJmiuGb3atFXBWKcwNumNuy4JecjQE+7NF8rfIv94NxbBV/WSM
# pKf6Yv9OgzkjY1nRdIS1FBHa88RR55+7Ikh4FIGPBTAibiCEJMc79+b8cdsQGOo4
# ymgbKjGeoRNjtegZ7XE/3TUywBBFMf8NfcjF8REs/HIl7u2RHwRaUTJdAgMBAAGj
# ggJzMIICbzA8BgkrBgEEAYI3FQcELzAtBiUrBgEEAYI3FQiG7sUghM++I4HxhQSF
# hqV1htyhDXuG5sF2wOlDAgFkAgEIMBMGA1UdJQQMMAoGCCsGAQUFBwMDMA4GA1Ud
# DwEB/wQEAwIHgDAMBgNVHRMBAf8EAjAAMBsGCSsGAQQBgjcVCgQOMAwwCgYIKwYB
# BQUHAwMwHQYDVR0OBBYEFOlnnQDHNUpYoPqECFP6JAqGDFM6MB8GA1UdIwQYMBaA
# FICT0Mhz5MfqMIi7Xax90DRKYJLSMIHUBgNVHR8EgcwwgckwgcaggcOggcCGgb1s
# ZGFwOi8vL0NOPUhPVENBS0VYLUNBLENOPUhvdENha2VYLENOPUNEUCxDTj1QdWJs
# aWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9u
# LERDPU5vbkV4aXN0ZW50RG9tYWluLERDPWNvbT9jZXJ0aWZpY2F0ZVJldm9jYXRp
# b25MaXN0P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQwgccG
# CCsGAQUFBwEBBIG6MIG3MIG0BggrBgEFBQcwAoaBp2xkYXA6Ly8vQ049SE9UQ0FL
# RVgtQ0EsQ049QUlBLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZp
# Y2VzLENOPUNvbmZpZ3VyYXRpb24sREM9Tm9uRXhpc3RlbnREb21haW4sREM9Y29t
# P2NBQ2VydGlmaWNhdGU/YmFzZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0
# aG9yaXR5MA0GCSqGSIb3DQEBDQUAA4ICAQA7JI76Ixy113wNjiJmJmPKfnn7brVI
# IyA3ZudXCheqWTYPyYnwzhCSzKJLejGNAsMlXwoYgXQBBmMiSI4Zv4UhTNc4Umqx
# pZSpqV+3FRFQHOG/X6NMHuFa2z7T2pdj+QJuH5TgPayKAJc+Kbg4C7edL6YoePRu
# HoEhoRffiabEP/yDtZWMa6WFqBsfgiLMlo7DfuhRJ0eRqvJ6+czOVU2bxvESMQVo
# bvFTNDlEcUzBM7QxbnsDyGpoJZTx6M3cUkEazuliPAw3IW1vJn8SR1jFBukKcjWn
# aau+/BE9w77GFz1RbIfH3hJ/CUA0wCavxWcbAHz1YoPTAz6EKjIc5PcHpDO+n8Fh
# t3ULwVjWPMoZzU589IXi+2Ol0IUWAdoQJr/Llhub3SNKZ3LlMUPNt+tXAs/vcUl0
# 7+Dp5FpUARE2gMYA/XxfU9T6Q3pX3/NRP/ojO9m0JrKv/KMc9sCGmV9sDygCOosU
# 5yGS4Ze/DJw6QR7xT9lMiWsfgL96Qcw4lfu1+5iLr0dnDFsGowGTKPGI0EvzK7H+
# DuFRg+Fyhn40dOUl8fVDqYHuZJRoWJxCsyobVkrX4rA6xUTswl7xYPYWz88WZDoY
# gI8AwuRkzJyUEA07IYtsbFCYrcUzIHME4uf8jsJhCmb0va1G2WrWuyasv3K/G8Nn
# f60MsDbDH1mLtzGCAxgwggMUAgEBMGYwTzETMBEGCgmSJomT8ixkARkWA2NvbTEi
# MCAGCgmSJomT8ixkARkWEkhPVENBS0VYLUNBLURvbWFpbjEUMBIGA1UEAxMLSE9U
# Q0FLRVgtQ0ECEx4AAAAEjzQsNDP/rxMAAAAAAAQwDQYJYIZIAWUDBAIBBQCggYQw
# GAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGC
# NwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQx
# IgQgzjFTSjtrwigp2bcZobnKOh0vqaFZ+5GO3XdrLptEylgwDQYJKoZIhvcNAQEB
# BQAEggIAAd/iAOjIxhjMQWV8RgzQcjyWbeuRfmIzGILOxPkAZ8Za39cnjd6enkBo
# IzvHIlI186QvKa4MJyKv46Wov96BF5aMAURTgrTcPqOrG6V7TP2TK8bQ/0IjIqSZ
# W5/7mKdxs8FTljTy/nlxJRg/7AavtyyO73Qh3Z+bejeBODR6A1lMLosBgyNjb10Z
# oFCqPoBouXHmT30dkc1j05NoAcp3lNn78KHjLCMam/mt9eAfedFmYZiaKoABpN1t
# T1GeT9jE+DbipgDj9dKcawudl2gQFM1pSt6kJtvm3orCZediyofZWMKznblQwtTn
# PRWF/mj0yEUJPWXJYU0MUGGYbXpNnMr3QjPoF73cM7ZrbIZzi6CXKqLVYni3fWum
# rQ3MRGyDEqr5aNM73K5NHUKheMSWM8tqR7vRm4wZbZZwAjB17VYsmWXyXOrWwJId
# FL7tbOj6ACCU3Xdo2t6JkD3SyX2cwtdlaLcRJhAexzqtdszfsXT+OLvWDPGHKeek
# OIw/mqcONic5O7yKWwsdRoNWZklfajcHb47QZhKUOgC6uE7qKtSlztWR5dmGYavu
# PLRhCPlfAzQRDWRlq3lwE6jcamruybDMMRAdrohuFPScZbWhyBCFpQmW4vzaInaW
# KCK/0qeex8rzqKZMMBcSyfqhiYfcFFf6CjiZXz0oIFzFIErxiNg=
# SIG # End signature block
