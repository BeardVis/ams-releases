#region Parameters
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$accountName,

    [Parameter(Mandatory=$true)]
    [string]$containerName,

    [Parameter(Mandatory=$true)]
    [string]$accountKey,

    [Parameter(Mandatory=$true)]
    [string[]]$filePaths
)
#endregion

#region Core Logic
try {
    Write-Host "Connecting to Azure Storage account..." -ForegroundColor Cyan

    $storageContext = New-AzStorageContext -StorageAccountName $accountName -StorageAccountKey $accountKey

    Add-Type -Assembly System.IO.Compression.FileSystem

    # Create a temporary directory for the files to be zipped
    $tempDir = New-Item -Path ([System.IO.Path]::GetTempPath()) -Name ([System.Guid]::NewGuid().ToString()) -ItemType Directory
    
    # Create the zip file path OUTSIDE of the tempDir to avoid file locking
    $zipFilePath = "$([System.IO.Path]::GetTempPath())\$([System.Guid]::NewGuid().ToString()).zip"

    Write-Host "Compressing files into a temporary zip archive..." -ForegroundColor Cyan
    # Copy files to the temporary directory to prepare for zipping
    $filesToZip = @()
    foreach ($filePath in $filePaths) {
        if ($filePath -like '*\*' -or $filePath -like '*') {
            $matchedFiles = Get-ChildItem -Path $filePath -Recurse | Where-Object { -not $_.PSIsContainer }
            $filesToZip += $matchedFiles
        }
        else {
            if (-not (Test-Path -Path $filePath)) {
                Write-Host "Error: File '$filePath' not found. Exiting." -ForegroundColor Red
                exit 1
            }
            $filesToZip += Get-Item -Path $filePath
        }
    }
    
    if ($filesToZip.Count -eq 0) {
        Write-Host "No files found to zip. Exiting." -ForegroundColor Yellow
        exit 0
    }

    foreach ($file in $filesToZip) {
        Copy-Item -Path $file.FullName -Destination $tempDir.FullName -ErrorAction Stop
    }

    # Create the zip archive from the temporary directory
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir.FullName, $zipFilePath)

    # Generate the unique blob name using a timestamp
    $blobName = "$(Get-Date -UFormat %s).zip"

    Write-Host "Uploading '$blobName' to Azure Blob Storage..." -ForegroundColor Cyan

    # Use Set-AzStorageBlobContent to upload the zip file.
    Set-AzStorageBlobContent -File $zipFilePath -Container $containerName -Blob $blobName -Context $storageContext

    Write-Host "File uploaded successfully!" -ForegroundColor Green

    Write-Host "Generating secure download URL..." -ForegroundColor Cyan

    # Get a reference to the uploaded blob
    $uploadedBlob = Get-AzStorageBlob -Blob $blobName -Container $containerName -Context $storageContext

    # Generate a SAS token for the blob.
    $sasToken = New-AzStorageBlobSASToken -Blob $blobName -Container $containerName -Context $storageContext -Permission r -ExpiryTime (Get-Date).AddMinutes(30)
    
    # Construct the full download URL
    $sasUrl = "$($uploadedBlob.ICloudBlob.Uri.AbsoluteUri)?$sasToken"

    Write-Host "Download link generated successfully!" -ForegroundColor Green
    Write-Host "Download URL: $sasUrl" -ForegroundColor Green

    # Return the full download URL to the GitHub Action
    Write-Output $sasUrl
}
catch {
    Write-Host "An error occurred during the upload process:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
finally {
    # Clean up the temporary directory and zip file
    if (Test-Path -Path $tempDir.FullName) {
        Remove-Item -Path $tempDir.FullName -Recurse -Force
    }
    if (Test-Path -Path $zipFilePath) {
        Remove-Item -Path $zipFilePath -Force
    }
}
#endregion
