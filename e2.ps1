#requires -Version 5.1

#region GLOBAL STATE

param(
    [Parameter(Mandatory = $true)][ValidateSet('add', 'delete')][string]$Action,
    [Parameter()][string]$channel_name,
    [Parameter()][string]$title,
    [Parameter()][long]$start_unix,
    [Parameter()][long]$end_unix,
    [Parameter()][string]$Description = "",
    [Parameter()][int]$AfterEvent
)

$script:Api = @{
    Info       = "/api/about"
    Epg        = "/api/epgsearch"
    CreateById = "/web/timeraddbyeventid"
    Create     = "/web/timeradd"
    Upcoming   = "/web/timerlist"
    Delete     = "/web/timerdelete"
}

$script:Config = @{}
$script:BaseUrl = ""
$script:Credential = $null
$script:LogFile = ""
$script:LogMaxMB = 1
$script:LogMaxFiles = 9
$script:ConfigUuid = ""
$script:Tolerance = 0
$script:MinLogLevel = 0
$script:Safe = @{ConfigLoaded = $false }
$script:LogLevels = @{
    DEBUG = 0
    INFO  = 1
    WARN  = 2
    ERROR = 3
}
$script:AfterEvent = $AfterEvent
if ($Action -eq "add") {
    if ($afterevent -notin 1, 2, 3) {
        $afterevent = 3
    }
}

#endregion

#region CONFIG

function Import-IniFile {
    param(
        [Parameter()][string]$Path
    )
    if (!(Test-Path $Path)) { throw "Config file not found: $Path" }
    $ini = @{}
    $section = ""
    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if ($line -match '^\s*;') { continue }
        if ($line -match '^\[(.+?)\]$') {
            $section = $matches[1]
            $ini[$section] = @{}
            continue
        }
        if ($line -match '^(.*?)=(.*)$' -and $section) {
            $ini[$section][$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $ini
}

function Init {
    param(
        [Parameter()][string]$Path
    )
    
    $script:Config = Import-IniFile $Path
    
    if (-not $script:Config.ContainsKey("Receiver")) {
        throw "Missing [Receiver] section."
    }

    if (-not $script:Config.ContainsKey("Channels")) {
        throw "Missing [Channels] section."
    }

    $script:BaseUrl = $script:Config.Receiver.Host.TrimEnd("/")

    if ($script:BaseUrl -notmatch "^http") {
        $script:BaseUrl = "http://$script:BaseUrl"
    }

    if ([string]::IsNullOrWhiteSpace($script:BaseUrl)) {
        throw "Receiver.Host missing."
    }

    $script:LogFile = $script:Config.System.logfile

    if ([string]::IsNullOrWhiteSpace($script:LogFile)) {
        $script:LogFile = "$PSScriptRoot\e2.log"
    }

    $script:Tolerance = [int]$script:Config.System.epg_tolerance

    if ($script:Tolerance -lt 0) {
        $script:Tolerance = 180
    }

    $level = "INFO"

    if ($script:Config.System.ContainsKey("loglevel")) {
        $level = $script:Config.System.loglevel.ToUpper()
    }

    if (-not $script:LogLevels.ContainsKey($level)) {
        $level = "INFO"
    }

    $script:MinLogLevel = $script:LogLevels[$level]
    $script:Safe.ConfigLoaded = $true

    $dir = Split-Path $script:LogFile

    if (!(Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    Write-Log "Configuration loaded." "DEBUG"
}

#endregion

#region LOGGING

function Initialize-LogRotation {
    param(
        [Parameter()][string]$LogFile,
        [Parameter()][int]$MaxMB = 5,
        [Parameter()][int]$MaxFiles = 5
    )
    
    if ([string]::IsNullOrWhiteSpace($LogFile)) { return }
    if (!(Test-Path $LogFile)) { return }
    
    $sizeMB = (Get-Item $LogFile).Length / 1MB
    if ($sizeMB -lt $MaxMB) { return }
    
    if (Test-Path "$LogFile.$MaxFiles") {
        Remove-Item "$LogFile.$MaxFiles" -Force
    }

    for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
        $src = "$LogFile.$i"
        $dst = "$LogFile." + ($i + 1)
        if (Test-Path $src) {
            Rename-Item $src $dst -Force
        }
    }

    Rename-Item $LogFile "$LogFile.1" -Force
}

function Write-Log {
    param(
        [Parameter()][string]$Message,
        [Parameter()][ValidateSet("DEBUG", "INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    
    if (-not $script:Safe.ConfigLoaded -and $Level -eq "DEBUG") {
        return
    }

    $levelValue = $script:LogLevels[$Level]

    if ($levelValue -lt $script:MinLogLevel) {
        return
    }

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message

    if ($script:LogFile) {
        try {
            $line | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
        }
        catch {}
    }

    if ($Host.Name -ne "ServerRemoteHost") {
        Write-Host $line
    }
}

#endregion

#region ENIGMA2 CONNECTION

function Test-e2Connection {
    
    Write-Log "Testing OpenWebif connection..." "DEBUG"
    
    try {
        
        $info = Invoke-e2Api -Path $script:Api.Info
        
        if ($null -eq $info) {
            throw "No response."
        }
    
        if ($info.enigma2) {
            Write-Log "Receiver: $($info.enigma2)" "INFO"
        }

        if ($info.webifversion) {
            Write-Log "OpenWebif: $($info.webifversion)" "INFO"
        }

        Write-Log "enigma2 connection OK." "INFO"
        return $true

    }
    catch {
    
        Write-Log "enigma2 connection FAILED." "ERROR"
        Write-Log $_.Exception.Message "ERROR"
        return $false
    
    }

}

#endregion

#region API CORE

function Test-e2XmlResult {
    param(
        [Parameter()][xml]$Response
    )
    
    if ($null -eq $Response.e2simplexmlresult) {
        return
    }

    if ($Response.e2simplexmlresult.e2state -ne "True") {
        throw $Response.e2simplexmlresult.e2statetext
    }
}

function Test-e2Result {
    param(
        [Parameter()][xml]$Response,
        [Parameter()][string]$FailText
    )
    
    if ($Response.PSObject.Properties.Match("result").Count) {
        if ($Response.result -ne $true) {
            if ($Response.PSObject.Properties.Match("message").Count) {
                throw $Response.message
            }
            else {
                throw $FailText
            }
        }
    }
}

function Invoke-e2Api {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][hashtable]$Query
    )
    
    if (-not $script:Safe.ConfigLoaded) {
        throw "Configuration not initialized."
    }

    $url = "$($script:BaseUrl)$Path"

    if ($Query -and $Query.Count) {
        $qs = ($Query.GetEnumerator() | Sort-Object Key | ForEach-Object {
                "$($_.Key)=$([System.Uri]::EscapeDataString([string]$_.Value))"
            }) -join "&"
        $url = "{0}?{1}" -f $url, $qs
    }

    Write-Log ("BaseUrl: '{0}' | Path: '{1}' | Url: '{2}'" -f $script:BaseUrl, $Path, $Url) "DEBUG"

    try {
    
        if ($Path.StartsWith("/api/")) {
            $response = Invoke-RestMethod -Uri $url -Method Get -ContentType "application/json" -TimeoutSec 4
        }
        elseif ($Path.StartsWith("/web/")) {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
        
            try {
                $bytes = $wc.DownloadData($url)
            }
            finally {
                $wc.Dispose()
            }
    
            $xmlText = [System.Text.Encoding]::UTF8.GetString($bytes)
            $response = [xml]$xmlText
        }
        else {
            throw "Path '" + $Path + "' not start with '/api/' or '/web/'."
        }

        if ($null -eq $response) {
            throw "Receiver returned no data."
        }

        if ($response -is [xml]) {
            Test-e2XmlResult $response
        }
        else {
    
            if ($response.PSObject.Properties.Match("result").Count) {
                if ($response.result -ne $true) {
                    if ($response.PSObject.Properties.Match("message").Count) {
                        throw $response.message
                    }
                    else {
                        throw "OpenWebif returned an error."
                    }
                }
            }
        }

        Write-Log "HTTP GET successful." "DEBUG"
        return $response

    }
    catch {
    
        if ($_.Exception.Response) {
            try {
                Write-Log ("HTTP Status {0}" -f [int]$_.Exception.Response.StatusCode) "ERROR"
            }
            catch {}
        }
    
        Write-Log "E2-API ERROR $Path : $($_.Exception.Message)" "ERROR"
        throw
    }
}

#endregion

#region EPG OPERATIONS

function Find-EpgEvent {
    param(
        [Parameter(Mandatory = $true)][string]$searchPhrase,
        [Parameter(Mandatory = $true)][long]$startTime
    )
    
    if ([string]::IsNullOrWhiteSpace($searchPhrase)) { throw "Search phrase missing." }
    
    Write-Log "Searching EPG '$searchPhrase'" "DEBUG"
    
    $res = Invoke-e2Api -Path $script:Api.Epg -Query @{search = $searchPhrase }
    
    if ($null -eq $res) {
        Write-Log "EPG search returned no response." "WARN"
        return $null
    }

    if (-not $res.PSObject.Properties.Match("events").Count) {
        Write-Log "Response contains no events property." "WARN"
        return $null
    }

    if ($null -eq $res.events -or $res.events.Count -eq 0) {
        Write-Log "No EPG events found." "INFO"
        return $null
    }

    $cfgSRef = $script:Config.Channels[$channel_name]

    $epgEvent = $res.events | Where-Object {
        $_.sref -eq $cfgSRef -and
        [math]::Abs($_.begin_timestamp - $startTime) -le $script:Tolerance
    } | Select-Object -First 1

    if ($null -eq $epgEvent) {
        Write-Log "No matching EPG event inside tolerance." "INFO"
        return $null
    }

    if (-not $epgEvent.PSObject.Properties.Match("id").Count) {
        Write-Log "Matching EPG event has no eventId." "WARN"
        return $null
    }

    if (-not $epgEvent.PSObject.Properties.Match("sref").Count) {
        $epgEvent | Add-Member -NotePropertyName sref -NotePropertyValue $script:Config.Channels[$channel_name]
    }

    Write-Log ("EPG match: '{0}' eventId={1} sref={2} start={3}" -f $epgEvent.title, $epgEvent.id, $epgEvent.sref, $epgEvent.begin_timestamp) "DEBUG"

    return $epgEvent
}

#endregion

#region DVR OPERATIONS

function New-RecordingByEventId {
    param(
        [Parameter(Mandatory = $true)][string]$sRef,
        [Parameter(Mandatory = $true)][long]$epgEventId
    )
    
    Write-Log ("Creating DVR timer eventId={0} sRef={1}" -f $epgEventId, $sRef) "DEBUG"
    
    $res = Invoke-e2Api -Path $script:Api.CreateById -Query @{sRef = $sRef; eventid = $epgEventId; afterevent = $script:AfterEvent }
    
    if ($null -eq $res) { throw "Timer creation returned no response." }
    
    Test-e2Result -Response $res -FailText "OpenWebif rejected timer creation."
    
    Write-Log "Recording successfully created." "INFO"
    return $res
}

function New-Recording {
    param(
        [Parameter(Mandatory = $true)][string]$sRef,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][long]$Begin,
        [Parameter(Mandatory = $true)][long]$End,
        [Parameter()][string]$Description = ""
    )
    
    Write-Log ("Creating DVR timer '{0}' begin={1} end={2} sRef={3}" -f $Title, $Begin, $End, $sRef) "DEBUG"
    
    $res = Invoke-e2Api -Path $script:Api.Create -Query @{sRef = $sRef; begin = $Begin; end = $End; name = $Title; description = $Description; disabled = 0; justplay = 0; afterevent = $script:AfterEvent; repeated = 0; eit = 0; dirname = ""; tags = "" }
    
    if ($null -eq $res) { throw "Timer creation returned no response." }
    
    Test-e2Result -Response $res -FailText "OpenWebif rejected timer creation."
    
    Write-Log "Recording successfully created." "INFO"
    return $res
}

function Get-UpcomingRecordings {
    Write-Log "Loading upcoming recordings..." "DEBUG"
    
    $res = Invoke-e2Api -Path $script:Api.Upcoming
    
    if ($null -eq $res) { throw "Timer list returned no response." }
    
    if ($null -eq $res.e2timerlist) {
        throw "e2timerlist missing in OpenWebif response."
    }

    $timers = @($res.e2timerlist.e2timer)

    Write-Log ("Loaded {0} upcoming timers." -f $timers.Count) "DEBUG"

    return $timers
}

function Search-UpcomingRecordings {
    param(
        [Parameter(Mandatory = $true)]$Upcoming,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$ChannelName,
        [Parameter(Mandatory = $true)][long]$startTime,
        [Parameter()][long]$endTime
    )
    
    Write-Log ("Searching timer '{0}' on '{1}'." -f $Title, $ChannelName) "DEBUG"
    
    $cfgSRef = $script:Config.Channels[$ChannelName]
    
    foreach ($entry in @($Upcoming)) {
        
        if ($null -eq $entry) {
            continue
        }
    
        Write-Log ("Timer candidate: name='{0}' service='{1}' begin={2} end={3}" -f $entry.e2name, $entry.e2servicename, $entry.e2timebegin, $entry.e2timeend) "DEBUG"
    
        $titleMatch = $entry.e2name.Equals($Title, [System.StringComparison]::OrdinalIgnoreCase)
    
        $channelMatch = ($entry.e2servicereference -eq $cfgSRef)
    
        $startMatch = ([math]::Abs([long]$entry.e2timebegin - $startTime) -le $script:Tolerance)
    
        if ($titleMatch -and $channelMatch -and $startMatch) {
            Write-Log ("Matching timer found: '{0}'" -f $entry.e2name) "DEBUG"
            return $entry
        }
    }

    Write-Log "No matching timer found." "DEBUG"
    return $null
}

function Remove-Recording {
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$sRef,
        [Parameter(Mandatory = $true)][long]$startTime,
        [Parameter(Mandatory = $true)][long]$endTime
    )
    
    Write-Log ("Deleting timer begin={0} end={1}" -f $startTime, $endTime) "DEBUG"
    
    $res = Invoke-e2Api -Path $script:Api.Delete -Query @{sRef = $sRef; begin = $startTime; end = $endTime }
    
    if ($null -eq $res) { throw "Timer delete returned no response." }
    
    Test-e2Result -Response $res -FailText "OpenWebif rejected timer deletion."
    
    Write-Log "Recording successfully deleted." "INFO"
    return $true
}

#endregion

#region MAIN

try {
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    Init "e2-config.ini"
    
    Initialize-LogRotation -LogFile $script:LogFile -MaxMB $script:LogMaxMB -MaxFiles $script:LogMaxFiles
    
    if (-not $script:Safe.ConfigLoaded) {
        throw "Configuration not loaded."
    }

    if ([string]::IsNullOrWhiteSpace($channel_name)) {
        throw "Parameter channel_name missing."
    }

    if (-not $script:Config.Channels.ContainsKey($channel_name)) {
        throw "Channel '$channel_name' not configured in e2-config.ini."
    }

    $sRef = $script:Config.Channels[$channel_name]

    if ([string]::IsNullOrWhiteSpace($sRef)) {
        throw "No service reference configured for '$channel_name'."
    }

    $startTime = $start_unix
    $endTime = 0
    if ($end_unix -gt 0) {
        $endTime = $end_unix
    }

    if ([string]::IsNullOrWhiteSpace($Description)) {
        Write-Log "Parameter description missing." "INFO"
    }
    else {
        $Description = $Description -replace "(`r`n|`n|`r)", " "
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        throw "Parameter 'title' missing."
    }
    else {
        $searchPhrase = $title
    }

    Write-Log ("Action      : {0}" -f $Action) "DEBUG"
    Write-Log ("Title       : {0}" -f $title) "DEBUG"
    Write-Log ("Channel     : {0}" -f $channel_name) "DEBUG"
    Write-Log ("sRef        : {0}" -f $sRef) "DEBUG"
    Write-Log ("Start       : {0}" -f $startTime) "DEBUG"
    Write-Log ("End         : {0}" -f $endTime) "DEBUG"
    Write-Log ("Description : {0}" -f $Description) "DEBUG"
    Write-Log ("AfterEvent  : {0}" -f $script:AfterEvent) "DEBUG"

    Write-Log ("InputEncoding : {0}" -f [Console]::InputEncoding.EncodingName) "DEBUG"
    Write-Log ("OutputEncoding: {0}" -f [Console]::OutputEncoding.EncodingName) "DEBUG"
    Write-Log ("Default       : {0}" -f [System.Text.Encoding]::Default.EncodingName) "DEBUG"

    if (-not (Test-e2Connection)) {
        exit 1
    }

    switch ($Action) {
        "add" {
            Write-Log "Searching EPG event..." "INFO"
        
            $epgEvent = Find-EpgEvent -searchPhrase $searchPhrase -startTime $start_unix
        
            if ($null -ne $epgEvent) {
            
                if ([string]::IsNullOrWhiteSpace($epgEvent.sref)) {
                    $epgEvent.sref = $sRef
                }
        
                Write-Log ("EPG event found: id={0} title='{1}'" -f $epgEvent.id, $epgEvent.title) "DEBUG"
        
                #kein Padding berechnen (macht Enigma2).
                $result = New-RecordingByEventId -sRef $epgEvent.sref -eventId $epgEvent.id
        
                if ($result.PSObject.Properties.Match("message").Count) {
                    Write-Log $result.message "INFO"
                }
    
                Write-Log ("DVR added via timeraddbyeventid:: '{0}' EventID={1}" -f $title, $epgEvent.id) "INFO"
            }
            else {
                Write-Log ("Event not found: '{0}' on '{1}'. Falling back to timeradd." -f $title, $channel_name) "WARN"
    
                #Padding selbst berechnen.
                $startTime = $start_unix - [int]$script:Config.Timer.PrePadding
                $endTime = $end_unix + [int]$script:Config.Timer.PostPadding
    
                $result = New-Recording -sRef $sRef -Title $title -Begin $startTime -End $endTime -Description $Description
    
                Write-Log ("DVR added via timeradd: '{0}'" -f $title) "INFO"
            }
        }
        "delete" {
            Write-Log "Loading upcoming recordings..." "INFO"
    
            $upcoming = Get-UpcomingRecordings
    
            if ($null -eq $upcoming) {
                Write-Log "No response received from timer list." "WARN"
                break
            }

            if ($upcoming.Count -eq 0) {
                Write-Log "No upcoming recordings found." "WARN"
                break
            }

            Write-Log ("Found upcoming timers.") "DEBUG"

            #Padding selbst berechnen.
            $startTime = $start_unix - [int]$script:Config.Timer.PrePadding
            $endTime = $end_unix + [int]$script:Config.Timer.PostPadding

            $entry = Search-UpcomingRecordings -Upcoming $upcoming -Title $title -ChannelName $channel_name -startTime $startTime -endTime $endTime

            if ($null -eq $entry) {
                Write-Log ("Recording not found: '{0}' on '{1}'." -f $title, $channel_name) "WARN"
                break
            }

            Write-Log ("Recording found: '{0}' Begin={1} End={2}" -f $entry.e2name, $entry.e2timebegin, $entry.e2timeend) "DEBUG"

            $deleteSRef = $sRef

            if ($entry.PSObject.Properties.Match("e2servicereference").Count) {
                if (-not [string]::IsNullOrWhiteSpace($entry.e2servicereference)) {
                    $deleteSRef = $entry.e2servicereference
                }
            }

            if (Remove-Recording -sRef $deleteSRef -startTime $entry.e2timebegin -endTime $entry.e2timeend) {
                Write-Log ("DVR deleted '{0}' from '{1}'." -f $title, $channel_name) "INFO"
            }
        }
        default {
            throw "Unknown action '$Action'."
        }
    }
    $stopwatch.Stop()
    Write-Log ("Runtime: {0:N2} seconds" -f $stopwatch.Elapsed.TotalSeconds) "INFO"
    Write-Log "e2.ps1 finished successfully." "DEBUG"
    exit 0
}
catch {
    try {
        Write-Log "e2.ps1 aborted." "ERROR"
        Write-Log ("FATAL: {0}" -f $_.Exception.Message) "ERROR"
    }
    catch {}
    Write-Output ("ERROR, check logfile: " + $script:LogFile)
    exit 1
}

#endregion
