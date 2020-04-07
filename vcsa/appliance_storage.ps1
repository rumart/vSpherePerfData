#Requires -Version 6.0
<#
    .SYNOPSIS
        Script for outputting vCenter storage info to Influx
    .DESCRIPTION
        This script will fetch the storage utilization from 
        the vCenter REST API and post this data to a InfluxDB database.

        The script will fetch the 30 minute interval.
        
        This script is tested against vCenter 6.7U3, please note that 
        there might be differences in other versions
        Note that this script is developed with PS Core and uses functionality
        not present in the desktop version of PS (v 5>=). A different version of the
        script that uses PS 5 can be found here, https://github.com/rumart/vmug-norway-dec-18
    .NOTES
        Author: Rudi Martinsen
        Created: 28/11-2018
        Version: 2.1.0
        Revised: 05/04-2020
        Changelog:
        2.1.0 -- Added multiple vCenter support
        2.0.0 -- BREAKING CHANGE: Ported to PS core, v6+ required
    .LINK
        https://www.rudimartinsen.com/2018/12/03/vsphere-performance-vcenter-server-appliance-vcsa-monitoring/
#>
#Function for generating correct timestamp for influx input
function Get-DBTimestamp($timestamp = (get-date)){
    if($timestamp -is [system.string]){
        $timestamp = [datetime]::ParseExact($timestamp,'dd.MM.yyyy HH:mm:ss',$null)
    }
    return $([long][double]::Parse((get-date $($timestamp).ToUniversalTime() -UFormat %s)) * 1000 * 1000 * 1000)
}


########################
## Environment params ##
########################
$vcenters = "<vcenter-server-1>","<vcenter-server-1>"
$username = "<your-vcenter-user>"
$pass = "<your-password>"

$database = "<your-influx-dbname>"
$influxServer = "<your-influx-server>"
$influxPort = 8086

################
## End params ##
################

#Create array for storing data
$tbl = @()

foreach($vcenter in $vcenters){

    $BaseUri = "https://$vcenter/rest/"

    #Authenticate to vCenter
    $SessionUri = $BaseUri + "com/vmware/cis/session"
    $auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($UserName+':'+$Pass))
    $header = @{
    'Authorization' = "Basic $auth"
    }
    $token = (Invoke-RestMethod -Method Post -Headers $header -Uri $SessionUri -SkipCertificateCheck).Value
    $sessionheader = @{'vmware-api-session-id' = $token}

    #Build string of metrics to pull
    $metrics = @(
        "storage.totalsize.filesystem.db"
        "storage.used.filesystem.db"
        "storage.totalsize.filesystem.dblog"
        "storage.used.filesystem.dblog"
        "storage.totalsize.filesystem.log"
        "storage.used.filesystem.log"
        "storage.totalsize.filesystem.root"
        "storage.used.filesystem.root"
        "storage.totalsize.filesystem.seat"
        "storage.used.filesystem.seat"
        "storage.totalsize.filesystem.updatemgr"
        "storage.used.filesystem.updatemgr"
        "storage.totalsize.filesystem.core"
        "storage.used.filesystem.core"
    )

    $count = 1
    $string = ""
    foreach($met in $metrics){
        $string += "&item.names.$count=$met"
        $count++
    }

    #Set start/end timestamps for use in the endpoint queries
    $end = (Get-Date).AddMinutes(-5).ToUniversalTime()
    $start = $end.AddMinutes(-5)
    $endTime = Get-Date $end -Format "yyyy-MM-ddTHH\:mm\:ss.fffZ"
    $startTime = Get-Date $start -Format "yyyy-MM-ddTHH\:mm\:ss.fffZ"

    #Build URI with timestamps and metrics string
    $uri = $BaseUri + "appliance/monitoring/query?item.interval=MINUTES30&item.function=MAX&item.start_time=$startTime&item.end_time=$endTime$string"

    #Fetch data
    $response = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $uri -SkipCertificateCheck

    #Iterate through metrics
    foreach($stat in $response.value){
        
        #Set timestamp
        $timestamp = Get-DBTimestamp (get-date $stat.end_time)

        #Select the latest value
        $storageVal = ($stat.data[-1] / 1024)

        #Set measurement and field names
        switch($stat.name){
            "storage.totalsize.filesystem.db" {$measurement = "storage.db"; $field = "totalsize"}
            "storage.used.filesystem.db" {$measurement = "storage.db"; $field = "used"}
            "storage.totalsize.filesystem.dblog" {$measurement = "storage.dblog"; $field = "totalsize"}
            "storage.used.filesystem.dblog" {$measurement = "storage.dblog"; $field = "used"}
            "storage.totalsize.filesystem.seat" {$measurement = "storage.seat"; $field = "totalsize"}
            "storage.used.filesystem.seat" {$measurement = "storage.seat"; $field = "used"}
            "storage.totalsize.filesystem.core" {$measurement = "storage.core"; $field = "totalsize"}
            "storage.used.filesystem.core" {$measurement = "storage.core"; $field = "used"}
            "storage.totalsize.filesystem.log" {$measurement = "storage.log"; $field = "totalsize"}
            "storage.used.filesystem.log" {$measurement = "storage.log"; $field = "used"}
            "storage.totalsize.filesystem.root" {$measurement = "storage.root"; $field = "totalsize"}
            "storage.used.filesystem.root" {$measurement = "storage.root"; $field = "used"}
            "storage.totalsize.filesystem.updatemgr" {$measurement = "storage.updatemgr"; $field = "totalsize"}
            "storage.used.filesystem.updatemgr" {$measurement = "storage.updatemgr"; $field = "used"}
        }

        #Add data to array
        $tbl += "$measurement,server=$vcenter,interval=$($stat.interval),unit=MB $field=$storageVal $timestamp"

    }
}

#Post data to Influx API
$postUri = "http://$influxServer" + ":$influxPort/write?db=$database"
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n") 
