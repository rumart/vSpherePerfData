#requires -module VMware.PowerCLI
<#
    .SYNOPSIS
        Script for pulling performance metrics from vCenter and writing to an Influx database
    .DESCRIPTION
        The script will pull performance metrics for VMHosts from vCenter and writes the data to an Influx
        timeseries database.
    .NOTES
        Author: Rudi Martinsen / Intility AS
        Created: 30/06-2017
        Version 0.5.4
        Revised: 28/02-2018
        Changelog:
        0.5.4 -- Added vmhba for new DL servers
        0.5.3 -- Added metrics (adapter & network totals)
        0.5.2 -- Added VDI metrics, comes in place if the cluster has VDI in its name
        0.5.1 -- Added metrics (mem usage, co stop)
        0.5.0 -- Added connection state
        0.4.0 -- Added error handling on vCenter connection, cleaned some comments and variables
        0.3.0 -- Added storageadapter and CPU Ready to metrics
        0.2.0 -- Changed to entitycount for pollingstat
    .LINK
        http://www.rudimartinsen.com/2017/07/17/vsphere-performance-data-part-5-the-script/
    .PARAMETER Samples
        Script parameter for how many samples to fetch. Default of 15 will give last 5 minutes (15*20sec)
    .PARAMETER VCenter
        The vCenter to connect to
    .PARAMETER Cluster
        The Cluster to get Hosts from. If omitted all Hosts in the vCenter will be fetched
    .PARAMETER HostCount
        Optional number of Hosts to get metrics from
    .PARAMETER Skip
        Optional number of Hosts to skip. Use with HostCount
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
    $VCenter,
    $Cluster,
    $Samples = 15,
    $Hostcount = 0,
    $Skip = 0, 
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
    $LogFile = "$scriptDir\log\vcpoll_host.log"
}
$start = Get-Date

#Import PowerCLI
Import-Module VMware.VimAutomation.Core

#statinterval is based on the realtime performance metrics gathered from vCenter which is 20 seconds
$statInterval = 20

#Variable to calculate correct CpuRdy value
$cpuRdyInt = 200

#Set targetname if omitted as a script parameter
if($targetname -eq $null -or $targetname -eq ""){
    if($cluster){
        $targetname = $cluster
    }
    else{
        $targetname = $vcenter
    }
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
#Get Hosts
if($cluster){
    $vmhosts = Get-Cluster $cluster -Server $vcenter | Get-VMHost | Where-Object {$_.ConnectionState -ne "NotResponding"}
}
else{
    $vmhosts = Get-VMHost -Server $vcenter | Where-Object {$_.ConnectionState -ne "NotResponding"}
}

####Filter based on vmcount/skip parameters. Could probably be done in the query above?
if($hostcount -gt 0){
    $vmhosts = $vmhosts | Sort-Object name | Select-Object -First $hostcount -Skip $skip
}

#Table to store data
$tbl = @()

#The different metrics to fetch
$metricsEsxi = "cpu.totalcapacity.average","cpu.usagemhz.average","cpu.ready.summation","cpu.costop.summation","cpu.latency.average","cpu.usage.average","cpu.utilization.average","mem.totalcapacity.average","mem.consumed.average","net.received.average","net.transmitted.average","storageadapter.read.average","storageadapter.write.average","mem.usage.average","net.usage.average","storageAdapter.commandsAveraged.average"
$metricsVdi = $metricsesxi + "gpu.mem.usage.average","gpu.mem.used.average","gpu.temperature.average","gpu.utilization.average"

foreach($vmhost in $vmhosts){
    $lapStart = get-date
    
    #Build variables for host metadata
    $hid = $vmhost.Id
    $hname = $vmhost.Name
    $cid = $vmhost.ParentId
    $cname = $vmhost.Parent.Name
    $vendor = $vmhost.ExtensionData.Hardware.SystemInfo.Vendor
    $state = $vmhost.ConnectionState

    if($cname -like "*VDI*"){
        $vdi = $true
        $metrics = $metricsvdi
    }
    else{
        $vdi = $false
        $metrics = $metricsEsxi
    }
    
    #Get the stats
    $stats = Get-Stat -Entity $vmhost -Realtime -MaxSamples $samples -Stat $metrics
    
    foreach($stat in $stats){
        $instance = $stat.Instance

        #Metrics will often have values for several instances per entity. Normally they will also have an aggregated instance. We're only interested in that one for now if not VDI metric
        if($instance -or $instance -ne "" -and $vdi -eq $false){
            continue
        }
            
        $unit = $stat.Unit
        $value = $stat.Value
        $statTimestamp = Get-DBTimestamp $stat.Timestamp

        if($unit -eq "%"){
            $unit="perc"
        }

        switch ($stat.MetricId) {
            "cpu.ready.summation" { $measurement = "cpu_ready"; $value = ($_.value / $cpuRdyInt); $unit = "perc" }
            "cpu.costop.summation" { $measurement = "cpu_costop"; $value = ($_.value / $cpuRdyInt); $unit = "perc" }
            "cpu.totalcapacity.average" { $measurement = "cpu_totalcapacity" }
            "cpu.utilization.average" {$measurement = "cpu_util" }
            "cpu.usagemhz.average" {$measurement = "cpu_usagemhz" }
            "cpu.usage.average" {$measurement = "cpu_usage" }
            "cpu.latency.average" {$measurement = "cpu_latency" }
            "mem.totalcapacity.average" {$measurement = "mem_totalcapacity"}
            "mem.consumed.average" {$measurement = "mem_consumed"}
            "mem.usage.average" {$measurement = "mem_usage"}
            "net.received.average"  {$measurement = "net_through_receive"}
            "net.transmitted.average"  {$measurement = "net_through_transmit"}
            "net.usage.average"  {$measurement = "net_through_total"}
            "gpu.mem.used.average"  {$measurement = "gpu_mem_usedkb";$vdiM=$true}
            "gpu.mem.usage.average"  {$measurement = "gpu_mem_usage";$vdiM=$true}
            "gpu.utilization.average"  {$measurement = "gpu_utilization";$vdiM=$true}
            "gpu.temperature.average"  {$measurement = "gpu_temperature";$vdiM=$true}
            #"storageadapter.read.average"  {$measurement = "stor_through_read"}
            #"storageadapter.write.average"  {$measurement = "stor_through_write"}
            Default { $measurement = $null }
        }

        if($measurement -ne $null){
            if($vdiM){
                #Write-Output "VDI! $measurement"
                $tbl += "$measurement,type=host,host=$hname,hostid=$hid,cluster=$cname,clusterid=$cid,platform=$vcenter,platformid=$vcid,location=$location,unit=$unit,statinterval=$statinterval,state=$state,instance=$instance value=$Value $stattimestamp"
            }
            else{
                $tbl += "$measurement,type=host,host=$hname,hostid=$hid,cluster=$cname,clusterid=$cid,platform=$vcenter,platformid=$vcid,location=$location,unit=$unit,statinterval=$statinterval,state=$state value=$Value $stattimestamp"
            }
        }

    }
    
    #Our environment consists mainly of HPE hosts which have the same adapters. The other hardware have different adapter configs and will be decommissioned soon so we don't care about them
    if($vendor -eq "HP" -or "HPE"){
        $stats | Where-Object {$_.metricid -eq  "storageadapter.read.average" -and (($_.instance -eq "vmhba0" -or $_.instance -eq "vmhba1") -or ($_.instance -eq "vmhba33" -or $_.instance -eq "vmhba34"))} | Group-Object timestamp | ForEach-Object {$tbl += "stor_through_read,type=host,host=$hname,hostid=$hid,cluster=$cname,clusterid=$cid,platform=$vcenter,platformid=$vcid,location=$location,unit=KBps,statinterval=$statinterval value=$([int](($_.group[0].value + $_.group[1].value)) ) $(Get-DBTimestamp $_.name)"}
        $stats | Where-Object {$_.metricid -eq  "storageadapter.write.average" -and (($_.instance -eq "vmhba0" -or $_.instance -eq "vmhba1") -or ($_.instance -eq "vmhba33" -or $_.instance -eq "vmhba34"))} | Group-Object timestamp | ForEach-Object {$tbl += "stor_through_write,type=host,host=$hname,hostid=$hid,cluster=$cname,clusterid=$cid,platform=$vcenter,platformid=$vcid,location=$location,unit=KBps,statinterval=$statinterval value=$([int](($_.group[0].value + $_.group[1].value)) ) $(Get-DBTimestamp $_.name)"}
        $stats | Where-Object {$_.metricid -eq  "storageAdapter.commandsAveraged.average" -and (($_.instance -eq "vmhba0" -or $_.instance -eq "vmhba1") -or ($_.instance -eq "vmhba33" -or $_.instance -eq "vmhba34"))} | Group-Object timestamp | ForEach-Object {$tbl += "stor_through_write,type=host,host=$hname,hostid=$hid,cluster=$cname,clusterid=$cid,platform=$vcenter,platformid=$vcid,location=$location,unit=KBps,statinterval=$statinterval value=$([int](($_.group[0].value + $_.group[1].value)) ) $(Get-DBTimestamp $_.name)"}
    }

    #Calculate lap time
    $lapStop = get-date
    $timespan = New-TimeSpan -Start $lapStart -End $lapStop
    Write-Output $timespan.TotalSeconds

}

#Disconnect from vCenter
Disconnect-VIServer $vcenter -Confirm:$false    

#Calculate runtime
$stop = get-date
$runTimespan = New-TimeSpan -Start $start -End $stop

Write-Output "Run $run took $($runTimespan.TotalSeconds) seconds"

#Build URI for the API call
$baseUri = "http://" + $dbserver + ":" + $dbserverPort + "/"
$dbname = "performance"
$postUri = $baseUri + "write?db=" + $dbname

####Perform a test againts the API?

#Write data to the API
Invoke-RestMethod -Method Post -Uri $postUri -Body ($newtbl -join "`n")

#Build qry to write stats about the run
$pollStatQry = "pollingstat,poller=$($env:COMPUTERNAME),unit=s,type=vmhostpoll,target=$($targetname) runtime=$($runtimespan.TotalSeconds),entitycount=$($vmhosts.Count) $(Get-DBTimestamp -timestamp $start)"

#Write data about the run
Invoke-RestMethod -Method Post -Uri $postUri -Body $pollStatQry
