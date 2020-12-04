function Exec-PipedProcess {
<#
.Synopsis
パイプで接続した複数のプロセスを実行する。
.Example
gpresult.exe /z の結果を取得する。
$stdout = New-Object System.IO.MemoryStream
$ProcessStartInfo = @()
$ProcessStartInfo += New-Object System.Diagnostics.ProcessStartInfo -Property @{
    FileName       = 'gpresult.exe'
    Arguments      = @('/z')
    CreateNoWindow = $true
}
$result = Exec-PipedProcess $ProcessStartInfo $null $stdout
[Console]::OutputEncoding.GetString($stdout.GetBuffer(), 0, $stdout.Length)
.Example
openssl.exe enc -e -aes-256-cbc -pass pass:password < "plainsecret.original.txt" | openssl.exe enc -d -aes-256-cbc -pass pass:password > "plainsecret.decrypted.txt" に相当する。
$infile  = 'plainsecret.original.txt'
$outfile = "plainsecret.decrypted.txt"
$stdin  = New-Object System.IO.FileStream $infile, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read)
$stdout = New-Object System.IO.FileStream $outfile, ([System.IO.FileMode]::Create), ([System.IO.FileAccess]::Write)
$ProcessStartInfo = @()
$ProcessStartInfo += New-Object System.Diagnostics.ProcessStartInfo -Property @{
    FileName       = 'openssl.exe'
    Arguments      = @('enc', '-e', '-aes-256-cbc', '-pass', 'pass:password')
    CreateNoWindow = $true
}
$ProcessStartInfo += New-Object System.Diagnostics.ProcessStartInfo -Property @{
    FileName       = 'openssl.exe'
    Arguments      = @('enc', '-d', '-aes-256-cbc', '-pass', 'pass:password')
    CreateNoWindow = $true
}
$result = Exec-PipedProcess $ProcessStartInfo $stdin $stdout
$stdin.Dispose()
$stdout.Dispose()
.Example
標準エラー出力と ExitCode (ERRORLEVEL) の取得方法
$stdout = New-Object System.IO.MemoryStream
$ProcessStartInfo = @()
$ProcessStartInfo += New-Object System.Diagnostics.ProcessStartInfo -Property @{
    FileName              = 'fc.exe'
    Arguments             = @('c:\invalidfilename.txt', 'c:\comparetarget.txt')
    CreateNoWindow        = $true
    RedirectStandardError = $true
}
$result = Exec-PipedProcess $ProcessStartInfo $null $stdout
$result |% {
    "exit code is $($_.Process.ExitCode)"
    $err = $_.ErrPump.Stream
    [Console]::OutputEncoding.GetString($err.GetBuffer(), 0, $err.Length)
}
.Parameter StartInfoList
ProcessStartInfo の配列。
.Parameter Souce
最初のプロセスの標準入力へ与えるストリーム。$null または省略可能。
.Parameter Destination
最後のプロセスの標準出力を受け取るストリーム。$null または省略可能。
.Parameter BufferLength
パイプ間を送受するバッファのバイト数。省略時は 512 バイト。
.NOTES
MIT License

Copyright (c) 2020 Isao Sato

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#>
    param(
        [System.Diagnostics.ProcessStartInfo[]] $StartInfoList,
        [System.IO.Stream] $Source,
        [System.IO.Stream] $Destination,
        [Int32] $BufferLength = 512)
    
    New-Variable -Name cbbuffer -Value $BufferLength -Option Constant
    $processlist = New-Object System.Diagnostics.Process[] $StartInfoList.Length
    
    $pumpcount = $StartInfoList.Length -1 +1
    if($Source) {
        $StartInfoList[0].RedirectStandardInput = $true
        ++$pumpcount
    }
    for($index = 1; $index -lt $StartInfoList.Length; ++$index) {
        $StartInfoList[$index].RedirectStandardInput = $true
    }
    for($index = 0; $index -lt ($StartInfoList.Length -1); ++$index) {
        $StartInfoList[$index].RedirectStandardOutput = $true
    }
    if($Destination) {
        $StartInfoList[-1].RedirectStandardOutput = $true
        ++$pumpcount
    }
    for($index = 0; $index -lt $StartInfoList.Length; ++$index) {
        if($StartInfoList[$index].RedirectStandardError) {
            ++$pumpcount
        }
        $startinfo = $StartInfoList[$index]
        $startinfo.UseShellExecute = $false
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startinfo
        $process.Start() | Out-Null
        $processlist[$index] = $process
    }
    
    $psrs = $null
    try {
        $is = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $is.ApartmentState = [System.Threading.ApartmentState]::MTA
        $is.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry 'cbbuffer', $cbbuffer, $null, Constant))
        $psrs = [RunspaceFactory]::CreateRunspacePool($pumpcount, $pumpcount, $is, $host)
        $psrs.Open()
        $streampumper = {
            param([System.IO.Stream] $Reader, [System.IO.Stream] $Writer, [switch] $CloseWriter)
            $lpbuffer = New-Object Byte[] $cbbuffer
            while((&{$global:readlength = $Reader.Read($lpbuffer, 0, $cbbuffer); $readlength -gt 0})){
                $Writer.Write($lpbuffer, 0, $readlength)
            }
            if($CloseWriter.IsPresent) {
                $Writer.Close()
            }
        }
        
        $pumplist = New-Object psobject[] ($StartInfoList.Length +1)
        $errpumplist = New-Object psobject[] $StartInfoList.Length
        try {
            for($index = 0; $index -lt $StartInfoList.Length; ++$index) {
                if($processlist[$index].StartInfo.RedirectStandardError) {
                    $errbuffer = New-Object System.IO.MemoryStream
                    
                    $pump = [System.Management.Automation.PowerShell]::Create()
                    $pump.RunspacePool = $psrs
                    $pump.AddScript($streampumper) | Out-Null
                    $pump.AddParameter('Reader', $processlist[$index].StandardError.BaseStream) | Out-Null
                    $pump.AddParameter('Writer', $errbuffer) | Out-Null
                    $sync = $pump.BeginInvoke()
                    $errpumplist[$index] = New-Object psobject -Property @{
                        PowerShell  = $pump
                        AsyncResult = $sync
                        Stream      = $errbuffer
                    }
                }
            }
            if($processlist[0].StartInfo.RedirectStandardInput) {
                $pump = [System.Management.Automation.PowerShell]::Create()
                $pump.RunspacePool = $psrs
                $pump.AddScript($streampumper) | Out-Null
                $pump.AddParameter('Reader', $Source) | Out-Null
                $pump.AddParameter('Writer', $processlist[0].StandardInput.BaseStream) | Out-Null
                $pump.AddParameter('CloseWriter', $true) | Out-Null
                $sync = $pump.BeginInvoke()
                $pumplist[0] = New-Object psobject -Property @{
                    PowerShell  = $pump
                    AsyncResult = $sync
                }
            }
            for($index = 1; $index -lt $StartInfoList.Length; ++$index) {
                $pump = [System.Management.Automation.PowerShell]::Create()
                $pump.RunspacePool = $psrs
                $pump.AddScript($streampumper) | Out-Null
                $pump.AddParameter('Reader', $processlist[$index -1].StandardOutput.BaseStream) | Out-Null
                $pump.AddParameter('Writer', $processlist[$index].StandardInput.BaseStream) | Out-Null
                $pump.AddParameter('CloseWriter', $true) | Out-Null
                $sync = $pump.BeginInvoke()
                $pumplist[$index] = New-Object psobject -Property @{
                    PowerShell  = $pump
                    AsyncResult = $sync
                }
            }
            if($processlist[-1].StartInfo.RedirectStandardOutput) {
                $pump = [System.Management.Automation.PowerShell]::Create()
                $pump.RunspacePool = $psrs
                $pump.AddScript($streampumper) | Out-Null
                $pump.AddParameter('Reader', $processlist[-1].StandardOutput.BaseStream) | Out-Null
                $pump.AddParameter('Writer', $Destination) | Out-Null
                $pump.AddParameter('CloseWriter', $false) | Out-Null
                $sync = $pump.BeginInvoke()
                $pumplist[-1] = New-Object psobject -Property @{
                    PowerShell  = $pump
                    AsyncResult = $sync
                }
            }
            
            if($pumpcount -gt 1) {
                $waithandlelist = New-Object System.Collections.Generic.List[System.Threading.WaitHandle]
                $pumplist |? {$_ -ne $null} |% {
                    $waithandlelist.Add($_.AsyncResult.AsyncWaitHandle)
                }
                
                $waitasync = [System.Management.Automation.PowerShell]::Create()
                $waitasync.RunspacePool = $psrs
                $waitasync.AddScript({
                    param([System.Threading.WaitHandle[]] $waithandlelist)
                    [System.Threading.WaitHandle]::WaitAll($waithandlelist)
                }) | Out-Null
                $waitasync.AddParameter('waithandlelist', $waithandlelist) | Out-Null
                $waitasync.Invoke() | Out-Null
                $waitasync.Dispose()
                
                $pumplist |? {$_ -ne $null} |% {
                    $_.PowerShell.EndInvoke($_.AsyncResult)
                }
                $errpumplist |? {$_ -ne $null} |% {
                    $_.PowerShell.EndInvoke($_.AsyncResult)
                }
            }
        } finally {
            $pumplist |? {$_ -ne $null} |% {
                $_.PowerShell.Dispose()
            }
            $errpumplist |? {$_ -ne $null} |% {
                $_.PowerShell.Dispose()
            }
        }
        $result = New-Object System.Collections.Generic.List[psobject]
        for($index = 0; $index -lt $StartInfoList.Length; ++$index) {
            $result.Add(
                (New-Object psobject -Property @{
                    Process = $processlist[$index]
                    InPump  = $pumplist[$index]
                    OutPump = $pumplist[$index+1]
                    ErrPump = $errpumplist[$index]
                }))
        }
        Write-Output $result
    } finally {
        if($psrs){$psrs.Dispose()}
    }
}
