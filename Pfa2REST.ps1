function New-Pfa2Session {
    param (
        [parameter(Mandatory, ValueFromPipeline)]
        [string]$Endpoint,
        [pscredential]$Credential,
        [switch]$SkipCertificateCheck,
        [version]$Version = '2.0'
    )
    
    $skipCertParams = @{}
    if ($SkipCertificateCheck -and $PSEdition -eq 'core') {
        $skipCertParams.Add('SkipCertificateCheck', $true)
    }

    $credParams = @{
        'username' = $Credential.UserName;
        'password' = $Credential.GetNetworkCredential().Password
    }

    $apiToken = Invoke-RestMethod -Method Post -Uri "https://$Endpoint/api/1.16/auth/apitoken" -Body $credParams @skipCertParams
    $auth = Invoke-WebRequest -Method Post -Uri "https://$Endpoint/api/$Version/login" -Headers @{'api-token' = $apiToken.api_token } @skipCertParams

    $authToken = -join $auth.Headers['x-auth-token']

    $sessionParams = @{
        Headers = @{ 'x-auth-token' = $authToken } 
    }

    $sessionParams += $skipCertParams

    return @{
        'endpoint' = $Endpoint
        'token'    = $authToken
        'version'  = $Version
        'params'   = $sessionParams
        'url'      = "https://$($Endpoint)/api/$($Version)/"
    }
}

function Remove-Pfa2Session {
    param (
        [parameter(Mandatory, ValueFromPipeline)]
        [hashtable]$session
    )

    Invoke-Pfa2Operation -session $session -query 'logout' | Out-Null
}

function Invoke-Pfa2Operation { 
    param (
        [parameter(Mandatory, ValueFromPipeline)]
        [hashtable]$session,
        [string]$query,
        [hashtable]$rest = @{},
        [string]$method = 'Post'
    )

    $p = $session.params
    Invoke-RestMethod -Method $method -Uri ($session.url + $query) @rest @p
}

function Set-Pfa2SkipCertificateCheck {
    Add-Type @"
public class Pfa2
{
    public static System.Net.Security.RemoteCertificateValidationCallback SkipCertificateCheck
    {
        get { return delegate { return true; }; }
    }
}
"@
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [Pfa2]::SkipCertificateCheck
}