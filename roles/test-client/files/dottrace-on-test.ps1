<#
.SYNOPSIS
  Name: dottrace-on-test.ps1
  executes a dottrace snapshot against the test process and copies the
  snapshot file to and S3 bucket.
  
.DESCRIPTION
  executes a dottrace snapshot against the test process and copies the
  snapshot file to and S3 bucket and then deletes the local snapshot file.

.PARAMETER DotTraceExePathAndFilename
  Path and filename to the dottrace exe

.PARAMETER SnapshotFolder
  Path to the folder where snapshots are saved

.PARAMETER S3BucketName
  S3 Bucket name

.PARAMETER timeout
  timeout duration of the dottrace snapshot

.EXAMPLE
  .\dottrace-on-test.ps1 -DotTraceExePathAndFilename "C:\Users\faint.street\AppData\Local\JetBrains\Installations\dotTrace221\dottrace.exe" -SnapshotFolder "C:\snapshots"-S3BucketName "tf-dev-dot-trace-snapshots20220516200110905600000001"
  .\dottrace-on-test.ps1 -DotTraceExePathAndFilename "C:\Users\faint.street\AppData\Local\JetBrains\Installations\dotTrace221\dottrace.exe" -SnapshotFolder "C:\snapshots"-S3BucketName "tf-dev-dot-trace-snapshots20220516200110905600000001" -timeout 10
  .\dottrace-on-test.ps1 "C:\Users\faint.street\AppData\Local\JetBrains\Installations\dotTrace221\dottrace.exe" "C:\snapshots\testing" "tf-dev-dot-trace-snapshots20220516200110905600000001" 10
#>

Param(
    [Parameter(Mandatory=$True)]
    [ValidateNotNull()]
    [string] $DotTraceExePathAndFilename = "",

    [Parameter(Mandatory=$True)]
    [ValidateNotNull()]
    [string] $SnapshotFolder = "",

    [Parameter(Mandatory=$True)]
    [ValidateNotNull()]
    [string] $S3BucketName = "",

    [Parameter(Mandatory=$False)]
    [ValidateRange(1,300)]
    [int] $timeout = 15
)

# validate dotTrace exe
if (!(Test-Path $DotTraceExePathAndFilename -PathType Leaf)) 
{
    Write-Host "ERROR Does not Exist: $DotTraceExePathAndFilename" `
        -foregroundcolor red
    Exit 100
}

# validate S3 Bucket
if (!(Test-S3Bucket -BucketName $S3BucketName)) 
{
    Write-Host "ERROR Test-S3Bucket failed for S3 bucket: $S3BucketName" `
        -foregroundcolor red
    Exit 200
}


# validate snapshot folder
if (!(Test-Path $SnapshotFolder)) 
{
    #PowerShell Create directory if not exists
    New-Item $SnapshotFolder -ItemType Directory
}

# Copy log files to S3 bucket that are older than ageMinutes
$ageMinutes = -30
Write-Host "Copying *.log files older than $ageMinutes minutes from $SnapshotFolder" -foregroundcolor green
$results = Get-ChildItem $SnapshotFolder -Recurse -Include "*.log" | Where-Object {$_.Lastwritetime -lt (Get-Date).addminutes($ageMinutes)}
foreach ($fileObject in $results) {
  $fileName = $fileObject.name         
  $dateKey =  "{0:yyyy-MM-dd}" -f $fileObject.CreationTime
  Write-S3Object -BucketName $S3BucketName -Key "$dateKey\$fileName" -File $fileObject
}

# delete the log files that were copied to S3
Write-Host "Deleting *.log files older than $ageMinutes minutes from $SnapshotFolder" -foregroundcolor green
foreach ($fileObject in $results) {
    Remove-Item -Path $fileObject
}    

# retrieve the list of process ids and usernames for the specified processName
$processName = 'test'
try 
{
  $processList = Get-Process $processName -IncludeUserName -ErrorAction Stop `
  | Select-Object username,Id `
  | ForEach-Object {$_.username + "," + $_.Id}
  Write-Host "Process List count: " $processList.Count -foregroundcolor green
  foreach($processInfo in $processList)
  {
    $username, $processId = $processInfo -split ','
      Write-Host "Process Name: " $processName -foregroundcolor green
      Write-Host "ProcessId: " $processId -foregroundcolor green
  
      #remove domain
      $indexBackSlash = $username.indexof('\')    
      if($indexBackSlash -gt 0)
      {
          $username = $username.Substring($indexBackSlash + 1)
      }
      Write-Host "username: " $username -foregroundcolor green
  
      #generate snapshot filename
      $dateStringKey = Get-Date -Format "yyyy-MM-dd"
      $dateStringFilename = Get-Date -Format "yyyy-MM-ddTHHmmssfff"
      $usernameDateStringKey = "{0}-{1}" -f $username, $dateStringFilename
      $snapshotFileWoExtension = "snapshot-{0}" -f $usernameDateStringKey
      $snapshotFileWithExtension = $snapshotFileWoExtension+'.dtp' 
  
      #generate command line args
      $commandlineArgs = " attach {0} --save-to=`"{1}\{2}`" --timeout={3}s --profiling-type=Sampling" `
                   -f $processId,$SnapshotFolder,$snapshotFileWithExtension,$timeout 
  
      #call dottrace with a -Wait to make blocking
      Write-Host $DotTraceExePathAndFilename $commandlineArgs -foregroundcolor green
      Start-Process -NoNewWindow -FilePath $DotTraceExePathAndFilename -ArgumentList $commandlineArgs -Wait
  
      #copy snapshot file to S3 Bucket
      Write-Host "Copying $snapshotFileWoExtension.* to S3 Bucket: " $S3BucketName -foregroundcolor green
      $results = Get-ChildItem $SnapshotFolder -Recurse -Include "$snapshotFileWoExtension.*" 
      foreach ($fileObject in $results) { 
        $fileName = $fileObject.name         
        Write-S3Object -BucketName $S3BucketName -Key "$dateStringKey\$usernameDateStringKey\$fileName" -File $fileObject
      }
  
      # delete the trace files
      Write-Host "Deleting $snapshotFileWoExtension.* from $SnapshotFolder" -foregroundcolor green
      foreach ($fileObject in $results) {
        Remove-Item -Path $fileObject
      }    
  }
  Write-Host "Process List traversal completed" -foregroundcolor green
}
catch [System.Management.Automation.ActionPreferenceStopException]
{
  Write-Host "Error fetching process info for $processName : $_" -foregroundcolor red
  Exit 300
}
catch
{
  Write-Host "Error in process list traversal: $_" -foregroundcolor red
}
