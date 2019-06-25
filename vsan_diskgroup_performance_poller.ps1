<#
    .SYNOPSIS
        Script for pulling performance metrics from vCenter VSAN diskgroups and writing to an Influx database
    .DESCRIPTION
        The script will pull performance metrics for VSAN Diskgroups from vCenter and writes to an Influx
        timeseries database.
    .NOTES
        Author: Rudi Martinsen / Intility AS
        Created: 02/04-2018
        Version 0.2.0
        Revised: 25/06-2019
        Changelog:
        0.2.0 -- Support for multiple clusters
        0.1.1 -- Cleaned unused variables
        0.1.0 -- Fork from Host poller
    .LINK
        http://www.rudimartinsen.com/2018/04/06/vsphere-performance-data-monitoring-vmware-vsan-performance/       
    .PARAMETER VCenter
        The vCenter to connect to
    .PARAMETER Cluster
        The Cluster to get stats from. If omitted all VSAN clusters in the vCenter will be fetched
    .PARAMETER Targetname
        Optional name of the target for use as a Tag in the Influx record
    .PARAMETER DBServer
        IP Address or hostname of the Influx Database server
    .PARAMETER DBServerPort
        TCP port for the DB server, Defaults to 8086 which is the default Influx port
    .PARAMETER LogFile
        Path to the logfile to write to
#>
param(
    [Parameter(Mandatory=$true)]
    $VCenter,
    [Parameter(Mandatory=$false)]
    $Cluster,
    $Targetname,
    $Dbserver,
    $DbserverPort = 8086,
    $LogFile
)
#Function to get the correct timestamp format for Influx
function Get-DBTimestamp($timestamp = (get-date)){
    if($timestamp -is [system.string]){
        $timestamp = [datetime]::ParseExact($timestamp,'dd.MM.yyyy HH:mm:ss',$null)
    }
    return $([long][double]::Parse((get-date $($timestamp).ToUniversalTime() -UFormat %s)) * 1000 * 1000 * 1000)
}

if(!$LogFile){
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
    $LogFile = "$scriptDir\log\vcpoll_vsan_diskgroup.log"
}
$start = Get-Date

#Import PowerCLI
#Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCeip:$false -Scope Session -Confirm:$false

#Vstatinterval is based on the realtime performance metrics gathered from vCenter which is 20 seconds
$statInterval = 300

#Set targetname if omitted as a script parameter
if($targetname -eq $null -or $targetname -eq ""){
    if($cluster){
        $targetname = $cluster
    }
    else{
        $targetname = $vcenter
    }
    $Targetname = "VSAN_" + $Targetname
}

#Connect to vCenter
try {
    $vc_conn = Connect-VIServer $vcenter -ErrorAction Stop -ErrorVariable vcerr  
    $vcid = $vc_conn.InstanceUuid
}
catch {
    Write-Output "$(Get-Date) : Couldn't connect to vCenter $vCenter. Script was started at $start" | Out-File $LogFile -Append
    Write-Output "$(Get-Date) : Error message was: $($vcerr.message)" | Out-File $LogFile -Append
    break
}

if($cluster){
    $clusterObjects = Get-Cluster $cluster -ErrorAction Stop -ErrorVariable clustErr
}
else{
    $clusterObjects = Get-Cluster | Where-Object {$_.VsanEnabled}
    Write-Output "Found $($clusterObjects.count) clusters"
}

if(!$clusterObjects){
    Write-Output "$(Get-Date) : Cluster not found. Exiting..." | Out-File $LogFile -Append
    break
}

#Table to store data
$newtbl = @()

#The different metrics to fetch. Because some errors with specifying the metrics we're using the wildcard instead..
#$metricsVsan = "Performance.ReadCacheWriteIops","Performance.WriteBufferReadIops","Performance.ReadCacheReadIops","Performance.WriteBufferWriteIops","Performance.ReadThroughput","Performance.WriteThroughput","Performance.ReadCacheReadLatency","Performance.AverageReadLatency","Performance.AverageWriteLatency","Backend.ReadThroughput","Backend.AverageReadLatency","Backend.WriteThroughput","Backend.AverageWriteLatency","Backend.Congestion","Backend.OutstandingIO","Backend.RecoveryWriteIops","Backend.RecoveryWriteThroughput","Backend.RecoveryWriteAverageLatency"
$metricsVsan = "*"

foreach($clusterObj in $clusterObjects){
    $diskGroups = Get-VsanDiskGroup -Cluster $clusterObj

    foreach($dg in $diskGroups){

        $lapStart = get-date
        
        $vmhost = $dg.vmhost.name
    
        #Build variables for "metadata"    
        $name = $dg.Name.Replace(" ","_")
        $dgType = $dg.DiskGroupType
        $san = $clusterObj.Name
        $sanid = $clusterObj.Id
        
        $type = "vsan_diskgroup"
        
        #Get the stats
        $stats = Get-VsanStat -Entity $dg -Name $metricsVsan -StartTime $lapStart.AddMinutes(-5)
        
        foreach($stat in $stats){
                
            $unit = $stat.Unit
            #We'll convert microseconds to milliseconds to correspond with "normal" vSphere stats
            if($unit -eq "Microseconds"){
                $value = $stat.Value / 1000
                $unit = "ms"
            }
            else{
                $value = $stat.Value
            }
    
            #Get correct timestamp for InfluxDB
            $statTimestamp = Get-DBTimestamp $stat.Time
    
            if($unit -eq "%"){
                $unit="perc"
            }
            switch ($stat.Name) {
                "Performance.ReadCacheWriteIops" { $measurement = "io_read"; $unit = "iops" }
                "Performance.WriteBufferReadIops" { $measurement = "io_write"; $unit = "iops" }
                "Performance.ReadCacheReadIops" { $measurement = "io_readcache_read"; $unit = "iops" }
                "Performance.WriteBufferWriteIops" { $measurement = "io_writebuffer_write"; $unit = "iops" }
                "Performance.ReadThroughput" {$measurement = "kB_read"; $value = ($value / 1024); $unit = "KBps" }
                "Performance.WriteThroughput" { $measurement = "kB_write"; $value = ($value / 1024); $unit = "KBps" }
                "Performance.AverageReadLatency" { $measurement = "latency_read"; $unit = "ms" }
                "Performance.AverageWriteLatency" { $measurement = "latency_write"; $unit = "ms" }
                "Performance.ReadCacheReadLatency" { $measurement = "latency_readcache_read"; }
                "Performance.ReadCacheHitRate" { $measurement = "readcache_hitrate"; }
                "Performance.WriteBufferFreePercentage" { $measurement = "writebuffer_free"; }
                "Performance.WriteBufferWriteLatency" { $measurement = "latency_writebuffer"; }
                "Performance.Capacity" { $measurement = "capacity"; $value = $value / 1GB; $unit = "GB" }
                "Performance.UsedCapacity" { $measurement = "used_capacity"; $value = $value / 1GB; $unit = "GB" }
                Default { $measurement = $null }
            }
            
            if($measurement -ne $null){
                $newtbl += "$measurement,name=$name,diskgrouptype=$dgType,type=$type,san=$san,sanid=$sanid,platform=$vcenter,platformid=$vcid,unit=$unit,statinterval=$statinterval,host=$vmhost value=$Value $stattimestamp"
            }
        }
    
        #Calculate lap time
        $lapStop = get-date
        $timespan = New-TimeSpan -Start $lapStart -End $lapStop
        #Write-Output $timespan.TotalSeconds
    }

}

#Disconnect from vCenter
Disconnect-VIServer $vcenter -Confirm:$false    

#Calculate runtime
$stop = Get-Date
$runTimespan = New-TimeSpan -Start $start -End $stop

Write-Output "Run $run took $($runTimespan.TotalSeconds) seconds"

#Build URI for the API call
$baseUri = "http://" + $dbserver + ":" + $dbserverPort + "/"
$dbname = "performance"
$postUri = $baseUri + "write?db=" + $dbname

####TODO: Test API access / error handling

#Write data to the API
Invoke-RestMethod -Method Post -Uri $postUri -Body ($newtbl -join "`n")

#Build qry to write stats about the run
$pollStatQry = "pollingstat,poller=$($env:COMPUTERNAME),unit=s,type=vsanpoll,target=$($targetname) runtime=$($runtimespan.TotalSeconds),entitycount=$($vmhosts.Count) $(Get-DBTimestamp -timestamp $start)"

#Write data about the run
Invoke-RestMethod -Method Post -Uri $postUri -Body $pollStatQry

