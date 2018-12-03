<#
    .SYNOPSIS
        Script for outputting VCSA health status to Influx
    .DESCRIPTION
        This script will fetch the health status from 
        the VCSA REST API and post this data to a InfluxDB database.

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

$SessionUri = $BaseUri + "com/vmware/cis/session"

#Authenticate to vCenter
$auth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($UserName+':'+$Pass))
$header = @{
  'Authorization' = "Basic $auth"
}
$token = (Invoke-RestMethod -Method Post -Headers $header -Uri $SessionUri).Value
$sessionheader = @{'vmware-api-session-id' = $token}

#Create array for storing data
$tbl = @()

#Build string of metrics/endpoints to pull
$metrics = "applmgmt","database-storage","load","mem","software-packages","storage","swap","system","services"

#Fetch last checked timestamp. Will be used as timestamp for all records
$lcuri = $BaseUri + "appliance/health/system/lastcheck"
$lcresponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $lcuri
$timestamp = Get-DBTimestamp (get-date $lcresponse.value)

#Iterate through all metrics/endpoints
foreach($met in $metrics){
    Remove-Variable value -ErrorAction SilentlyContinue | Out-Null

    #Build current endpoint URI
    $uri = $BaseUri + "appliance/health/$met"
     if($met -eq "services"){
        $uri = $BaseUri + "appliance/$met"
    }

    #Fetch data from enpoint
    Clear-Variable meterr -ErrorAction SilentlyContinue
    $response = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $uri -ErrorVariable metErr
    
    if(!$meterr){
        #Set measurement name
        switch($met){
            "database-storage" {$measurement="health_databasestorage"}
            "software-packages" {$measurement="health_softwarepackages"}
            default {$measurement = "health_$met"}
        }

        
        if($met -eq "services"){
            
            foreach($val in $response.value){
                $name = $val.key
                $value = $val.value.state
                #Set numeric value, used for determining status in dashboards
                switch($value){
                    "STARTED" {$val = 0}
                    "STOPPED" {$val = 1}
                    default {$val = 9}
                }
                #Add to data array
                $tbl += "services,server=$vcenter $name=""$value"",value=$val $timestamp"
            }
        }
        else{

            $value = $response.value
            #Set numeric value, used for determining status in dashboards
            switch($value){
                "green" {$val = 0}
                "orange" {$val = 1}
                "red"  {$val = 2}
                "gray"  {$val = 9}
                "unknown" {$val = 9}
                default {$val = 9}
            }
                
            #Add to data array
            $tbl += "$measurement,server=$vcenter text=""$value"",value=$val $timestamp"
        }
            
    }
    else{
        Write-Warning "[ERROR] Error with $met, error msg $metErr"
    }

}

#Post data to Influx API
$postUri = "http://$influxServer" + ":$influxPort/write?db=$database"
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n")