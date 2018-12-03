<#
    .SYNOPSIS
        Script for outputting vCenter load to Influx
    .DESCRIPTION
        This script will fetch the performance stats from 
        the vCenter REST API and post this data to a InfluxDB database.

        The script will fetch the 5 minute interval.
        
        This script is tested against vCenter 6.7U1, please note that 
        there might be differences in other version
    .NOTES
        Author: Rudi Martinsen / Intility AS
        Created: 28/11-2018
        Version: 1.0.0
        Revised: 
        Changelog:
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

#Skip ssl stuff...
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


########################
## Environment params ##
########################
$vcenter = "your-vcsa"
$username = "your-user"
$pass = "your-pass"

$database = "vcsa"
$influxServer = "your-influxserver"
$influxPort = 8086

################
## End params ##
################

$BaseUri = "https://$vcenter/rest/"

#Authenticate to vCenter
$SessionUri = $BaseUri + "com/vmware/cis/session"
$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($UserName+':'+$Pass))
$header = @{
  'Authorization' = "Basic $auth"
}
$token = (Invoke-RestMethod -Method Post -Headers $header -Uri $SessionUri).Value
$sessionheader = @{'vmware-api-session-id' = $token}

#Build string of metrics to pull
$metrics = @(
    "cpu.util"
    "mem.usage"
)

$count = 1
$string = ""
foreach($met in $metrics){
    $string += "&item.names.$count=$met"
    $count++
}

#Create array for storing data
$tbl = @()

#Set start/end timestamps for use in the endpoint queries
$end = (Get-Date).AddMinutes(-5).ToUniversalTime()
$start = $end.AddMinutes(-5)
$endTime = Get-Date $end -Format "yyyy-MM-ddTHH\:mm\:ss.fffZ"
$startTime = Get-Date $start -Format "yyyy-MM-ddTHH\:mm\:ss.fffZ"

#Build URI with timestamps and metrics string
$uri = $BaseUri + "appliance/monitoring/query?item.interval=MINUTES5&item.function=MAX&item.start_time=$startTime&item.end_time=$endTime$string"

#Fetch data
$response = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $uri

#Iterate through metrics
foreach($stat in $response.value){
    Remove-Variable val1,val2,time1,time2 -ErrorAction SilentlyContinue | Out-Null
    
    #Set measurement name
    switch($stat.name){
        "cpu.util" {$measurement = "cpu"; $field = "value"; }
        "mem.usage" {$measurement = "mem"; $field = "value"; }
        default {$measurement = $null}
    }

    if($measurement -eq $null){
        continue
    }

    #Fetch both values (in case of 5 min interval) and add to data array
    if($stat.data[-2]){
        $val1 = $stat.data[-2]
        $time1 = Get-DBTimestamp (get-date $stat.start_time)
        $tbl += "$measurement,server=$vcenter,interval=$($stat.interval),unit=perc $field=$val1 $time1"
    }
    
    if($stat.data[-1]){
        $val2 = $stat.data[-1]
        $time2 = Get-DBTimestamp (get-date $stat.end_time)
        $tbl += "$measurement,server=$vcenter,interval=$($stat.interval),unit=perc $field=$val2 $time2"
    }
}

#Post data to Influx API
$postUri = "http://$influxServer" + ":$influxPort/write?db=$database"
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n")