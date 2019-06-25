<#
    .SYNOPSIS
        Script for pulling performance metrics from vCenter VSAN clusters and writing to an Influx database
    .DESCRIPTION
        The script will pull performance metrics for VSAN Hosts from vCenter and writes to an Influx
        timeseries database.
    .NOTES
        Author: Rudi Martinsen / Intility AS
        Created: 07/03-2018
<<<<<<< HEAD
        Version 0.3.0
        Revised: 25/06-2019
        Changelog:
        0.3.0 -- Added support for multiple clusters
=======
        Version 0.3.0-beta
        Revised: 17/02-2019
        Changelog:
        0.3.0-beta -- Added support for multiple clusters (not tested)
>>>>>>> dc1f8f502eff2622bd72092906443782be8f2815
        0.2.1 -- Fixed Read-host on password
        0.2.0 -- Adding Influx auth support
        0.1.2 -- Cleaned unused variables
        0.1.1 -- Added backend stuff
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
    .PARAMETER DBServerUserName
        Username for authenticating to InfluxDB
    .PARAMETER DBServerUserPass
        Password for authenticating to InfluxDB
    .PARAMETER LogFile
        Path to the logfile to write to
#>
param(
    [Parameter(Mandatory=$true)]
    $VCenter,
    [Parameter(Mandatory=$false)]
    $Cluster,
    $Targetname,
    $DBServer,
    $DBServerPort = 8086,
    $DBServerUserName,
    [securestring]
    $DBServerUserPass = (Read-Host -Prompt "Please provide password" -AsSecureString),
    $SkipSSL = $true,
    $LogFile
)
function Insecure-SSL {
#skip ssl validation
add-type @" 
    using System.Net; 
    using System.Security.Cryptography.X509Certificates; 
    public class TrustAllCertsPolicy : ICertificatePolicy { 
        public bool CheckValidationResult( 
            ServicePoint srvPoint, X509Certificate certificate, 
            WebRequest request, int certificateProblem) { 
            return true; 
        } 
    } 
"@  
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    $AllProtocols = [System.Net.SecurityProtocolType]'Ssl3,Tls,Tls11,Tls12'
    [System.Net.ServicePointManager]::SecurityProtocol = $AllProtocols
}
#Function to get the correct timestamp format for Influx
function Get-DBTimestamp($timestamp = (get-date)){
    if($timestamp -is [system.string]){
        $timestamp = [datetime]::ParseExact($timestamp,'dd.MM.yyyy HH:mm:ss',$null)
    }
    return $([long][double]::Parse((get-date $($timestamp).ToUniversalTime() -UFormat %s)) * 1000 * 1000 * 1000)
}

if(!$LogFile){
    $scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
    $LogFile = "$scriptDir\log\vcpoll_vsan_cluster.log"
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

#Get VSAN clusters
if($cluster){
<<<<<<< HEAD
    $clusterObjects = Get-Cluster $cluster -ErrorAction Stop -ErrorVariable clustErr
=======
    $clusterObj = Get-Cluster $cluster | where-Object {$_.VsanEnabled -eq $true} -ErrorAction Stop -ErrorVariable clustErr
>>>>>>> dc1f8f502eff2622bd72092906443782be8f2815
}
else{
    $clusterObjects = Get-Cluster | Where-Object {$_.VsanEnabled}
    Write-Output "Found $($clusterObjects.count) clusters"
}

#Table to store data
$newtbl = @()

#The different metrics to fetch. Because some errors with specifying the metrics we're using the wildcard instead..
#$metricsVsan = "VMConsumption.ReadThroughput","VMConsumption.AverageReadLatency","VMConsumption.WriteThroughput","VMConsumption.AverageWriteLatency","VMConsumption.Congestion","VMConsumption.OutstandingIO"
$metricsVsan = "*"

<<<<<<< HEAD
if(!$clusterObjects){
    Write-Output "$(Get-Date) : Cluster not found. Exiting..." | Out-File $LogFile -Append
    break
}

foreach($clusterObj in $clusterObjects){
    Write-Output "Processing VSAN cluster $($clusterObj.Name)"
    $san = $clusterObj.Name
    $sanid = $clusterObj.Id
    $type = "vsan"
        
    #Get the stats
    $stats = Get-VsanStat -Entity $clusterObj -Name $metricsVsan -StartTime $lapStart.AddMinutes(-5)
    $space = Get-VsanSpaceUsage -Cluster $clusterObj
=======
if(!$clusterObj){
    Write-Output "$(Get-Date) : VSAN Cluster not found. Exiting..." | Out-File $LogFile -Append
    break
}

foreach ($clust in $clusterObj){
    Write-Output "Working on cluster $($clust.name)"
    $san = $clust.Name
    $sanid = $clust.Id
    $type = "vsan"
        
    #Get the stats
    $stats = Get-VsanStat -Entity $clust -Name $metricsVsan -StartTime $lapStart.AddMinutes(-5)
    $space = Get-VsanSpaceUsage -Cluster $clust
>>>>>>> dc1f8f502eff2622bd72092906443782be8f2815
        
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
            "VMConsumption.ReadThroughput" { $measurement = "kB_read"; $value = ($value / 1024); $unit = "KBps" }
            "VMConsumption.AverageReadLatency" { $measurement = "latency_read"; }
            "VMConsumption.WriteThroughput" { $measurement = "kB_write"; $value = ($value / 1024); $unit = "KBps" }
            "VMConsumption.AverageWriteLatency" { $measurement = "latency_write"; }
            "VMConsumption.Congestion" {$measurement = "congestion"; $unit = "count" }
            "VMConsumption.OutstandingIO" { $measurement = "io_outstanding"; $unit = "count" }
            "VMConsumption.ReadIops" { $measurement = "io_read"; $unit = "iops" }
            "VMConsumption.WriteIops" { $measurement = "io_write"; $unit = "iops" }
            "Backend.ResyncReadLatency" { $measurement = "latency_resync_read"; }
            "Backend.ReadThroughput" { $measurement = "kB_read_backend"; $value = ($value / 1024); $unit = "KBps" }
            "Backend.AverageReadLatency" { $measurement = "latency_read_backend"; }
            "Backend.WriteThroughput" { $measurement = "kB_write_backend"; $value = ($value / 1024); $unit = "KBps" }
            "Backend.AverageWriteLatency" { $measurement = "latency_write_backend"; }
            "Backend.Congestion" {$measurement = "congestion_backend"; $unit = "count" }
            "Backend.OutstandingIO" { $measurement = "io_outstanding_backend"; $unit = "count" }
            "Backend.RecoveryWriteIops" { $measurement = "io_write_recovery"; $unit = "iops" }
            "Backend.RecoveryWriteThroughput" { $measurement = "kb_write_recovery"; $value = ($value / 1024); $unit = "KBps" }
            "Backend.RecoveryWriteAverageLatency" { $measurement = "latency_write_recovery"; }
            Default { $measurement = $null }
        }

        if($measurement -ne $null){
            $newtbl += "$measurement,type=$type,san=$san,sanid=$sanid,platform=$vcenter,platformid=$vcid,unit=$unit,statinterval=$statinterval value=$Value $stattimestamp"
        }
    }

    if($space){
        $newtbl += "vsan_diskusage,type=$type,san=$san,sanid=$sanid,platform=$vcenter,platformid=$vcid,unit=GB,statinterval=$statinterval freespace=$([int]$space.freespacegb),capacity=$([int]$space.CapacityGB),primaryvmdata=$([int]$space.PrimaryVMDataGB),vdiskusage=$([int]$space.VirtualDiskUsageGB),vsanoverhead=$([int]$space.VsanOverheadGB),vmhomeusage=$([int]$space.VMHomeUsageGB) $stattimestamp"
    }
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

#User authentication to Influx
if($SkipSSL){
    Insecure-SSL
}
$insecurePass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($DBServerUserPass))
$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($DBServerUserName+':'+$insecurePass))
$header = @{
  'Authorization' = "Basic $auth"
}

####TODO: Test API access / error handling

#Write data to the API
Invoke-RestMethod -Method Post -Uri $postUri -Body ($newtbl -join "`n") -Headers $header

#Build qry to write stats about the run
$pollStatQry = "pollingstat,poller=$($env:COMPUTERNAME),unit=s,type=vsanpoll,target=$($targetname) runtime=$($runtimespan.TotalSeconds),entitycount=$($vmhosts.Count) $(Get-DBTimestamp -timestamp $start)"

#Write data about the run
Invoke-RestMethod -Method Post -Uri $postUri -Body $pollStatQry
