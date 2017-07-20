<#
    .SYNOPSIS
        Script for pulling performance metrics from vCenter and writing to an Influx database
    .DESCRIPTION
        The script will pull performance metrics for VMs from vCenter and writes to an Influx
        timeseries database.
    .NOTES
        Author: Rudi Martinsen / Intility AS
        Created: 14/06-2017
        Version 0.5.0
        Revised: 20/07-2017
        Changelog:
        0.5.0 -- Moved companycode logic to a function
        0.4.2 -- Fixed bug in companycode
        0.4.1 -- Fixed bug in hostname
        0.4.0 -- Changed to entitycount for pollingstat
        0.3.0 -- foreach and switch statement on stats
        0.2.1 -- Cleaned script and added description
    .PARAMETER Samples
        Script parameter for how many samples to fetch. Default of 15 will give last 5 minutes (15*20sec)
    .PARAMETER VCenter
        The vCenter to connect to
    .PARAMETER Cluster
        The Cluster to get VMs from. If omitted all VMs in the vCenter will be fetched
    .PARAMETER VMCount
        Optional number of VMs to get metrics from
    .PARAMETER Skip
        Optional number of VMs to skip. Use with VMCount
    .PARAMETER Targetname
        Optional name of the target for use as a Tag in the Influx record
    .PARAMETER DBServer
        IP Address or hostname of the Influx Database server
    .PARAMETER DBServerPort
        TCP port for the DB server, Defaults to 8086 which is the default Influx port
#>
param(
    $VCenter,
    $Cluster,
    $Samples = 15,
    $Vmcount = 0,
    $Skip = 0, 
    $Targetname,
    $Dbserver,
    $DbserverPort = 8086
)
#Function to get the correct timestamp format for Influx
function Get-DBTimestamp($timestamp = (get-date)){
    if($timestamp -is [system.string]){
        $timestamp = [datetime]::ParseExact($timestamp,'dd.MM.yyyy HH:mm:ss',$null)
    }
    return $([long][double]::Parse((get-date $($timestamp).ToUniversalTime() -UFormat %s)) * 1000 * 1000 * 1000)
}

function Get-CompanyCode ($vmname) {
    $splitName = $vmname.split("-")[0]

    if($splitName.Length -eq 2){
        $companycode = $splitName
    }
    elseif($splitName.Length -gt 2){
        $companycode = $splitName.Substring(0,2)
        
    }
    else{
        $companycode = $null
    }
    return $companycode
}

$start = Get-Date

#Import PowerCLI
Import-Module VMware.VimAutomation.Core

#Vstatinterval is based on the realtime performance metrics gathered from vCenter which is 20 seconds
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
$vc_conn = Connect-VIServer $vcenter
$vcid = $vc_conn.InstanceUuid

#Get VMs
if($cluster){
    $vms = Get-Cluster $cluster | Get-VM -Server $vcenter | Where-Object {$_.PowerState -eq "PoweredOn"}
}
else{
    $vms = Get-VM -Server $vcenter | Where-Object {$_.PowerState -eq "PoweredOn"}
}

#Filter based on vmcount/skip parameters. 
#TODO: Could probably be done in the query above?
if($vmcount -gt 0){
    $vms = $vms | Sort-Object name | Select-Object -First $vmcount -Skip $skip
}

#Table to store data
$tbl = @()

#The different metrics to fetch
$metrics = "cpu.ready.summation","cpu.latency.average","cpu.usagemhz.average","cpu.usage.average","mem.active.average","mem.usage.average","net.received.average","net.transmitted.average","disk.maxtotallatency.latest","disk.read.average","disk.write.average","disk.numberReadAveraged.average","disk.numberWriteAveraged.average"

foreach($vm in $vms){
    $lapStart = get-date
    
    #Build variables for vm "metadata"    
    $hid = $vm.VMHostId
    $cid = $vm.VMHost.ParentId
    $cname = $vm.VMHost.Parent.Name
    $vid = $vm.Id
    $vname = $vm.name
    $vproc = $vm.NumCpu
    $hname = $vm.VMHost.Name
    
    #TODO: Move companycode logic to a function
    
   

    #Get the stats
    $stats = Get-Stat -Entity $vm -Realtime -MaxSamples $samples -Stat $metrics
    
    foreach($stat in $stats){
        $instance = $stat.Instance

        #Metrics will often have values for several instances per entity. Normally they will also have an aggregated instance. We're only interested in that one for now
        if($instance -or $instance -ne ""){
            continue
        }
            
        $unit = $stat.Unit
        $value = $stat.Value
        $statTimestamp = Get-DBTimestamp $stat.Timestamp

        if($unit -eq "%"){
            $unit="perc"
        }

        switch ($stat.MetricId) {
            "cpu.ready.summation" { $measurement = "cpu_ready";$value = $(($Value / $cpuRdyInt)/$vproc) }
            "cpu.latency.average" {$measurement = "cpu_latency" }
            "cpu.usagemhz.average" {$measurement = "cpu_usagemhz" }
            "cpu.usage.average" {$measurement = "cpu_usage" }
            "mem.active.average" {$measurement = "mem_usagekb" }
            "mem.usage.average" {$measurement = "mem_usage" }
            "net.received.average"  {$measurement = "net_through_receive"}
            "net.transmitted.average"  {$measurement = "net_through_transmit"}
            "disk.maxtotallatency.latest" {$measurement = "storage_latency"}
            "disk.read.average" {$measurement = "disk_through_read"}
            "disk.write.average" {$measurement = "disk_through_write"}
            Default { $measurement = $null }
        }

        if($measurement -ne $null){
            $tbl += "$measurement,type=vm,vm=$vname,vmid=$vid,companycode=$companycode,host=$hname,hostid=$hid,cluster=$cname,clusterid=$cid,platform=$vcenter,platformid=$vcid,unit=$unit,statinterval=$statinterval value=$Value $stattimestamp"
        }

    }
    
    $stats | Where-Object {$_.metricid -eq  "disk.numberReadAveraged.average"} | Group-Object timestamp | ForEach-Object {$tbl += "disk_iops_read,type=vm,vm=$vname,vmid=$vid,companycode=$companycode,host=$hname,hostid=$hid,cluster=$cname,clusterid=$cid,platform=$vcenter,platformid=$vcid,unit=iops,statinterval=$statinterval value=$($_.group) $(Get-DBTimestamp $_.name)"}
    $stats | Where-Object {$_.metricid -eq  "disk.numberWriteAveraged.average"} | Group-Object timestamp | ForEach-Object {$tbl += "disk_iops_write,type=vm,vm=$vname,vmid=$vid,companycode=$companycode,host=$hname,hostid=$hid,cluster=$cname,clusterid=$cid,platform=$vcenter,platformid=$vcid,unit=iops,statinterval=$statinterval value=$($_.group) $(Get-DBTimestamp $_.name)"}
    
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

Write-Output "Run took $($runTimespan.TotalSeconds) seconds"

#Build URI for the API call
$baseUri = "http://" + $dbserver + ":" + $dbserverPort + "/"
$dbname = "performance"
$postUri = $baseUri + "write?db=" + $dbname

#TODO: Perform a test againts the API?

#Write data to the API
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n")

#Build qry to write stats about the run
$pollStatQry = "pollingstat,poller=$($env:COMPUTERNAME),unit=s,type=vmpoll,target=$($targetname) runtime=$($runtimespan.TotalSeconds),entitycount=$($vms.Count) $(Get-DBTimestamp -timestamp $start)"

#Write data about the run
Invoke-RestMethod -Method Post -Uri $postUri -Body $pollStatQry

#TODO: Error handling for API calls..