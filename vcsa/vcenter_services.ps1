<#
    .SYNOPSIS
        Script for outputting vCenter storage info to Influx
    .DESCRIPTION
        This script will fetch the vCenter services status from 
        the vCenter REST API and post this data to a InfluxDB database.

        A conversion of the textual output of status to a numeric value 
        will be done to support dashboard functions in Grafana
        
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

#Create array for storing data
$tbl = @()

#Set endpoint URI
$uri = $BaseUri + "appliance/vmon/service"

#Fetch data
$response = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $uri

#Set timestamp for query
$timestamp = Get-DBTimestamp

#Iterate through services
foreach($stat in $response.value){
    
    Remove-Variable value -ErrorAction SilentlyContinue | Out-Null
    
    #Set name and state of service
    $name = $stat.key
    $state = $stat.value.state
    
    #Set state to DEGRADED if an AUTOMATIC service is stopped
    if($stat.value.health){
        $health = $stat.value.health
    }
    elseif($stat.value.startup_type -eq "AUTOMATIC" -and $stat.value.state -ne "STARTED"){
        $health = "DEGRADED"
    }
    else{
        $health = "N/A"
    }
    
    #Set numeric value based on textual output
    switch($health){
        "HEALTHY" {$val = 0}
        "HEALTHY_WITH_WARNINGS" {$val = 1}
        "DEGRADED" {$val = 2}
        default {$val = 9}
    }
    
    #Set measurement name
    $measurementName = "vcservice_" + $name
    
    #Add to data array
    $tbl += "$measurementName,server=$vcenter health=""$health"",state=""$state"",value=$val $timestamp"
    
}

#Post data to Influx API
$postUri = "http://$influxServer" + ":$influxPort/write?db=$database"
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n")