Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "Malphas Pipeline Clipboard"
$form.Size = New-Object System.Drawing.Size(380, 210)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 10)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$btnStruct = New-Object System.Windows.Forms.Button
$btnStruct.Location = New-Object System.Drawing.Point(25, 25)
$btnStruct.Size = New-Object System.Drawing.Size(315, 45)
$btnStruct.Text = "COPIS STRUCT (Solo Arbol de Carpetas)"
$btnStruct.Font = New-Object System.Drawing.Font("Sans", 9, [System.Drawing.FontStyle]::Bold)
$btnStruct.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
$btnStruct.ForeColor = [System.Drawing.Color]::FromArgb(224, 220, 211)
$btnStruct.FlatStyle = "Flat"
$btnStruct.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(40, 40, 40)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Location = New-Object System.Drawing.Point(25, 90)
$btnAll.Size = New-Object System.Drawing.Size(315, 45)
$btnAll.Text = "COPIS ALL (Todo el Codigo + Rutas)"
$btnAll.Font = New-Object System.Drawing.Font("Sans", 9, [System.Drawing.FontStyle]::Bold)
$btnAll.BackColor = [System.Drawing.Color]::FromArgb(35, 30, 30)
$btnAll.ForeColor = [System.Drawing.Color]::FromArgb(224, 220, 211)
$btnAll.FlatStyle = "Flat"
$btnAll.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 30, 30)

$btnStruct.Add_Click({
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
    $items = Get-ChildItem -Path $root -Recurse | Where-Object {
        $_.FullName -notmatch "(\\target\\|\\build\\|\\\.dart_tool\\|\\\.git\\|\\\.idea\\|\\\.vscode\\)"
    }
    
    $tree = "STRUCTURE ASSETS BLUEPRINT:`r`n"
    foreach ($item in $items) {
        $relative = $item.FullName.Substring($root.Length)
        $tree += "$relative`r`n"
    }
    
    [System.Windows.Forms.Clipboard]::SetText($tree)
    [System.Windows.Forms.MessageBox]::Show("Estructura copiada al portapapeles.", "Malphas Core")
})

$btnAll.Add_Click({
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
    $files = Get-ChildItem -Path $root -Recurse -File | Where-Object {
        $_.FullName -notmatch "(\\target\\|\\build\\|\\\.dart_tool\\|\\\.git\\|\\\.idea\\|\\\.vscode\\)" -and
        $_.Extension -match "(\.rs|\.toml|\.yaml|\.dart|gitignore|md)" -and
        $_.Name -notmatch "copiador.ps1"
    }
    
    $dump = ""
    foreach ($file in $files) {
        $content = Get-Content -Path $file.FullName -Raw
        $relative = $file.FullName.Substring($root.Length)
        
        $dump += "===============================================================================`r`n"
        $dump += "FILE: $relative`r`n"
        $dump += "===============================================================================`r`n"
        $dump += $content + "`r`n`r`n"
    }
    
    if ([string]::IsNullOrEmpty($dump)) {
        [System.Windows.Forms.MessageBox]::Show("No se encontraron archivos validos.", "Error")
    } else {
        [System.Windows.Forms.Clipboard]::SetText($dump)
        [System.Windows.Forms.MessageBox]::Show("Todo el codigo copiado al portapapeles.", "Malphas Core")
    }
})

$form.Controls.Add($btnStruct)
$form.Controls.Add($btnAll)
$form.ShowDialog() | Out-Null
