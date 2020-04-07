#Requires -Version 6.0
<#
    .SYNOPSIS
        Script for outputting VCSA info to Influx
    .DESCRIPTION
        This script will fetch update information from 
        the VCSA REST API and post this data to a InfluxDB database

        This script is tested against vCenter 6.7U3, please note that 
        there might be differences in other versions
    .NOTES
        Author: Rudi Martinsen
        Created: 07/11-2019
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

    #Fetch timestamp
    $timestamp = Get-DBTimestamp

    #API Endpoints
    $bckJobUri = $BaseUri + "appliance/recovery/backup/job"
    $bckSchedUri = $BaseUri + "appliance/recovery/backup/schedules"

    #Fetch data
    $bckJobResponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $bckJobUri -SkipCertificateCheck
    $bckSchedResponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $bckSchedUri -SkipCertificateCheck

    #Build variables for Influx
    $recurrence = "n/a"
    $schedEnabled = "false"
    $protocol = "n/a"
    $location = "n/a"
    if ($bckJobResponse) {
        if ($bckJobResponse.value.count -gt 1) {
            $jobId = $bckJobResponse.value[0]
        }
        else {
            $jobId = $bckJobResponse
        }
        $bckJobDetUri = $bckJobUri + "/$jobId"
        $bckJobDetResponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $bckJobDetUri -SkipCertificateCheck
        
        $startTime = $bckJobDetResponse.value.start_time
        $endTime = $bckJobDetResponse.value.end_time
        
        $duration = (New-TimeSpan -Start $startTime -End $endTime).TotalSeconds
        $start = (New-TimeSpan -Start (get-date 1/1-1970) -End $startTime).TotalMilliseconds
        $end = (New-TimeSpan -Start (get-date 1/1-1970) -End $endTime).TotalMilliseconds
        $progress = $bckJobDetResponse.value.progress
        $state = $bckJobDetResponse.value.state
    }
    if ($bckSchedResponse.value) {
        $schedEnabled = $bckSchedResponse.value.value.enable
        if ($schedEnabled) {
            $schedLocation = $bckSchedResponse.value.value.location
            $schedLocSplit = $schedLocation.Split("://")
            $protocol = $schedLocSplit[0]
            $location = $schedLocSplit[1].Split(":")[0]

            $rec = $bckSchedResponse.value.value.recurrence_info
            if (!$rec.days) {
                $recurrence = "DAILY"
            }
            else {
                $recurrence = $rec.days
            }
        }  
    }

    #Add to array
    if ($jobId) {
        $tbl += "appliance_backup_job,server=$vcenter jobid=""$jobId"",start=""$start"",end=""$end"",duration=$duration,progress=""$progress"",state=""$state"" $timestamp"    
    }
    $tbl += "appliance_backup_schedule,server=$vcenter recurrence=""$recurrence"",protocol=""$protocol"",schedEnabled=$schedEnabled,location=""$location"" $timestamp"
}

#Post data to Influx API
$postUri = "http://$influxServer" + ":$influxPort/write?db=$database"
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n") 
