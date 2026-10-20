$ErrorActionPreference = 'Stop'
$studentKey = Read-Host 'Supabase Secret key (or service_role), input is hidden' -AsSecureString
$studentKeyPointer = [IntPtr]::Zero
try {
    $studentKeyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($studentKey)
    $env:LAB_QUEUE_ADMIN_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($studentKeyPointer)
    & node (Join-Path $PSScriptRoot 'create-students.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Account creation failed. Check the messages above and run again.' }
} finally {
    Remove-Item Env:LAB_QUEUE_ADMIN_KEY -ErrorAction SilentlyContinue
    if ($studentKeyPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($studentKeyPointer) }
    $studentKey.Dispose()
}
