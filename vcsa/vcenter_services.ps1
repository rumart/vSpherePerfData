#Requires -Version 6.0
<#
    .SYNOPSIS
        Script for outputting vCenter storage info to Influx
    .DESCRIPTION
        This script will fetch the vCenter services status from 
        the vCenter REST API and post this data to a InfluxDB database.

        A conversion of the textual output of status to a numeric value 
        will be done to support dashboard functions in Grafana
        
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

    #Set endpoint URI
    $uri = $BaseUri + "appliance/vmon/service"

    #Fetch data
    $response = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $uri -SkipCertificateCheck

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
}

#Post data to Influx API
$postUri = "http://$influxServer" + ":$influxPort/write?db=$database"
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n") 
