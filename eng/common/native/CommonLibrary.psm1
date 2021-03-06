<#
.SYNOPSIS
Helper module to install an archive to a directory

.DESCRIPTION
Helper module to download and extract an archive to a specified directory

.PARAMETER Uri
Uri of artifact to download

.PARAMETER InstallDirectory
Directory to extract artifact contents to

.PARAMETER Force
Force download / extraction if file or contents already exist. Default = False

.PARAMETER DownloadRetries
Total number of retry attempts. Default = 5

.PARAMETER RetryWaitTimeInSeconds
Wait time between retry attempts in seconds. Default = 30

.NOTES
Returns False if download or extraction fail, True otherwise
#>
function DownloadAndExtract {
  [CmdletBinding(PositionalBinding=$false)]
  Param (
    [Parameter(Mandatory=$True)]
    [string] $Uri,
    [Parameter(Mandatory=$True)]
    [string] $InstallDirectory,
    [switch] $Force = $False,
    [int] $DownloadRetries = 5,
    [int] $RetryWaitTimeInSeconds = 30
  )
  # Define verbose switch if undefined
  $Verbose = $VerbosePreference -Eq "Continue"
  
  $TempToolPath = CommonLibrary\Get-TempPathFilename -Path $Uri

  # Download native tool
  $DownloadStatus = CommonLibrary\Get-File -Uri $Uri `
                                           -Path $TempToolPath `
                                           -DownloadRetries $DownloadRetries `
                                           -RetryWaitTimeInSeconds $RetryWaitTimeInSeconds `
                                           -Force:$Force `
                                           -Verbose:$Verbose

  if ($DownloadStatus -Eq $False) {
    Write-Error "Download failed"
    return $False
  }

  # Extract native tool
  $UnzipStatus = CommonLibrary\Expand-Zip -ZipPath $TempToolPath `
                                          -OutputDirectory $InstallDirectory `
                                          -Force:$Force `
                                          -Verbose:$Verbose
  
  if ($UnzipStatus -Eq $False) {
    Write-Error "Unzip failed"
    return $False
  }
  return $True
}

<#
.SYNOPSIS
Download a file, retry on failure

.DESCRIPTION
Download specified file and retry if attempt fails

.PARAMETER Uri
Uri of file to download. If Uri is a local path, the file will be copied instead of downloaded

.PARAMETER Path
Path to download or copy uri file to

.PARAMETER Force
Overwrite existing file if present. Default = False

.PARAMETER DownloadRetries
Total number of retry attempts. Default = 5

.PARAMETER RetryWaitTimeInSeconds
Wait time between retry attempts in seconds Default = 30

#>
function Get-File {
  [CmdletBinding(PositionalBinding=$false)]
  Param (
    [Parameter(Mandatory=$True)]
    [string] $Uri,
    [Parameter(Mandatory=$True)]
    [string] $Path,
    [int] $DownloadRetries = 5,
    [int] $RetryWaitTimeInSeconds = 30,
    [switch] $Force = $False
  )
  $Attempt = 0

  if ($Force) {
    if (Test-Path $Path) {
      Remove-Item $Path -Force
    }
  }
  if (Test-Path $Path) {
    Write-Host "File '$Path' already exists, skipping download"
    return $True
  }

  $DownloadDirectory = Split-Path -ErrorAction Ignore -Path "$Path" -Parent
  if (-Not (Test-Path $DownloadDirectory)) {
    New-Item -path $DownloadDirectory -force -itemType "Directory" | Out-Null
  }

  if (Test-Path -IsValid -Path $Uri) {
    Write-Verbose "'$Uri' is a file path, copying file to '$Path'"
    Copy-Item -Path $Uri -Destination $Path
    return $?
  }
  else {
    Write-Verbose "Downloading $Uri"
    while($Attempt -Lt $DownloadRetries)
    {
      try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Path
        Write-Verbose "Downloaded to '$Path'"
        return $True
      }
      catch {
        $Attempt++
        if ($Attempt -Lt $DownloadRetries) {
          $AttemptsLeft = $DownloadRetries - $Attempt
          Write-Warning "Download failed, $AttemptsLeft attempts remaining, will retry in $RetryWaitTimeInSeconds seconds"
          Start-Sleep -Seconds $RetryWaitTimeInSeconds
        }
        else {
          Write-Error $_
          Write-Error $_.Exception
        }
      }
    }
  }

  return $False
}

<#
.SYNOPSIS
Generate a shim for a native tool

.DESCRIPTION
Creates a wrapper script (shim) that passes arguments forward to native tool assembly

.PARAMETER ShimPath
Path to shim file

.PARAMETER ToolFilePath
Path to file that shim forwards to

.PARAMETER Force
Replace shim if already present.  Default = False

.NOTES
Returns $True if generating shim succeeds, $False otherwise
#>
function New-ScriptShim {
  [CmdletBinding(PositionalBinding=$false)]
  Param (
    [Parameter(Mandatory=$True)]
    [string] $ShimPath,
    [Parameter(Mandatory=$True)]
    [string] $ToolFilePath,
    [switch] $Force
  )
  try {
    Write-Verbose "Generating '$ShimPath' shim"

    if ((Test-Path $ShimPath) -And (-Not $Force)) {
      Write-Error "$ShimPath already exists"
      return $False
    }

    if (-Not (Test-Path $ToolFilePath)){
      Write-Error "Specified tool file path '$ToolFilePath' does not exist"
      return $False
    }

    $ShimContents = "@echo off`n"
    $ShimContents += "setlocal enableextensions enabledelayedexpansion`n"
    $ShimContents += "set SHIMARGS=`n"
    $ShimContents += "for %%x in (%*) do (set SHIMARGS=!SHIMARGS! `"%%~x`")`n"
    $ShimContents += "`"$ToolFilePath`" %SHIMARGS%`n"
    $ShimContents += "endlocal"

    # Write shim file
    $ShimContents | Out-File $ShimPath -Encoding "ASCII"

    if (-Not $?) {
      Write-Error "Failed to generate shim"
      return $False
    }
    return $True
  }
  catch {
    Write-Host $_
    Write-Host $_.Exception
    return $False
  }
}

<#
.SYNOPSIS
Returns the machine architecture of the host machine

.NOTES
Returns 'x64' on 64 bit machines
 Returns 'x86' on 32 bit machines
#>
function Get-MachineArchitecture {
  $ProcessorArchitecture = $Env:PROCESSOR_ARCHITECTURE
  $ProcessorArchitectureW6432 = $Env:PROCESSOR_ARCHITEW6432
  if($ProcessorArchitecture -Eq "X86")
  {
    if(($ProcessorArchitectureW6432 -Eq "") -Or
       ($ProcessorArchitectureW6432 -Eq "X86")) {
        return "x86"
    }
    $ProcessorArchitecture = $ProcessorArchitectureW6432
  }
  if (($ProcessorArchitecture -Eq "AMD64") -Or
      ($ProcessorArchitecture -Eq "IA64") -Or
      ($ProcessorArchitecture -Eq "ARM64")) {
    return "x64"
  }
  return "x86"
}

<#
.SYNOPSIS
Get the name of a temporary folder under the native install directory
#>
function Get-TempDirectory {
  return Join-Path (Get-NativeInstallDirectory) "temp/"
}

function Get-TempPathFilename {
  [CmdletBinding(PositionalBinding=$false)]
  Param (
    [Parameter(Mandatory=$True)]
    [string] $Path
  )
  $TempDir = CommonLibrary\Get-TempDirectory
  $TempFilename = Split-Path $Path -leaf
  $TempPath = Join-Path $TempDir $TempFilename
  return $TempPath
}

<#
.SYNOPSIS
Returns the base directory to use for native tool installation

.NOTES
Returns the value of the NETCOREENG_INSTALL_DIRECTORY if that environment variable
is set, or otherwise returns an install directory under the %USERPROFILE%
#>
function Get-NativeInstallDirectory {
  $InstallDir = $Env:NETCOREENG_INSTALL_DIRECTORY
  if (!$InstallDir) {
    $InstallDir = Join-Path $Env:USERPROFILE ".netcoreeng/native/"
  }
  return $InstallDir
}

<#
.SYNOPSIS
Unzip an archive

.DESCRIPTION
Powershell module to unzip an archive to a specified directory

.PARAMETER ZipPath (Required)
Path to archive to unzip

.PARAMETER OutputDirectory (Required)
Output directory for archive contents

.PARAMETER Force
Overwrite output directory contents if they already exist

.NOTES
- Returns True and does not perform an extraction if output directory already exists but Overwrite is not True.
- Returns True if unzip operation is successful
- Returns False if Overwrite is True and it is unable to remove contents of OutputDirectory
- Returns False if unable to extract zip archive
#>
function Expand-Zip {
  [CmdletBinding(PositionalBinding=$false)]
  Param (
    [Parameter(Mandatory=$True)]
    [string] $ZipPath,
    [Parameter(Mandatory=$True)]
    [string] $OutputDirectory,
    [switch] $Force
  )

  Write-Verbose "Extracting '$ZipPath' to '$OutputDirectory'"
  try {
    if ((Test-Path $OutputDirectory) -And (-Not $Force)) {
      Write-Host "Directory '$OutputDirectory' already exists, skipping extract"
      return $True
    }
    if (Test-Path $OutputDirectory) {
      Write-Verbose "'Force' is 'True', but '$OutputDirectory' exists, removing directory"
      Remove-Item $OutputDirectory -Force -Recurse
      if ($? -Eq $False) {
        Write-Error "Unable to remove '$OutputDirectory'"
        return $False
      }
    }
    if (-Not (Test-Path $OutputDirectory)) {
      New-Item -path $OutputDirectory -Force -itemType "Directory" | Out-Null
    }

    Add-Type -assembly "system.io.compression.filesystem"
    [io.compression.zipfile]::ExtractToDirectory("$ZipPath", "$OutputDirectory")
    if ($? -Eq $False) {
      Write-Error "Unable to extract '$ZipPath'"
      return $False
    }
  }
  catch {
    Write-Host $_
    Write-Host $_.Exception

    return $False
  }
  return $True
}

export-modulemember -function DownloadAndExtract
export-modulemember -function Expand-Zip
export-modulemember -function Get-File
export-modulemember -function Get-MachineArchitecture
export-modulemember -function Get-NativeInstallDirectory
export-modulemember -function Get-TempDirectory
export-modulemember -function Get-TempPathFilename
export-modulemember -function New-ScriptShim
