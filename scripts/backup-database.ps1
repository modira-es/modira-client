$ErrorActionPreference = "Stop"

# =========================================================
# MODIRA — BACKUP DIARIO DE BASE DE DATOS
# =========================================================

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BackupPasswordFile = Join-Path $PSScriptRoot "backup-password.txt"

$LocalTemp = Join-Path $ProjectRoot "backups\automatic-temp"
$DriveBackupDir = "G:\Mi unidad\MODIRA\Backups\Database"

$SevenZip = "C:\Program Files\7-Zip\7z.exe"

$Date = Get-Date -Format "yyyy-MM-dd"
$ArchiveName = "MODIRA-$Date.7z"
$ArchivePath = Join-Path $DriveBackupDir $ArchiveName

# ---------------------------------------------------------
# Comprobaciones
# ---------------------------------------------------------

if (-not (Test-Path $SevenZip)) {
    throw "No se encuentra 7-Zip en: $SevenZip"
}

if (-not (Test-Path $BackupPasswordFile)) {
    throw "No se encuentra el archivo de contraseña de backup."
}

if (-not (Test-Path "G:\")) {
    throw "Google Drive no está disponible en G:."
}

New-Item -ItemType Directory -Force -Path $LocalTemp | Out-Null
New-Item -ItemType Directory -Force -Path $DriveBackupDir | Out-Null

# Limpiar temporales anteriores
Remove-Item (Join-Path $LocalTemp "*") -Force -Recurse -ErrorAction SilentlyContinue

# ---------------------------------------------------------
# Recuperar contraseña protegida por Windows DPAPI
# ---------------------------------------------------------

$SecurePassword = Get-Content $BackupPasswordFile |
    ConvertTo-SecureString

$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)

try {
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)

    # -----------------------------------------------------
    # Generar dumps
    # -----------------------------------------------------

    $SchemaFile = Join-Path $LocalTemp "schema.sql"
    $DataFile   = Join-Path $LocalTemp "data.sql"
    $RolesFile  = Join-Path $LocalTemp "roles.sql"

    Write-Host "Generando backup de esquema..."

    & supabase db dump --linked -f $SchemaFile

    if ($LASTEXITCODE -ne 0) {
        throw "Falló el backup del esquema."
    }

    Write-Host "Generando backup de datos..."

    & supabase db dump --linked --data-only -f $DataFile

    if ($LASTEXITCODE -ne 0) {
        throw "Falló el backup de datos."
    }

    Write-Host "Generando backup de roles..."

    & supabase db dump --linked --role-only -f $RolesFile

    if ($LASTEXITCODE -ne 0) {
        throw "Falló el backup de roles."
    }

    # -----------------------------------------------------
    # Crear archivo cifrado
    # -----------------------------------------------------

    Write-Host "Cifrando backup..."

    & $SevenZip a `
        -t7z `
        "-p$Password" `
        -mhe=on `
        $ArchivePath `
        $SchemaFile `
        $DataFile `
        $RolesFile

    if ($LASTEXITCODE -ne 0) {
        throw "Falló el cifrado del backup."
    }

    # -----------------------------------------------------
    # Verificar archivo cifrado
    # -----------------------------------------------------

    Write-Host "Verificando backup cifrado..."

    & $SevenZip t `
        "-p$Password" `
        $ArchivePath

    if ($LASTEXITCODE -ne 0) {
        throw "La verificación del backup cifrado ha fallado."
    }

    # -----------------------------------------------------
    # Eliminar temporales en claro
    # -----------------------------------------------------

    Remove-Item $SchemaFile, $DataFile, $RolesFile -Force

    # -----------------------------------------------------
    # Retención: conservar únicamente 7 backups
    # -----------------------------------------------------

    Write-Host "Aplicando retención de 7 backups..."

    $Archives = Get-ChildItem $DriveBackupDir -Filter "MODIRA-*.7z" |
        Sort-Object Name -Descending

    if ($Archives.Count -gt 7) {
        $Archives |
            Select-Object -Skip 7 |
            Remove-Item -Force
    }

    Write-Host ""
    Write-Host "========================================="
    Write-Host "BACKUP MODIRA COMPLETADO CORRECTAMENTE"
    Write-Host "========================================="
    Write-Host "Archivo: $ArchivePath"
}
finally {
    if ($BSTR -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }

    $Password = $null
    $SecurePassword = $null

    # Limpiar cualquier temporal que pudiera quedar
    if (Test-Path $LocalTemp) {
        Remove-Item (Join-Path $LocalTemp "*") -Force -Recurse -ErrorAction SilentlyContinue
    }
}