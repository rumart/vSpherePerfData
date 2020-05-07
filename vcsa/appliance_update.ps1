 <#
    .SYNOPSIS
        Script for outputting VCSA info to Influx
    .DESCRIPTION
        This script will fetch update information from 
        the VCSA REST API and post this data to a InfluxDB database

        This script is tested against vCenter 6.7U3, please note that 
        there might be differences in other version
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
    $updUri = $BaseUri + "appliance/update"
    $updLastCheckUri = $BaseUri + "appliance/update/pending?source_type=LAST_CHECK"
    $updPolUri = $BaseUri + "appliance/update/policy"

    #Fetch data
    $updResponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $updUri -SkipCertificateCheck
    $updPolResponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $updPolUri -SkipCertificateCheck

    #Build variables for Influx
    $qryTime = $updResponse.value.latest_query_time
    $newVersion = "n/a"
    $upd_type = "n/a"
    $rel_date = "n/a"
    $priority = "n/a"
    $severity = "n/a"
    if($qryTime -and $qryTime -ge (Get-Date).AddDays(-1)){
        $qryTime = (New-TimeSpan -Start (get-date 1/1-1970) -End $qrytime).TotalMilliseconds
        $updLastCheckResponse = Invoke-RestMethod -Method Get -Headers $sessionheader -Uri $updLastCheckUri -SkipCertificateCheck
        $state = $updResponse.value.state
        if ($updLastCheckResponse) {
            $newVersion = $updLastCheckResponse.value[0].version
            $upd_type = $updLastCheckResponse.value[0].update_type
            $rel_date = (New-TimeSpan -Start (get-date 1/1-1970) -End $updLastCheckResponse.value[0].release_date).TotalMilliseconds
            $priority = $updLastCheckResponse.value[0].priority
            $severity = $updLastCheckResponse.value[0].severity
        }    
    }
    else{
        $qryTime = "n/a"
        $state = "n/a"
    }

    $manualControl = $updPolResponse.value.manual_control

    #Add to array
    $tbl += "appliance_update,server=$vcenter state=""$state"",query_time=""$qryTime"",manual_control=$manualControl,new_version=""$newVersion"",rel_date=""$rel_date"",upd_type=""$upd_type"",severity=""$severity"",priority=""$priority"" $timestamp"

}

#Post data to Influx API
$postUri = "http://$influxServer" + ":$influxPort/write?db=$database"
Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n") 

