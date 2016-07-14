#####################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
#####################################################################


<#
.Synopsis
 Verify that a VM with low memory pressure looses memory when another VM has a high memory demand.

 Description:
   Verify a VM with low memory pressure and lots of memory looses memory when a starved VM has a
   high memory demand.

   3 VMs are required for this test.

   The testParams have the format of:

      vmName=Name of a VM, enable=[yes|no], minMem= (decimal) [MB|GB|%], maxMem=(decimal) [MB|GB|%],
      startupMem=(decimal) [MB|GB|%], memWeight=(0 < decimal < 100)

   Only the vmName param is taken into consideration. This needs to appear at least twice for
   the test to start.

      Tries=(decimal)
       This controls the number of times the script tries to start the second VM. If not set, a default
       value of 3 is set.
       This is necessary because Hyper-V usually removes memory from a VM only when a second one applies pressure.
       However, the second VM can fail to start while memory is removed from the first.
       There is a 30 second timeout between tries, so 3 tries is a conservative value.

   The following is an example of a testParam for configuring Dynamic Memory

       "Tries=3;vmName=sles11x64sp3;enable=yes;minMem=512MB;maxMem=80%;startupMem=80%;memWeight=0;
       vmName=sles11x64sp3_2;enable=yes;minMem=512MB;maxMem=25%;startupMem=25%;memWeight=0"

   All scripts must return a boolean to indicate if the script completed successfully or not.

   .Parameter vmName
    Name of the VM to remove NIC from .

    .Parameter hvServer
    Name of the Hyper-V server hosting the VM.

    .Parameter testParams
    Test data for this test case

    .Example
    setupscripts\DM_RemoveUnderPressure.ps1 -vmName nameOfVM -hvServer localhost -testParams 'sshKey=KEY;ipv4=IPAddress;rootDir=path\to\dir;vmName=NameOfVM1
        vmName=NameOfVM2;vmName=NameOfVM3'
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

Set-PSDebug -Strict

function checkStressapptest([String]$conIpv4, [String]$sshKey)
{


    $cmdToVM = @"
#!/bin/bash
        command -v stressapptest
        sts=`$?
        if [ 0 -ne `$sts ]; then
            echo "Stressapptest is not installed! Please install it before running the memory stress tests." >> /root/HotAdd.log 2>&1
        else
            echo "Stressapptest is installed! Will begin running memory stress tests shortly." >> /root/HotAdd.log 2>&1
        fi
        echo "CheckStressappreturned `$sts"
        exit `$sts
"@

    #"pingVMs: sendig command to vm: $cmdToVM"
    $filename = "CheckStressapp.sh"

    # check for file
    if (Test-Path ".\${filename}")
    {
        Remove-Item ".\${filename}"
    }

    Add-Content $filename "$cmdToVM"

    # send file
    $retVal = SendFileToVM $conIpv4 $sshKey $filename "/root/${$filename}"

    # delete file unless the Leave_trail param was set to yes.
    if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
    {
        Remove-Item ".\${filename}"
    }

    # check the return Value of SendFileToVM
    if (-not $retVal)
    {
        return $false
    }

    # execute command
    $retVal = SendCommandToVM $conIpv4 $sshKey "cd /root && chmod u+x ${filename} && sed -i 's/\r//g' ${filename} && ./${filename}"

    return $retVal
}

# we need a scriptblock in order to pass this function to start-job
$scriptBlock = {
  # function which $memMB MB of memory on VM with IP $conIpv4 with stresstestapp
  function ConsumeMemory([String]$conIpv4, [String]$sshKey, [String]$rootDir,[int64]$memMB,[int64]$chunckSize,[int]$duration)
  {

  # because function is called as job, setup rootDir and source TCUtils again
  if (Test-Path $rootDir)
  {
    Set-Location -Path $rootDir
    if (-not $?)
    {
    "Error: Could not change directory to $rootDir !"
    return $false
    }
    "Changed working directory to $rootDir"
  }
  else
  {
    "Error: RootDir = $rootDir is not a valid path"
    return $false
  }

  # Source TCUitls.ps1 for getipv4 and other functions
  if (Test-Path ".\setupScripts\TCUtils.ps1")
  {
    . .\setupScripts\TCUtils.ps1
    "Sourced TCUtils.ps1"
  }
  else
  {
    "Error: Could not find setupScripts\TCUtils.ps1"
    return $false
  }


      $cmdToVM = @"
#!/bin/bash
        if [ ! -e /proc/meminfo ]; then
          echo ConsumeMemory: no meminfo found. Make sure /proc is mounted >> /root/RemoveUnderPressure.log 2>&1
          exit 100
        fi

        rm ~/HotAddErrors.log -f
        dos2unix check_traces.sh
        chmod +x check_traces.sh
        ./check_traces.sh &
        
        __totalMem=`$(cat /proc/meminfo | grep -i MemTotal | awk '{ print `$2 }')
        __totalMem=`$((__totalMem/1024))
        echo ConsumeMemory: Total Memory found `$__totalMem MB >> /root/RemoveUnderPressure.log 2>&1
        if [ $memMB -ge `$__totalMem ];then
          echo ConsumeMemory: memory to consume $memMB is greater than total Memory `$__totalMem >> /root/RemoveUnderPressure.log 2>&1
          exit 200
        fi
        __ChunkInMB=$chunckSize
        if [ $memMB -ge `$__ChunkInMB ]; then
          #for-loop starts from 0
          __iterations=`$(($memMB/__ChunkInMB))
        else
          __iterations=1
          __ChunkInMB=$memMB
        fi
        echo "Going to start `$__iterations instance(s) of stresstestapp each consuming `$__ChunkInMB MB memory" >> /root/RemoveUnderPressure.log 2>&1
        __start=`$(date +%s)
        for ((i=0; i < `$__iterations; i++)); do
          echo Starting instance `$i of stressapptest >> /root/RemoveUnderPressure.stressapptest 2>&1
          stressapptest -M `$__ChunkInMB -s $duration >> /root/RemoveUnderPressure.stressapptest 2>&1 &
        done
        echo "Waiting for jobs to finish" >> /root/RemoveUnderPressure.log 2>&1
        wait
        __end=`$(date +%s)
        echo "All jobs finished in `$((__end-__start)) seconds" >> /root/RemoveUnderPressure.log 2>&1
        exit 0
"@

    #"pingVMs: sending command to vm: $cmdToVM"
    $filename = "ConsumeMemOn${conIpv4}.sh"

    # check for file
    if (Test-Path ".\${filename}")
    {
      Remove-Item ".\${filename}"
    }

    Add-Content $filename "$cmdToVM"

    # send file
    $retVal = SendFileToVM $conIpv4 $sshKey $filename "/root/${filename}"

    # delete file unless the Leave_trail param was set to yes.
    if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
    {
      Remove-Item ".\${filename}"
    }

    # check the return Value of SendFileToVM
    if (-not $retVal[-1])
    {
      return $false
    }

    # execute command as job
    $retVal = SendCommandToVM $conIpv4 $sshKey "cd /root && chmod u+x ${filename} && sed -i 's/\r//g' ${filename} && ./${filename}"

    return $retVal

  }
}


#######################################################################
#
# Main script body
#
#######################################################################

#
# Check input arguments
#
if ($vmName -eq $null)
{
    "Error: VM name is null"
    return $False
}

if ($hvServer -eq $null)
{
    "Error: hvServer is null"
    return $False
}

if ($testParams -eq $null)
{
    "Error: testParams is null"
    return $False
}

# Write out test Params
$testParams

# sshKey used to authenticate ssh connection and send commands
$sshKey = $null

# IP Address of first VM
$ipv4 = $null

# IP Address of second VM
$vm2ipv4 = $null

# Name of first VM
$vm1Name = $null

# Name of second VM
$vm2Name = $null

# string array vmNames
[String[]]$vmNames = @()

# number of tries
[int]$tries = 0

# default number of tries
Set-Variable defaultTries -option Constant -value 10

# change working directory to root dir
$testParams -match "RootDir=([^;]+)"
if (-not $?)
{
  "Mandatory param RootDir=Path; not found!"
  return $false
}
$rootDir = $Matches[1]

if (Test-Path $rootDir)
{
  Set-Location -Path $rootDir
  if (-not $?)
  {
    "Error: Could not change directory to $rootDir !"
    return $false
  }
  "Changed working directory to $rootDir"
}
else
{
  "Error: RootDir = $rootDir is not a valid path"
  return $false
}

# Source TCUitls.ps1 for getipv4 and other functions
if (Test-Path ".\setupScripts\TCUtils.ps1")
{
  . .\setupScripts\TCUtils.ps1
}
else
{
  "Error: Could not find setupScripts\TCUtils.ps1"
  return $false
}

$params = $testParams.Split(";")
foreach ($p in $params)
{
    $fields = $p.Split("=")

    switch ($fields[0].Trim())
    {
      "vmName"  { $vmNames = $vmNames + $fields[1].Trim() }
      "ipv4"    { $ipv4    = $fields[1].Trim() }
      "sshKey"  { $sshKey  = $fields[1].Trim() }
      "tries"  { $tries  = $fields[1].Trim() }
    }

}

if (-not $sshKey)
{
  "Error: Please pass the sshKey to the script."
  return $false
}

if ($tries -le 0)
{
  $tries = $defaultTries
}

if ($vmNames.count -lt 3)
{
  "Error: three VMs are necessary for the StartupLowCompete test."
  return $false
}

$vm1Name = $vmNames[0]
$vm2Name = $vmNames[1]
$vm3Name = $vmNames[2]

if ($vm1Name -notlike $vmName)
{
  if ($vm2Name -like $vmName)
  {
    # switch vm1Name with vm2Name
    $vm1Name = $vmNames[1]
    $vm2Name = $vmNames[0]

  }
  elseif ($vm3Name -like $vmName)
  {
    # switch vm1Name with vm3Name
    $vm1Name = $vmNames[2]
    $vm3Name = $vmNames[0]
  }
  else
  {
    "Error: The first vmName testparam must be the same as the vmname from the vm section in the xml."
    return $false
  }
}

$vm1 = Get-VM -Name $vm1Name -ComputerName $hvServer -ErrorAction SilentlyContinue

if (-not $vm1)
{
  "Error: VM $vm1Name does not exist"
  return $false
}

$vm2 = Get-VM -Name $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue

if (-not $vm2)
{
  "Error: VM $vm2Name does not exist"
  return $false
}

$vm3 = Get-VM -Name $vm3Name -ComputerName $hvServer -ErrorAction SilentlyContinue

if (-not $vm3)
{
  "Error: VM $vm3Name does not exist"
  return $false
}

# determine which is vm2 and whih is vm3 based on memory weight

$vm2MemWeight = (Get-VMMemory -VM $vm2).Priority

if (-not $?)
{
  "Error: Unable to get $vm2Name memory weight."
  return $false
}

$vm3MemWeight = (Get-VMMemory -VM $vm3).Priority

if (-not $?)
{
  "Error: Unable to get $vm3Name memory weight."
  return $false
}

if ($vm3MemWeight -eq $vm2MemWeight)
{
  "Error: $vm3Name must have a higher memory weight than $vm2Name"
  return $false
}

if ($vm3MemWeight -lt $vm2MemWeight)
{
  # switch vm2 with vm3
  $aux = $vm2Name
  $vm2Name = $vm3Name
  $vm3Name = $aux

  $vm2 = Get-VM -Name $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue

  if (-not $vm2)
  {
    "Error: VM $vm2Name does not exist anymore"
    return $false
  }

  $vm3 = Get-VM -Name $vm3Name -ComputerName $hvServer -ErrorAction SilentlyContinue

  if (-not $vm3)
  {
    "Error: VM $vm3Name does not exist anymore"
    return $false
  }

}

#
# LIS Started VM1, so start VM2
#

if (Get-VM -Name $vm2Name -ComputerName $hvServer |  Where { $_.State -notlike "Running" })
{

  [int]$i = 0
  # try to start VM2
  for ($i=0; $i -lt $tries; $i++)
  {

    Start-VM -Name $vm2Name -ComputerName $hvServer -ErrorAction SilentlyContinue
    if (-not $?)
    {
      "Warning: Unable to start VM ${vm2Name} on attempt $i"
    }
    else
    {
      $i = 0
      break
    }

    Start-sleep -s 30
  }

  if ($i -ge $tries)
  {
    "Error: Unable to start VM2 after $tries attempts"
    return $false
  }

}

# just to make sure vm2 started
if (Get-VM -Name $vm2Name -ComputerName $hvServer |  Where { $_.State -notlike "Running" })
{
  "Error: $vm2Names never started."
  return $false
}


# Check if stressapptest is installed
"Checking if Stressapptest is installed"

$retVal = checkStressapptest $ipv4 $sshKey

if (-not $retVal)
{
    "Stressapptest is not installed on $vm1Name! Please install it before running the memory stress tests."
    return $false
}

"Stressapptest is installed on $vm1Name! Will begin running memory stress tests shortly."



# get memory stats from vm1 and vm2
# wait up to 2 min for it

$sleepPeriod = 120 #seconds
# get VM1 and VM2's Memory
while ($sleepPeriod -gt 0)
{

  [int64]$vm1BeforeAssigned = ($vm1.MemoryAssigned/[int64]1048576)
  [int64]$vm1BeforeDemand = ($vm1.MemoryDemand/[int64]1048576)
  [int64]$vm2BeforeAssigned = ($vm2.MemoryAssigned/[int64]1048576)
  [int64]$vm2BeforeDemand = ($vm2.MemoryDemand/[int64]1048576)

  if ($vm1BeforeAssigned -gt 0 -and $vm1BeforeDemand -gt 0 -and $vm2BeforeAssigned -gt 0 -and $vm2BeforeDemand -gt 0)
  {
    break
  }

  $sleepPeriod-= 5
  start-sleep -s 5

}

if ($vm1BeforeAssigned -le 0 -or $vm1BeforeDemand -le 0)
{
  "Error: vm1 or vm2 reported 0 memory (assigned or demand)."
  Stop-VM -VMName $vm2name -ComputerName $hvServer -force
  return $False
}

"Memory stats after both $vm1Name and $vm2Name started reporting "
"  ${vm1Name}: assigned - $vm1BeforeAssigned | demand - $vm1BeforeDemand"
"  ${vm2Name}: assigned - $vm2BeforeAssigned | demand - $vm2BeforeDemand"

# get vm2 IP
$vm2ipv4 = GetIPv4 $vm2Name $hvServer

# Check if stressapptest is installed on 2nd VM
$retVal = checkStressapptest $vm2ipv4 $sshKey

if (-not $retVal)
{
    "Stressapptest is not installed on $vm2Name! Please install it before running the memory stress tests."
    return $false
}

"Stressapptest is installed on $vm2Name! Will begin running memory stress tests shortly."

# wait for ssh to start on vm2
$timeout = 30 #seconds
if (-not (WaitForVMToStartSSH $vm2ipv4 $timeout))
{
    "Error: VM ${vm2Name} never started ssh"
    Stop-VM -VMName $vm2name -ComputerName $hvServer -force
    return $False
}



# Calculate the amount of memory to be consumed on VM1 and VM2 with stresstestapp
[int64]$vm1ConsumeMem = (Get-VMMemory -VM $vm1).Maximum
[int64]$vm2ConsumeMem = (Get-VMMemory -VM $vm2).Maximum
# only consume 75% of max memory
$vm1ConsumeMem = ($vm1ConsumeMem / 4) * 3
$vm2ConsumeMem = ($vm2ConsumeMem / 4) * 3
# transform to MB
$vm1ConsumeMem /= 1MB
$vm2ConsumeMem /= 1MB

# standard chunks passed to stresstestapp
[int64]$vm1Chunks = 256 #MB
[int64]$vm2Chunks = 256 #MB
[int]$vm1Duration = 60 #seconds
[int]$vm2Duration = 90 #seconds

# Send Command to consume
$job1 = Start-Job -ScriptBlock { param($ip, $sshKey, $rootDir, $memMB, $memChunks, $duration) ConsumeMemory $ip $sshKey $rootDir $memMB $memChunks $duration } -InitializationScript $scriptBlock -ArgumentList($ipv4,$sshKey,$rootDir,$vm1ConsumeMem,$vm1Chunks,$vm1Duration)
if (-not $?)
{
  "Error: Unable to start job for creating pressure on $vm1Name"
  Stop-VM -VMName $vm2name -ComputerName $hvServer -force
  return $false
}

$job2 = Start-Job -ScriptBlock { param($ip, $sshKey, $rootDir, $memMB, $memChunks, $duration) ConsumeMemory $ip $sshKey $rootDir $memMB $memChunks $duration } -InitializationScript $scriptBlock -ArgumentList($vm2ipv4,$sshKey,$rootDir,$vm2ConsumeMem,$vm2Chunks,$vm2Duration)
if (-not $?)
{
  "Error: Unable to start job for creating pressure on $vm1Name"
  Stop-VM -VMName $vm2name -ComputerName $hvServer -force
  return $false
}

# sleep a few seconds so all stresstestapp processes start and the memory assigned/demand gets updated
start-sleep -s 10
# get memory stats for vm1 and vm2 just before vm3 starts
[int64]$vm1Assigned = ($vm1.MemoryAssigned/[int64]1048576)
[int64]$vm1Demand = ($vm1.MemoryDemand/[int64]1048576)
[int64]$vm2Assigned = ($vm2.MemoryAssigned/[int64]1048576)
[int64]$vm2Demand = ($vm2.MemoryDemand/[int64]1048576)

"Memory stats after $vm1Name and $vm2Name started stresstestapp, but before $vm3Name starts: "
"  ${vm1Name}: assigned - $vm1Assigned | demand - $vm1Demand"
"  ${vm2Name}: assigned - $vm2Assigned | demand - $vm2Demand"

# try to start VM3
for ($i=0; $i -lt $tries; $i++)
{

  # test to see that jobs haven't finished before VM3 started
  if ($job1.State -like "Completed")
  {
    "Error: VM1 $vm1Name finished the memory stresstest before VM3 started"
    Stop-VM -VMName $vm2name -ComputerName $hvServer -force
    return $false
  }

  if ($job2.State -like "Completed")
  {
    "Error: VM2 $vm2Name finished the memory stresstest before VM3 started"
    Stop-VM -VMName $vm2name -ComputerName $hvServer -force
    return $false
  }

  Start-VM -Name $vm3Name -ComputerName $hvServer -ErrorAction SilentlyContinue
  if (-not $?)
  {
    "Warning: Unable to start VM ${vm3Name} on attempt $i"
  }
  else
  {
    $i = 0
    break
  }

  Start-sleep -s 10
}

if ($i -ge $tries)
{
  "Error: Unable to start VM3 after $tries attempts"
  Stop-VM -VMName $vm2name -ComputerName $hvServer -force
  return $false
}

Start-sleep -s 30
# get memory stats after vm3 started
[int64]$vm1AfterAssigned = ($vm1.MemoryAssigned/[int64]1048576)
[int64]$vm1AfterDemand = ($vm1.MemoryDemand/[int64]1048576)
[int64]$vm2AfterAssigned = ($vm2.MemoryAssigned/[int64]1048576)
[int64]$vm2AfterDemand = ($vm2.MemoryDemand/[int64]1048576)

"Memory stats after $vm1Name and $vm2Name started stresstestapp and after $vm3Name started: "
"  ${vm1Name}: assigned - $vm1AfterAssigned | demand - $vm1AfterDemand"
"  ${vm2Name}: assigned - $vm2AfterAssigned | demand - $vm2AfterDemand"

# Wait for jobs to finish now and make sure they exited successfully
$totalTimeout = $timeout = 2000
$timeout = 0
$firstJobState = $false
$secondJobState = $false
$min = 0
while ($true)
{

  if ($job1.State -like "Completed" -and -not $firstJobState)
  {
    $firstJobState = $true
    $retVal = Receive-Job $job1
    if (-not $retVal[-1])
    {
      "Error: Consume Memory script returned false on VM1 $vm1Name"
      Stop-VM -VMName $vm2name -ComputerName $hvServer -force
      Stop-VM -VMName $vm3name -ComputerName $hvServer -force
      return $false
    }

    "Job1 finished in $min minutes."
  }

  if ($job2.State -like "Completed" -and -not $secondJobState)
  {
    $secondJobState = $true
    $retVal = Receive-Job $job1
    if (-not $retVal[-1])
    {
      "Error: Consume Memory script returned false on VM2 $vm2Name"
      Stop-VM -VMName $vm2name -ComputerName $hvServer -force
      Stop-VM -VMName $vm3name -ComputerName $hvServer -force
      return $false
    }
    $diff = $totalTimeout - $timeout
    "Job2 finished in $min minutes."
  }

  if ($firstJobState -and $secondJobState)
  {
    break
  }

  if ($timeout%60 -eq 0)
  {
   "$min minutes passed"
  $min += 1
  }

  $timeout += 5
  start-sleep -s 5
}

[int64]$vm1DeltaAssigned = [int64]$vm1Assigned - [int64]$vm1AfterAssigned
[int64]$vm1DeltaDemand = [int64]$vm1Demand - [int64]$vm1AfterDemand
[int64]$vm2DeltaAssigned = [int64]$vm2Assigned - [int64]$vm2AfterAssigned
[int64]$vm2DeltaDemand = [int64]$vm2Demand - [int64]$vm2AfterDemand

"Deltas for $vm1Name and $vm2Name after $vm3Name started:"
"  ${vm1Name}: deltaAssigned - $vm1DeltaAssigned | deltaDemand - $vm1DeltaDemand"
"  ${vm2Name}: deltaAssigned - $vm2DeltaAssigned | deltaDemand - $vm2DeltaDemand"

# check that at least one of the first two VMs has lower assigned memory as a result of VM3 starting
if ($vm1DeltaAssigned -le 0 -and $vm2DeltaAssigned -le 0)
{
  "Error: Neither $vm1Name, nor $vm2Name didn't lower their assigned memory in response to $vm3Name starting"
  Stop-VM -VMName $vm2name -ComputerName $hvServer -force
  Stop-VM -VMName $vm3name -ComputerName $hvServer -force
  return $false
}

[int64]$vm1EndAssigned = ($vm1.MemoryAssigned/[int64]1048576)
[int64]$vm1EndDemand = ($vm1.MemoryDemand/[int64]1048576)
[int64]$vm2EndAssigned = ($vm2.MemoryAssigned/[int64]1048576)
[int64]$vm2EndDemand = ($vm2.MemoryDemand/[int64]1048576)

$sleepPeriod = 120 #seconds
# get VM3's Memory
while ($sleepPeriod -gt 0)
{

  [int64]$vm3EndAssigned = ($vm3.MemoryAssigned/[int64]1048576)
  [int64]$vm3EndDemand = ($vm3.MemoryDemand/[int64]1048576)

  if ($vm3EndAssigned -gt 0 -and $vm3EndDemand -gt 0)
  {
    break
  }

  $sleepPeriod-= 5
  start-sleep -s 5

}

if ($vm1EndAssigned -le 0 -or $vm1EndDemand -le 0 -or $vm2EndAssigned -le 0 -or $vm2EndDemand -le 0 -or $vm3EndAssigned -le 0 -or $vm3EndDemand -le 0)
{
  "Error: One of the VMs reports 0 memory (assigned or demand) after vm3 $vm3Name started"
  Stop-VM -VMName $vm2name -ComputerName $hvServer -force
  Stop-VM -VMName $vm3name -ComputerName $hvServer -force
  return $false
}

# stop vm2 and vm3
Stop-VM -VMName $vm2name -ComputerName $hvServer -force
Stop-VM -VMName $vm3name -ComputerName $hvServer -force

# Verify if errors occured on guest
$isAlive = WaitForVMToStartKVP $vm1Name $hvServer 10
if (-not $isAlive){
  "Error: VM is unresponsive after running the memory stress test"
  return $false
}

$errorsOnGuest = echo y | bin\plink -i ssh\${sshKey} root@$ipv4 "cat HotAddErrors.log"
if (-not  [string]::IsNullOrEmpty($errorsOnGuest)){
  $errorsOnGuest
  return $false
}

# Everything ok
"Success: Memory was removed from a low priority VM with minimal memory pressure to a VM with high memory pressure!"
return $true