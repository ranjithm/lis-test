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
 Verify that a VM that looses memory shuts down gracefully.

 Description:
   Verify a VM that looses memory due to another VM starting shuts down cleanly.
   2 VMs are required for this test.

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
    setupscripts\DM_CleanShutdown.ps1 -vmName nameOfVM -hvServer localhost -testParams 'sshKey=KEY;ipv4=IPAddress;rootDir=path\to\dir;vmName=NameOfVM1;vmName=NameOfVM2'
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

Set-PSDebug -Strict


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
Set-Variable defaultTries -option Constant -value 3

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

# iterator for vmName= parameters. Only 2 are taken into consideration
[int]$netAdapterNameIterator = 0

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

if ($tries -le 0)
{
  $tries = $defaultTries
}

if ($vmNames.count -lt 2)
{
  "Error: two VMs are necessary for the DM_CleanShutdown test."
  return $false
}

$vm1Name = $vmNames[0]
$vm2Name = $vmNames[1]

if ($vm1Name -notlike $vmName)
{
  if ($vm2Name -like $vmName)
  {
    # switch vm1Name with vm2Name
    $vm1Name = $vmNames[1]
    $vm2Name = $vmNames[0]
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

# sleep 1 minute for VM to start reporting demand
$sleepPeriod = 60

while ($sleepPeriod -gt 0)
{
  # get VM1's Memory
  [int64]$vm1BeforeAssigned = ($vm1.MemoryAssigned/1MB)
  [int64]$vm1BeforeDemand = ($vm1.MemoryDemand/1MB)

  if ($vm1BeforeAssigned -gt 0 -and $vm1BeforeDemand -gt 0)
  {
    break
  }

  $sleepPeriod -= 5
  start-sleep -s 5
}

if ($vm1BeforeAssigned -le 0)
{
  "Error: $vm1Name Assigned memory is 0"
  return $false
}

if ($vm1BeforeDemand -le 0)
{
  "Error: $vm1Name Memory demand is 0"
  return $false
}

"VM1 $vm1Name before assigned memory : $vm1BeforeAssigned"
"VM1 $vm1Name before memory demand: $vm1BeforeDemand"

#
# LIS Started VM1, so start VM2
#
Start-sleep -s 20
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

WaitForVMToReportDemand $vm1Name $hvServer $timeout

# get VM1's Memory
[int64]$vm1AfterAssigned = ($vm1.MemoryAssigned/1MB)
[int64]$vm1AfterDemand = ($vm1.MemoryDemand/1MB)

if ($vm1AfterAssigned -le 0)
{
  "Error: $vm1Name Assigned memory is 0 after $vm2Name started"
  Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
  return $false
}

if ($vm1AfterDemand -le 0)
{
  "Error: $vm1Name Memory demand is 0 after $vm2Name started"
  Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
  return $false
}

"VM1 $vm1Name after assigned memory : $vm1AfterAssigned"
"VM1 $vm1Name after memory demand: $vm1AfterDemand"

# Compute deltas
[int64]$vm1AssignedDelta = [int64]$vm1BeforeAssigned - [int64]$vm1AfterAssigned
[int64]$vm1DemandDelta = [int64]$vm1BeforeDemand - [int64]$vm1AfterDemand

"Deltas after vm2 $vm2Name started"
"  VM1 Assigned : ${vm1AssignedDelta}"
"  VM1 Demand   : ${vm1DemandDelta}"

# Assigned memory needs to have lowered after VM2 starts.
if ($vm1AssignedDelta -le 0)
{
  "Error: $vm1Name did not lower its assigned Memory after vm2 started."
  Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
  return $false
}

$timeout = 120 #seconds

Stop-VM -vmName $vm1Name -ComputerName $hvServer -force

if (-not $?)
{
  "Error: $vm1Name did not shutdown via Hyper-V"
  Stop-VM -vmName $vm2Name -ComputerName $hvServer -force
  return $false
}

# vm1 shut down gracefully via Hyper-V, so shutdown vm2
Stop-VM -vmName $vm2Name -ComputerName $hvServer -force

write-output $true
return $true