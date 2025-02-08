param (
    [Parameter()]
    $MonitorProcessInfo = $false,
    [Parameter()]
    $OutputDetailedInfo = $false,
    [Parameter(Mandatory = $true,
        ValueFromRemainingArguments = $true)]
    [ValidateNotNullOrEmpty()]
    $PackageName
)

$ErrorActionPreference = "Stop"

$baseProtocol = "https:"
$baseHostName = "marketplace.visualstudio.com"

$Uri = "$($baseProtocol)//$($baseHostName)/items?itemName=$PackageName"
$TempGuid = [guid]::NewGuid()
$VsixDir = $env:TEMP
$VsixLocation = "$($VsixDir)\$($TempGuid).vsix"
Write-Output "logs-path-match=$($VsixDir)\dd_*.log" >> $env:GTHUB_OUTPUT

$VSInstallDir = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\resources\app\ServiceHub\Services\Microsoft.VisualStudio.Setup.Service"

if (-Not $VSInstallDir) {
    Write-Error "Visual Studio install directory is missing"
    Exit 1
}
Write-Host "Grabbing VSIX extension at $($Uri)"
$HTML = Invoke-WebRequest -Uri $Uri -UseBasicParsing -SessionVariable session

Write-Host "Attempting to download $PackageName..."
$anchor = $HTML.Links |
Where-Object { $_.class -eq 'install-button-container' } |
Select-Object -ExpandProperty href
if (-Not $anchor) {
    Write-Error "Could not find download anchor tag on the Visual Studio Extensions page"
    Exit 1
}
Write-Host "Anchor is $($anchor)"
$href = "$($baseProtocol)//$($baseHostName)$($anchor)"
Write-Host "Href is $($href)"
Invoke-WebRequest $href -OutFile $VsixLocation -WebSession $session

if (-Not (Test-Path $VsixLocation)) {
    Write-Error "Downloaded VSIX file could not be located"
    Exit 1
}
Write-Host "VSInstallDir is $($VSInstallDir)"
Write-Host "VsixLocation is $($VsixLocation)"

Write-Host "Initializing log file monitoring..."
Install-Module -Name FSWatcherEngineEvent
# Date format is yyyyMMddHHmmss
$LogFileNameIncludes = @( "dd_VSIXInstaller_*" )
if ($OutputDetailedInfo) { $LogFileNameIncludes += "dd_setup*.log" }
else { $LogFileNameIncludes += "dd_setup_*_errors.log" }
$LogFileReaders = @{}

function FSWatcherEventAction($FSWEvent) {
    $FileName = $FSWEvent.MessageData.Name
    Write-Debug "File event: $($FileName)"

    foreach ($item In $LogFileNameIncludes) {
        if (($FileName -like $item) -and (!$LogFileReaders.ContainsKey($FileName))) {
            Write-Debug "Returning new matching and unopened file."
            return $FileName
        }
    }
}

Write-Host "Connecting file monitor event handler..."
# https://github.com/wgross/fswatcher-engine-event/blob/main/README.md
$WatcherJob = New-FileSystemWatcher -SourceIdentifier "VSIXLogFileMonitor" -Path $VsixDir -Filter "dd_*.log" -Action { FSWatcherEventAction $event }

Write-Host "Installing $PackageName..."
$proc = Start-Process -Filepath "$($VSInstallDir)\VSIXInstaller" -ArgumentList "/q $($VsixLocation)" -PassThru

while ($proc.HasExited -eq $false) {
    # Check if the watcher job has encountered an error and pass it along
    if ($WatcherJob.JobStateInfo.State.HasFlag([System.Management.Automation.JobState]::Failed)) {
        throw $WatcherJob.Error[0].Exception
    }

    # Check if new file to watch was returned
    $watcherJobOut = Receive-Job -Job $WatcherJob
    if ($watcherJobOut) {
        Write-Debug "Received output from watcher job!" ; $watcherJobOut
        # Sometimes an array might be returned (works for single objects too)
        $watcherJobOut | ForEach-Object {
            if (!($LogFileReaders.ContainsKey($_))) {
                # Open file for reading, using a workaround that gives us the most permissive sharing & access.
                $LogFileReaders[$_] = New-Object System.IO.StreamReader ( New-Object System.IO.FileStream(
                        "$($VsixDir)\$($_)", [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite))
                Write-Host "Opened $($_) for reading."
            }
            else { Write-Debug "Attempted to open a duplicate streamreader!"}
        }
    }

    # Iterate through all streamreaders and read-out to the end of the buffer
    $LogFileReaders.GetEnumerator() | ForEach-Object {
        if (!$_.Value.EndOfStream) {
            Write-Host "[$($_.Key)] bytes $($_.Value.BaseStream.Position) to $($_.Value.BaseStream.Length)"
            while (!$_.Value.EndOfStream) { Write-Host $_.Value.ReadToEnd() }
            Write-Host "[End of stream]`r`n"
        }
    }

    if ($MonitorProcessInfo) { Write-Host ($proc | Format-Table | Out-String) }

    Start-Sleep 1
}

Write-Host "Process exited."

Write-Host "Cleanup..."

Remove-FileSystemWatcher -SourceIdentifier "VSIXLogFileMonitor"
Remove-Item $VsixLocation
$LogFileReaders.GetEnumerator() | ForEach-Object {
    Write-Debug "Closing file $($_.Key)"
    $_.Value.Close()
}

if ($proc.ExitCode -ne 0) {
    Write-Host "Error encountered: $($proc.ExitCode)"
    Write-Host (Select-String -Path $env:temp\dd_setup_*_errors.log -Pattern "^.*Exception.*$")
}
else {
    Write-Host "Installation of $PackageName complete!"
}

if ($env:GITHUB_WORKSPACE) {
    exit $proc.ExitCode
}
else {
    Write-Host "Simulated exit code $($proc.ExitCode)"
}