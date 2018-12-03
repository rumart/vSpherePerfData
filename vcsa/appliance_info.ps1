<#
    .SYNOPSIS
        Script for outputting VCSA info to Influx
    .DESCRIPTION
        This script will fetch build, version and uptime from 
        the VCSA REST API and post this data to a InfluxDB database

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

#Fetch timestamp
$timestamp = Get-DBTimestamp

#API Endpoints
$verUri = $BaseUri + "appliance/system/version"
$upUri = $BaseUri + "appliance/system/uptime"

#Fetch data
$verResponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $verUri
$upResponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $upUri

#Build variables for Influx
$version = $verResponse.value.version
$build = $verResponse.value.build
$uptime = $upResponse.value

#Add to array
$tbl += "appliance_info,server=$vcenter version=""$version"",build=$build,uptime=$uptime $timestamp"

#Post data to Influx API
$postUri = "http://$influxServer" + ":$influxPort/write?db=$database"
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n")