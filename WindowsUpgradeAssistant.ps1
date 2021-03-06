
[CmdletBinding()]
Param(
        [Parameter(Mandatory=$false, Position=0)] $TimerDuration = 10, # In minutes
        [Parameter(Mandatory=$false, Position=1)] $AutoCloseDuration = 60, # In minutues
        [Parameter(Mandatory=$false, Position=2)] $LogFile 
    )

# If no log file is specfied, it gets created under the SsystemDrive\Logs directory.
If (!$LogFile) {
    $LogDir = "$env:SystemDrive\Logs"
    $LogFile = "$LogDir\WindowsUpgradeAssistant.log" 
    If (!(Test-Path $LogDir)) {
        New-Item $LogDir -ItemType Directory | Out-Null
    }
}

# Function displays the message on the screen and writes to a log file. 
Function Write-ToLog {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)] $Message
    )
    
    "[$(Get-date)] $Message" | Out-File -FilePath $LogFile -Encoding Unicode -Append

    Write-Host "[$(Get-date)] $Message"
}

# Get hardware model
Function Get-HardwareModel() {
    $computerSystem = Get-WmiObject -Query "Select * from Win32_ComputerSystem"
    $computerSystemProduct = Get-WmiObject -Query "Select * from Win32_ComputerSystemProduct"

    if ($computerSystemProduct.Vendor -eq "Lenovo") {
        $Value = "$($computerSystemProduct.Vendor) $($computerSystemProduct.Version)"
    } else {
        $Value = "$($computerSystem.Manufacturer) $($computerSystem.Model)"
    } 

    Return $Value
}

# Function to check if the device is connected to external power
Function Get-ExternalPowerStatus {

    $hardwareType = (Get-WmiObject -Class Win32_ComputerSystem).PCSystemType

    #Check hardware is mobile type
    If ($hardwaretype -eq 2) {
        $Power = (Get-WmiObject -Class BatteryStatus -Namespace root\wmi).PowerOnLine
        If ($Power -contains "True") {
            $Status = $true
        } else {
            $Status = $false
        }
    } else {
        $Status = $true
    }

    Return $Status
}

# Function to check for the free disk space 
Function Get-FreeDiskSpace {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)] $diskspace
    )

    $DiskDetails = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'" | Select-Object DeviceId, MediaType, @{n="Size";e={[math]::Round($_.Size/1GB,2)}},@{n="FreeSpace";e={[math]::Round($_.FreeSpace/1GB,2)}}
    If($DiskDetails.FreeSpace -ge $diskspace) {
        $Status =  $true
    } else {
        $Status =  $false
    }

    Return $Status
}

# Function to get network connection type
Function Get-NetworkConnectionType {

    $adapters = Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} 

    
    # If the name contains juniper of AnyConnect then it connection type is s VPN
    If ( $( $adapters | Where-Object {($_.InterfaceDescription -like "*juniper*") -or ($_.InterfaceDescription -like "*AnyConnect*")}) -ne $null) {
        $ConnectType = "VPN"
    } 
    # If InterfaceType is 71 then one ore more adapters are connected to wireless
    elseif (  $adapters | Where-Object {($_.InterfaceType -eq "71") } ) {
        
        # If there is only one collection there it has to be wireless
        If (($adapters | Where-Object {$_.HardwareInterface -eq  $true} | Measure-Object).Count -eq 1) {
            
            # Added this on 01 March 2019 as it was detecing Wireless for Thinkpad Thunderbolt dock
            $CurrentAdapter = $adapters | Where-Object {$_.HardwareInterface -eq  $true}
            If (($CurrentAdapter.Name -eq 'Ethernet') -and ($CurrentAdapter.LinkSpeed -eq '1 Gbps')) {
                $ConnectType = "Wired"
            } else {
                $ConnectType = "Wireless"
            }
        } else {
            # If there are more connections then find the adapters without 169 IP, if the count is 1 then it has to be wireless
            If ((Get-NetIPConfiguration | Where-Object {($_.IPv4Address -ne $null) -and ($_.IPv4Address.IPAddress -notlike '169*')} | Measure-Object).Count -eq 1) {
                $ConnectType = "Wireless"
            } else {
                # If there are more connections then find the adapters without 169 IP, if the count is > 1 then needs to find out what it is hence it is unknown for now
                If ($adapters.Name -like 'Ethernet*') { # Updated on 15 April 2019 to consider adatpers with names like 'Ethernet #' as wired adapters
                    $ConnectType = "Wired"
                } else {
                    $ConnectType = "Unknown"
                }
            }
        }

    } else {
        $ConnectType = "Wired"
    }
    
    Return $ConnectType
}

# Check if a user is logged in
Function Get-UserLoggedInStatus {

    #Check if the explorer is in use
    $CheckExplorer = Get-WmiObject -Query 'Select * from Win32_process WHERE name=''explorer.exe''' 
    $LoggedInUserList = ""

    If ($CheckExplorer) {
            $Status = $true
            $Counter = 0
            $CheckExplorer | Foreach-Object { 
                If ($Counter -eq 0) {
                    $LoggedInUserList = "$($($_.GetOwner()).domain)\$($($_.GetOwner()).user)"
                } else {
                    $LoggedInUserList += ";$($($_.GetOwner()).domain)\$($($_.GetOwner()).user)"
                }
                $Counter += 1
            }
        } else {
            $Status = $false
        }
    [PSCustomObject]$Object = @{
                                Status=$Status
                                LoggedInUserList = $LoggedInUserList
                            }
    Return $Object
}

# Function to check the prereqs by calling the individual functions, add more functions as required and call them in this function
Function Get-PreReqStatus {
    
    $errorMessage = ""
    $errorCode = 0
    $ErrorCodes = Import-Csv "$PSScriptRoot\ErrorCodes.csv" | Group-Object -AsHashTable -Property ErrorCode
    $errorCount = 0

    If ($(Get-ExternalPowerStatus) -eq $false) {
        If ($errorCount -ge 1) {
            $errorMessage += "`n"
        }
        
        # Increment by 1 everytime there is pre-req not meeting
        $errorCount += 1
        $errorCode += 1 # error code is 2 to the power of 0 = 1
        $message = $($ErrorCodes["1"].ErrorMessage) # Update this number with the error code
        $errorMessage += "- $message" 

        Write-ToLog $message
    } 

    If ($(Get-FreeDiskSpace 20) -eq $false) {
        If ($errorCount -ge 1) {
            $errorMessage += "`n"
        }
        
        $errorCount += 1
        $errorCode += 2 # error code is 2 to the power of 1 = 2
        $message = $($ErrorCodes["2"].ErrorMessage) # Update this number with the error code
        $errorMessage += "- $message"

        Write-ToLog $message
    } 

    $Object = [PSCustomObject] @{
        ErrorCode = $errorCode
        ErrorMessage = $errorMessage
        ErrorCount = $errorCount
    }

    Return $object
}

# Function to update or create registry item
Function Set-Registry {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory, Position=0)] $Key,
        [Parameter(Position=1)] $Value,
        [Parameter(Position=2)] $Data,
        [ValidateSet("String", "ExpandString", "Binary", "DWord", "MultiString", "Qword")] 
        [Parameter(Position=3)] $Type="String",
        [ValidateSet($true, $false)] [Parameter(Position=5)] $Logging=$true
    ) 

    If (!(Test-Path $Key)) {
        Try {
            New-Item -Path $Key -Force -ErrorAction Stop | Out-Null
            If ($Logging ) { Write-ToLog "$Key created" }    
        } Catch {
            If ($Logging ) {Write-ToLog $_}
        }
    } else {
        # If ($Logging) { Write-TextToLog "$Path already exists, using existing" }
    }

    If ($PSBoundParameters.ContainsKey('Value')) {
        If (Test-Path $Key) {
            Try {
                Set-ItemProperty -Path $Key -Name $Value -Value $Data -Type $Type -Force -ErrorAction Stop
                If ($Logging ) { Write-ToLog "$Key\$Value = $Data" } 
            } Catch {
                If ($Logging ) { Write-ToLog $_}    
            }
        }
    }
}

# Function to close SCCM Task Sequence progress bar
Function Close-SCCMTSProgressBar {
    Try {
        $TSProgressUI = New-Object -ComObject Microsoft.SMS.TSProgressUI -ErrorAction Stop;
        $TSProgressUI.CloseProgressDialog();  
        #Write-ToLog "Successfully closed SCCM TS progress bar"
    } Catch {
        Write-ToLog "Script not run via SCCM, will not attempt to close SCCM progress bar"
    }
}


# Function to set SCCM Task Sequence variable
Function Set-SCCMTSVariable {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)] $Name,
        [Parameter(Mandatory=$true)] $Value
    )

    Try {
    
        $TSEnvironment = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop;
     
        $TSEnvironment.Value("$Name")  = $Value
        #Write-ToLog "Successfully set SCCM TS Variable ($Name = $Value)"
    } Catch {
        Write-ToLog "Script not run via SCCM, will not attempt to set the SCCM TS variable $Name"
    }
}

# Function to get SCCM Task Sequence variable
Function Get-SCCMTSVariable {
    Param(
        [Parameter(Mandatory=$true)] $Name
    )

    $TSValue = $null
    Try {
    
        $TSEnvironment = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop;
     
        $TSValue = $TSEnvironment.Value("$Name")
        #Write-ToLog "Successfully set SCCM TS Variable ($Name = $TSValue)"
    } Catch {
        Write-ToLog "Script not run via SCCM, will not attempt to get the SCCM TS variable $Name"
    }
    
    Return $TSValue   
}

Function Initialize-WPFForm {
    # Load the required assemblies for the GUI
    [System.Reflection.Assembly]::LoadWithPartialName('presentationframework') 	| out-null
    [System.Reflection.Assembly]::LoadFrom("$PSScriptRoot\assembly\MahApps.Metro.dll")  | out-null
    [System.Reflection.Assembly]::LoadFrom("$PSScriptRoot\assembly\ControlzEx.dll")  | out-null

    # Load MainWindow

    $XamlLoader=(New-Object System.Xml.XmlDocument)
    $XamlLoader.Load("$PSScriptRoot\WindowsUpgradeAssistant.xaml")
    $Reader = (New-Object System.Xml.XmlNodeReader $XamlLoader)
    
    $Script:Form = [Windows.Markup.XamlReader]::Load($Reader)

    [System.Xml.XmlNamespaceManager] $nsmgr = $XamlLoader.NameTable
    $nsmgr.AddNamespace("xaml", "http://schemas.microsoft.com/winfx/2006/xaml/presentation")
    $nsmgr.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')

    $Script:FormVariableList = @()
    $XamlLoader.SelectNodes("//*[@x:Name]",$nsmgr) | ForEach-Object {

        New-Variable -Name "$($_.Name)" -Value $Form.FindName($_.Name) -Force -Scope Global
        $Script:FormVariableList += $_.Name
    }
}

Function Set-CommonExitAttributes  {
    Param(
        [Parameter(Mandatory=$true)] $ExitCode
    )
    $Form.close()
    
    $ScriptEndtime = Get-Date
    
    $TSNotificationRunTime = $($ScriptStartTime.ToUniversalTime() - $ScriptEndtime.ToUniversalTime()).ToString("hh\:mm\:ss")
    
    # Run of the script
    Write-ToLog "TSNotificationRunTime: $TSNotificationRunTime"
    Set-Registry -Key $IPURegPath -Value 'TSNotificationRunTime' -Data $TSNotificationRunTime

    Write-ToLog "ExitCode: $ExitCode"

    Write-ToLog "########## End ##########"

    Exit $ExitCode
}

Function Write-NetworkConnectionType {

    # Get the connection is vpn, wireless or wired
    $NetworkConnectionType = Get-NetworkConnectionType

    Write-ToLog "NetworkConnectionType: $NetworkConnectionType"
    Set-Registry -Key $IPURegPath -Value "NetworkConnectionType" -Data $NetworkConnectionType

    # Assign the SCCM TS variable
    Set-SCCMTSVariable -Name "NetworkConnectionType" -Value $NetworkConnectionType

    Return $NetworkConnectionType
}

######### Main script ###########

$ScriptStartTime = Get-Date
Write-ToLog "########## Start ##########"

# Update MyCompany as per the requirement,. this is where the 

$IPURegPath = "HKLM:\SOFTWARE\MyCompany\IPU"
$UserLoggedInInfo = Get-UserLoggedInStatus
$UserLoggedIn  = $UserLoggedInInfo.Status
$StartingExitCode = 10000 # This will be the starting range of the exit codes of this script
$PreCheckStatus = @()
$ExitCode = 0

Write-ToLog "DeviceName: $($env:computername)"
Write-ToLog "UserLoggedIn: $UserLoggedIn"
Set-Registry -Key $IPURegPath -Value "UserLoggedIn" -Data $UserLoggedIn

If ($UserLoggedIn) {
    Write-ToLog "LoggedInUserList: $($UserLoggedInInfo.LoggedInUserList)"
    Set-Registry -Key $IPURegPath -Value "LoggedInUserList" -Data $UserLoggedInInfo.LoggedInUserList
}

try {
    $ADSite = ""
    $ADSite = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name
} catch {}

Write-ToLog "ADSite: $ADSite "
Set-Registry -Key $IPURegPath -Value "ADSite" -Data $ADSite

Write-ToLog "HardwareModel: $(Get-HardwareModel)"
Write-ToLog "TimerDuration: $TimerDuration"
Write-ToLog "AutoCloseDuration: $AutoCloseDuration"
Write-ToLog "LogFile: $Logfile"

# The NumberOfUpgradeAttempts is incremented whenever the script runs
Try {
    $NumberOfUpgradeAttempts = Get-ItemPropertyValue -Path $IPURegPath -Name "NumberofUpgradeAttempts" -ErrorAction Stop
    [int]$NumberOfUpgradeAttempts += 1
} Catch {
    [int]$NumberOfUpgradeAttempts = 1
}

Set-Registry -Key $IPURegPath -Value 'NumberOfUpgradeAttempts' -Data $NumberofUpgradeAttempts

# Close SCCM progress bar
Close-SCCMTSProgressBar

# Write NetworkConnectionType to registry and SCCM TS varaible
$NetworkConnectionType = Write-NetworkConnectionType 

# Initalize the form and load the control variables
Initialize-WPFForm

# Display compliance error if the device is not upgraded after production end date which needs to be defined as a task sequence variable

$ProductionEndDate = Get-SCCMTSVariable -Name "ProductionEndDate"
#$ProductionEndDate = "2018-November-01" #Use this for testing when the script is not run via SCCM TS

If ($ProductionEndDate ) {
    $ProductionEndDate = [datetime]$ProductionEndDate
    $CurrentDate = Get-Date

    Write-ToLog "ProductionEndDate: $($ProductionEndDate.ToString('dd-MMM-yyyy'))"
    Write-ToLog "CurrentDate: $($CurrentDate.ToString('dd-MMM-yyyy'))"

    $DaysSinceProduction = $($CurrentDate - $ProductionEndDate).Days
    Write-ToLog "DaysSinceProduction: $DaysSinceProduction"

    # 21 = 3 weeks
    If ($DaysSinceProduction  -gt 21) {
        $ComplianceFailureText.Visibility = "Visible"
        $ProductionEndDateText = $Form.FindName("ProductionEndDateText")
        $ProductionEndDateText.Text = $ProductionEndDate.ToString('dd-MMM-yyyy')
    }
} else {
    Write-ToLog "ProductionEndDate: Not set" 
}

# Script block to create a timer
$TimerScriptBlock = {

    $startTime = Get-Date
    
    $endTime = $startTime.AddMinutes($TimerDuration)
    $totalSeconds = (New-TimeSpan -Start $startTime -End $endTime).TotalSeconds
    #$secondsElapsedForShowWindow = 0
    do {
        $now = Get-Date
        $secondsElapsed = (New-TimeSpan -Start $startTime -End $now).TotalSeconds

        $secondsRemaining = $totalSeconds - $secondsElapsed
        $timespan = [timespan]::FromSeconds($secondsRemaining)

        #$percentDone = ($secondsElapsed / $totalSeconds) * 100
        
        $TimerHour.Content = $timespan.Hours
        $TimerMinute.Content = $timespan.Minutes
        $TimerSecond.Content = $timespan.Seconds

        $Form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ContextIdle);
        
    } Until ($now -ge $endTime)
    
    Set-CommonExitAttributes -ExitCode $ExitCode
}

# Script block to show the error panel
$ShowErrorPanelScriptBlock = {

    # Show the error message
    $ErrorMessagePanel.Visibility = "Visible"
    $ErrorMessageText.Text = $PreCheckStatus.ErrorMessage

    # Hide the upgrade now and upgrade now text
    $UpgradeNowButton.Visibility = "Collapsed"
    $UpgradeNowWiredPanel.Visibility = "Collapsed"
    $UpgradeNowWirelessPanel.Visibility = "Collapsed"
    $UpgradeNowVPNPanel.Visibility = "Collapsed"
    $TimerPanel.Visibility = "Collapsed"

    # Show the cancel and Tryagain buttons
    $CancelButton.Visibility = "Visible"
    $TryagainButton.Visibility = "Visible"
}

# Script block to hide the error panel
$HideErrorPanelScriptBlock = {

    # Hide the error message
    $ErrorMessagePanel.Visibility = "Collapsed"

    # Show the Upgrade now and upgrade now text

    Switch ($NetworkConnectionType) {
        'VPN' {
            # If on VPN then show different text for upgrade now and show cancel button
            $UpgradeNowVPNPanel.Visibility = "Visible"
            $CancelButton.Visibility = "Visible"
        }
        'Wireless' {
            $UpgradeNowWirelessPanel.Visibility = "Visible"
            $TimerPanel.Visibility = "Visible"
            $CancelButton.Visibility = "Collapsed"
        }
        'Wired' {
            $UpgradeNowWiredPanel.Visibility = "Visible"
            $TimerPanel.Visibility = "Visible"
            $CancelButton.Visibility = "Collapsed"
        }
    }
    
    # Hide the Tryagain button and show the upgrade now button
    $UpgradeNowButton.Visibility = "Visible"
    $TryagainButton.Visibility = "Collapsed"
}

# Hide the Hours timer if the time is less than 60 minutes
If ($TimerDuration -le 60) {
    $HoursGroup.Visibility = "Collapsed"
}

# Show different text based on the connection type
# Always show cancel button for vpn

Switch ($NetworkConnectionType) {
    'VPN' {
        $VPNContent.Visibility = "Visible"
        $CancelButton.Visibility = "Visible"
    }
    'Wireless' {
        $WirelessContent.Visibility = "Visible"
        $CancelButton.Visibility = "Collapsed"
    }
    'Wired' {
        $WiredContent.Visibility = "Visible"
    }
}

# Check prereqs
$Script:PreCheckStatus = Get-PreReqStatus

If ($PreCheckStatus.ErrorMessage -eq "" ) {
    
    $ExitCode = $PreCheckStatus.ErrorCode

    # If no user is logged in then exit with precheck exit code instead of displaying the form
    If ($UserLoggedIn -eq $false) {
        <#Write-ToLog "ExitCode: $ExitCode"
        $ScriptEndtime = Get-Date
        Write-ToLog "EndTime: $ScriptEndtime"
        
        Exit $ExitCode
        #>
        Set-CommonExitAttributes -ExitCode $ExitCode
    } else {
        & $HideErrorPanelScriptBlock
        $Form.Add_ContentRendered({    
            & $TimerScriptBlock
        })
    }
} else {

    $ExitCode = $StartingExitCode + $PreCheckStatus.ErrorCode

    # If no user is loggedin then exit with precheck exit code instead of displaying the form
    If ($UserLoggedIn -eq $false) {
        Set-CommonExitAttributes -ExitCode $ExitCode
    } else {
        & $ShowErrorPanelScriptBlock
    }
}

# Auto close the application after a defined duration if user does not proceed with the deployment
# This will exit the task sequence with the same exit code when user cancels the deployment.  

If($CancelButton.Visibility -eq "Visible") {
    #$AutoCloseDuration = 60 # In minutues

    Write-ToLog "Auto closing the form in $AutoCloseDuration minutes"

    $ExitCode = $StartingExitCode + $PreCheckStatus.ErrorCode

    #Event handlers             
    $Form.Add_SourceInitialized({
        # To avoid errors while converting minutes more than 59        
        if ($AutoCloseDuration -le 59) {
            $script:seconds =([timespan]0).Add("0:$AutoCloseDuration")
        } else {
            $TimeSpanObj =New-TimeSpan -Minutes $AutoCloseDuration
            $script:seconds =([timespan]0).Add("$($TimeSpanObj.Hours):$($TimeSpanObj.Minutes)")
        }
        
        # Create timer   
        $script:timer = new-object System.Windows.Threading.DispatcherTimer
        
        # Fires every 1 minute (Hours:Minutes:Seconds) (i.e if you set to 1 hour it runs 60 times). Change it as needed
        # This can be updated as needed based on AutoCloseDuration
        $timer.Interval = [TimeSpan]'0:1:0.0'
        
        # Invoke the $updateBlock          
        $timer.Add_Tick.Invoke($UpDateBlock)
        
        # Start the timer            
        $timer.Start()
        if ($timer.IsEnabled -eq $false) {
            Write-ToLog "Timer failed to start"
        }
    })

    $UpDateBlock = ({
        # Fires every 1 minute (Hours:Minutes:Seconds) (i.e if you set to 1 hour it runs 60 times). Change it as needed
        # It substracts 1 minute every 1 minute until it becomes 0 and exits
        # This can be updated as needed based on AutoCloseDuration
        $script:seconds= $script:seconds.Subtract('0:1:0')
        
        # uncomment the below for troubleshooting
        #Write-Host $seconds.ToString('mm\:ss')

        if($seconds -le 0) {  
            $Form.close()

            Write-ToLog "Auto closed the form after $AutoCloseDuration minutes"
            
            Set-CommonExitAttributes -ExitCode $ExitCode
        }
    })
}

# Try again prereqs
$TryagainButton.add_click({
    
    Write-ToLog "User clicked: Trying again"

    # Redetect the Network connection and assign it to the variable
    $NetworkConnectionType = Write-NetworkConnectionType 

    # Check prereqs
    $Script:PreCheckStatus = Get-PreReqStatus

    If ($PreCheckStatus.ErrorMessage -eq "") {    
        & $HideErrorPanelScriptBlock
        & $TimerScriptBlock
    } else {
        & $ShowErrorPanelScriptBlock
    }
})

$UpgradeNowButton.add_click({
    
    $Form.close()
   
    # Exit 0 if user clicks Upgrade Now 
    $ExitCode = 0

    Write-ToLog "User clicked: Upgrade Now"
    
    Set-CommonExitAttributes -ExitCode $ExitCode
})

$CancelButton.add_click({

    Write-ToLog "User clicked: Cancel"

    # write to registry when user cancels the deployment
    Try {
        $NumberOfCancelledAttempts = Get-ItemPropertyValue -Path $IPURegPath -Name "NumberOfCancelledAttempts" -ErrorAction Stop
        [int]$NumberOfCancelledAttempts += 1
    } Catch {
        [int]$NumberOfCancelledAttempts = 1
    }

    Write-ToLog "NumberOfCancelledAttempts: $NumberOfCancelledAttempts"
    
    Set-Registry -Key $IPURegPath -Value 'NumberOfCancelledAttempts' -Data $NumberOfCancelledAttempts

    $ExitCode = $StartingExitCode + $PreCheckStatus.ErrorCode

    Set-CommonExitAttributes -ExitCode $ExitCode
})

$Form.Add_Closing({
    # This will preventing closing the form using Alt F4
    # Uncomment the below when running the script using ISE or any IDE
    #$_.cancel = $true
})
  
$Form.ShowDialog() | Out-Null
