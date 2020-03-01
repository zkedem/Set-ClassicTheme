[CmdletBinding()]

param (
    [switch]$Enable,
    [switch]$Disable,
    [switch]$GUI,
    [string]$FilePath,
    # ArgumentList is given a default value of " ", otherwise Start-Process won't work.
    [string[]]$ArgumentList = " "
)

#region Core Functionality
<#
Get SID for current user.
This is distinct from the current session ID mentioned below.
#>
function Get-CurrentUserSID {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    return ([System.DirectoryServices.AccountManagement.UserPrincipal]::Current).SID.Value
}

<#
Get current session ID.
For each session, ThemeSection is located in \Session\<session ID>\Windows.
#>
function Get-CurrentSessionID {
    return (Get-Process -PID $pid).SessionID
}

# Get ThemeSection for current user.
function Get-ThemeSection {
    return Get-NtSection ("\Sessions\" + (Get-CurrentSessionID) + "\Windows\ThemeSection")
}

# Get ThemeSection's security descriptor.
function Get-ThemeSectionSD {
    $obj = Get-ThemeSection
    return $obj.SecurityDescriptor
}

# Generate partial SDDL security descriptor to deny current user read/query access.
function Get-RQPermissions {
    return "(D;;CCLC;;;$(Get-CurrentUserSID))"
}

# Is the Classic theme switched on at the moment?
function Is-Enabled {
    $permissions = Get-RQPermissions
    return (Get-ThemeSectionSD).ToSddl().Contains($permissions)
}

function Enable-ClassicTheme {
    # If the Classic theme hasn't already been activated...
    if (!(Is-Enabled)) {
        # Find where to insert our permissions.
        $splice = (Get-ThemeSectionSD).ToSddl().IndexOf(":(") + 1
        # Create new security descriptor based on the original.
        $permissions = Get-RQPermissions
        $sd = New-NtSecurityDescriptor (Get-ThemeSectionSD).ToSddl().Insert($splice, $permissions)
        # Set ThemeSection's descriptor to our new one.
        $obj = Get-ThemeSection
        Set-NtSecurityDescriptor $obj $sd Dacl
    }
}

function Disable-ClassicTheme {
    # If the Classic theme is already activated...
    if (Is-Enabled) {
        # Find out where our permissions are, so we can remove them.
        $permissions = Get-RQPermissions
        $splice = (Get-ThemeSectionSD).ToSddl().IndexOf($permissions)
        $to = $permissions.Length
        # Recover and restore original security descriptor.
        $sd = New-NtSecurityDescriptor (Get-ThemeSectionSD).ToSddl().Remove($splice, $to)
        $obj = Get-ThemeSection
        Set-NtSecurityDescriptor $obj $sd Dacl
    }
}

# Do we have admnistrative permissions?
function Is-Admin {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $user).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# Elevate this script if not started as Administrator.
function Elevate-Self {
    Start-Process powershell.exe "-File",('"{0}"' -f $ScriptPath),"$parameters" -Verb RunAs -Wait -WindowStyle Hidden
}
#endregion Core Functionality

#region GUI
# Derive an aliased app's name from that of the corresponding registry key.
function Get-ExecName {
    param (
        $key,
        [string]$AppPaths
    )

    return "$key".Replace($AppPaths.Replace("HKLM:", "HKEY_LOCAL_MACHINE"), "")
}

# Determine whether registry key represents a blacklisted app.
function Is-Blacklisted {
    param (
        $key,
        [string]$InterceptPath,
        [string]$ExecName
    )

    return (Get-ItemPropertyValue -Path "$key".Replace("HKEY_LOCAL_MACHINE", "HKLM:") -Name "(default)").Contains("$InterceptPath$ExecName.cmd")
}

# Test Classic theme by opening a WScript.Shell popup in a new job.
function Test-Theme {
    param ($form)

    # Disable test button so only one popup window at a time can be opened.
    $buttonTest.IsEnabled = $false
    # Start new job w/info popup.
    Start-Job -ScriptBlock {
        $wshell = New-Object -ComObject Wscript.Shell -ErrorAction Stop
        $wshell.Popup(@"
You should be seeing the Classic window borders right now.
If not, select "Enable Classic theme" and try again.
"@, 0, "Classic Theme GUI", 64) | Out-Null
    } -Name "TestWindow"
    # Wait until user closes window.
    Wait-Job -Name "TestWindow"
    # Re-enable test button.
    $buttonTest.IsEnabled = $true
}

# Show error message using Wscript.Shell.
function Show-ErrorMessage {
    param ([string]$message)

    $wshell = New-Object -ComObject Wscript.Shell -ErrorAction Stop
    $wshell.Popup($message, 0, "Classic Theme GUI", 16) | Out-Null
}

# Apply settings selected by user in the GUI.
function Apply-GUISettings {
    param (
        $form,
        [string]$AppPaths,
        [string]$InterceptPath
    )

    # Disable form while applying settings to avoid invalid input.
    $form.IsEnabled = $false
    # For each key amongst the app execution aliases:
    foreach ($key in Get-ChildItem $AppPaths) {
        $ExecName = Get-ExecName $key $AppPaths
        # The try/catch block is for silencing unrelated errors.
        try {
            if (Is-Blacklisted $key $InterceptPath $ExecName) {
                # Remove app name and batch file if absent from the ListView.
                if (!($listView.Items.Contains($ExecName))) {
                    Remove-Item -Path "$AppPaths$ExecName" -Recurse
                    Remove-Item "$InterceptPath$ExecName.cmd"
                }
            }
        }
        catch {}
    }
    # For each app in the ListView:
    foreach ($ExecName in $listView.Items) {
        # If not already in blacklist:
        if (!(Get-Item -Path "$AppPaths$ExecName" -ErrorAction SilentlyContinue)) {
            <#
            Since we can't start an app directly, we create a batch file to do so.
            The batch file passes the app name to this script as a parameter.
            Then we make the registry alias point to that batch file.
            #>
            if (!(Test-Path -LiteralPath $InterceptPath)) {
                # Create directory for batch files if absent.
                try {
                    New-Item $InterceptPath -ItemType Directory -ErrorAction Stop | Out-Null
                }
                catch {
                    Show-ErrorMessage "Could not create directory $InterceptPath."
                    break
                }
            }
            New-Item "$InterceptPath$ExecName.cmd"
            New-Item "$AppPaths$ExecName"
            Set-Content -Path "$InterceptPath$ExecName.cmd" -Value "@powershell.exe -WindowStyle Hidden -Command `"$ScriptName -FilePath $ExecName`""
            Set-ItemProperty -Path "$AppPaths$ExecName" -Name "(default)" -Value "$InterceptPath$ExecName.cmd"
        }
    }
    # Enable/disable Classic theme per user's selection.
    if ($radioButtonEnable.IsChecked) {
        Enable-ClassicTheme
    }
    elseif ($radioButtonDisable.IsChecked) {
        Disable-ClassicTheme
    }
    # Re-enable form.
    $form.IsEnabled = $true
}

# Start the WPF-based GUI.
function Start-GUI {
    # The GUI is loaded from an XAML file in the same directory as the script.
    $RawXaml = @"
    $(try {
        Get-Content .\MainWindow.xaml -Raw -ErrorAction Stop
    }
    catch {
        Show-ErrorMessage "Failed to locate user interface."
        exit
    })
"@
    # PowerShell doesn't support certain properties, so we'll remove those.
    $RawXaml = $RawXaml -replace 'x:','' -replace 'Class=.*','' -replace 'mc:.*',''
    # Place XAML contents into new XML object.
    [xml]$xaml = $RawXaml
    # Loading in the GUI.
    Add-Type -AssemblyName PresentationFramework
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    try {
        $form = [Windows.Markup.XamlReader]::Load($reader)
    }
    catch {
        # If the file contains invalid data:
        Show-ErrorMessage "Failed to load user interface."
        exit
    }
    # Enumerating the UI elements.
    $xaml.SelectNodes("//*[@Name]") | % {Set-Variable -Name ($_.Name) -Value $form.FindName($_.Name)}

        #region GUI Functionality
            
            #region Theme Settings
            # Set RadioButtons according to theme status.
            if (Is-Enabled) {
                $radioButtonEnable.IsChecked = $true
            }
            elseif (!(Is-Enabled)) {
                $radioButtonDisable.IsChecked = $true
            }
            # Test button initiates a simple test of whether the Classic theme is active.
            $buttonTest.Add_Click({Test-Theme $form})
            #endregion Theme Settings
            
            #region App Blacklist
            # Path to app execution aliases in registry (using drive provider):
            $AppPaths = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\"
            # Path to interception batch files:
            $InterceptPath ="$PWD\Blacklist\"
            foreach ($key in Get-ChildItem $AppPaths) {
                $ExecName = Get-ExecName $key $AppPaths
                # The try/catch block is for silencing unrelated errors.
                try {
                    if (Is-Blacklisted $key $InterceptPath $ExecName) {
                        # Place blacklisted apps in the ListView.
                        Write-Output $ExecName | % {$listView.AddChild($_)}
                    }
                }
                catch {}
            }
            # Add button adds TextBox contents to ListView, then clears TextBox.
            $buttonAdd.Add_Click({
                if ($textBoxExecName.Text.length -gt 0) {
                    Write-Output $textBoxExecName.Text | % {$listView.AddChild($_)}
                    $textBoxExecName.Text = ""
                }
            })
            # Remove button removes selected items from ListView.
            $buttonRemove.Add_Click({$listView.Items.Remove($listView.SelectedItem)})
            #endregion App Blacklist
            
            #region Main Buttons
            # OK button saves settings and closes window.
            $buttonOK.Add_Click({
                Apply-GUISettings $form $AppPaths $InterceptPath
                $form.Close()
            })
            # Cancel button closes window.
            $buttonCancel.Add_Click({$form.Close()})
            # Apply button saves settings.
            $buttonApply.Add_Click({Apply-GUISettings $form $AppPaths $InterceptPath})
            #endregion Main Buttons

        #endregion GUI Functionality

    # Shows the GUI.
    $form.ShowDialog() | Out-Null
}
#endregion GUI

#region Compatibility
<# 
This is for apps that break under the Classic theme.
The idea is that these apps would have a registry alias such that they always start using this script.
If the Classic theme is enabled, it will be temporarily disabled so the app can start.
If not, it'll just start without affecting anything else.
#>
function Start-FaultyApp {
    # We cannot alter the Classic theme state unless running as Administrator.
    if (Is-Admin) {
        Disable-ClassicTheme
    }
    # Start the app w/command-line arguments (if any).
    Start-Process -FilePath "$FilePath" -ArgumentList "$ArgumentList" -Wait
    # Re-enable Classic theme.
    if (Is-Admin) {
        Enable-ClassicTheme
    }
}
#endregion Compatibility

#region Startup
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptName = $MyInvocation.MyCommand.Name
$parameters = $PSBoundParameters.Keys | % { ('-' + $_), $PSBoundParameters.Item($_) }
# If no parameters, show help.
if ($parameters.Length -eq 0) {
    Get-Help $ScriptPath
}
elseif (Is-Admin) {
    if ($Enable) {
        Enable-ClassicTheme
    }
    elseif ($Disable) {
        Disable-ClassicTheme
    }
    elseif ($GUI) {
        # Since the GUI resources are in the same place as the script, we have to make that our working directory.
        $StartPath = $PWD
        Set-Location $ScriptPath.Remove($ScriptPath.IndexOf($ScriptName))
        Start-GUI
        # When finished, return to starting directory.
        Set-Location $StartPath
    }
    elseif ($FilePath.length -gt 0) {
        Start-FaultyApp
    }
}
# Start app when Classic theme is disabled without requiring administartive privileges.
elseif ($FilePath.length -gt 0 -and !(Is-Enabled)) {
    Start-FaultyApp
}
# The last possible condition is if a normal user tries one of the above operations which need elevation.
else {
    Elevate-Self
}
#endregion Startup